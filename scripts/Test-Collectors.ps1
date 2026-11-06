#requires -Version 7.2
<#
.SYNOPSIS
使用受控夹具与模拟系统查询验证目录概览与软件取证采集脚本；不执行任何卸载或清理操作。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$overviewScript = Join-Path $PSScriptRoot 'Get-DirectoryOverview.ps1'
$evidenceScript = Join-Path $PSScriptRoot 'Find-SoftwareEvidence.ps1'
if (-not [IO.Path]::IsPathFullyQualified($TestRoot)) {
    throw 'TestRoot 必须为调用项目或会话工作目录中的绝对路径。'
}
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$skillRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')

# 逐级解析现有连接，避免通过 Junction 把夹具写回技能安装目录。
function Resolve-TestDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $resolved = $root
    foreach ($part in $full.Substring($root.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $resolved = Join-Path $resolved $part
        $item = $null
        try {
            $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        } catch {
            if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
        }
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $target = $item.ResolveLinkTarget($true)
            if ($null -eq $target) {
                throw "无法解析测试目录重解析点：$resolved"
            }
            $resolved = $target.FullName
        }
    }
    [IO.Path]::GetFullPath($resolved).TrimEnd('\', '/')
}

$resolvedTestRoot = Resolve-TestDirectory $TestRoot
$resolvedSkillRoot = Resolve-TestDirectory $skillRoot
if ($resolvedTestRoot.Equals($resolvedSkillRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedTestRoot.StartsWith($resolvedSkillRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'TestRoot 不得位于 windows-cleanup 技能根目录内。'
}

$run = Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($run)
$passed = [Collections.Generic.List[string]]::new()
$skipped = [Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) {
        throw "断言失败：$Name"
    }
    $passed.Add($Name)
}

$empty = Join-Path $run '空[目录]'
$null = [IO.Directory]::CreateDirectory($empty)
$result = & $overviewScript -LiteralPath $empty | ConvertFrom-Json
Assert-True ($result.overview.status -eq 'complete' -and $result.overview.count -eq 0 -and $result.overview.globalNameOrder) '空目录与中文方括号字面路径'

$parent = Join-Path $run '样本'
$child = Join-Path $parent '目录'
$null = [IO.Directory]::CreateDirectory($child)
foreach ($name in @('b.txt', 'a.txt', 'c.txt')) {
    [IO.File]::WriteAllText((Join-Path $child $name), '测试正文不得被采集')
}
$hidden = Join-Path $parent '隐藏.txt'
[IO.File]::WriteAllText($hidden, '123')
[IO.File]::SetAttributes($hidden, [IO.FileAttributes]::Hidden)

$result = & $overviewScript -LiteralPath $parent -MaxChildrenPerDirectory 2 | ConvertFrom-Json
Assert-True ($result.overview.entries.Count -eq 2 -and ($result.overview.entries | Where-Object name -eq '隐藏.txt').attributes -match 'Hidden') '隐藏条目可见'
$sample = ($result.overview.entries | Where-Object type -eq 'directory').overview
Assert-True ($sample.entries.Count -eq 2 -and $sample.truncated -and $sample.countIsLowerBound -and -not $sample.globalNameOrder) '子目录样本截断与下界'
Assert-True (($result | ConvertTo-Json -Depth 12) -notmatch '测试正文不得被采集') '不读取文件正文'

$result = & $overviewScript -LiteralPath $parent -MaxEntries 1 | ConvertFrom-Json
Assert-True ($result.overview.truncated -and $result.overview.entries.Count -eq 1 -and -not $result.overview.globalNameOrder) '顶层截断不声明全局名称顺序'

$result = & $overviewScript -LiteralPath $parent -MaxChildrenPerDirectory 0 | ConvertFrom-Json
Assert-True (($result.overview.entries | Where-Object type -eq 'directory').overview.reason -eq 'disabled') '可关闭目录样本'

$result = & $overviewScript -LiteralPath $parent | ConvertFrom-Json
Assert-True (($result.overview.entries | Where-Object type -eq 'directory').overview.reason -eq 'disabled' -and ($result.overview.entries | Where-Object type -eq 'directory').overview.entries.Count -eq 0) '默认仅枚举父目录直接项'
Assert-True (@($result.overview.entries | Where-Object { $null -ne $_.linkTarget }).Count -eq 0) '普通文件和目录的链接目标为空'

$result = & $overviewScript -LiteralPath (Join-Path $run 'missing') | ConvertFrom-Json
Assert-True ($result.overview.status -eq 'error' -and $result.overview.errors[0].kind -eq 'missing') '缺失目录独立分类'

$result = & $overviewScript -LiteralPath '.' | ConvertFrom-Json
Assert-True ($result.overview.status -eq 'error') '拒绝相对路径'

$junction = Join-Path $parent '连接'
try {
    $null = New-Item -ItemType Junction -Path $junction -Target $child -ErrorAction Stop
} catch {
    $skipped.Add("无法创建重解析点：$($_.Exception.Message)")
}
if (Test-Path -LiteralPath $junction) {
    $result = & $overviewScript -LiteralPath $parent | ConvertFrom-Json
    Assert-True (($result.overview.entries | Where-Object name -eq '连接').overview.reason -eq 'reparsePoint') '不展开直接重解析点'
    Assert-True (($result.overview.entries | Where-Object name -eq '连接').linkTarget -eq $child) '链接自身目标元数据'
    $result = & $overviewScript -LiteralPath $junction | ConvertFrom-Json
    Assert-True ($result.overview.status -eq 'error') '拒绝重解析点根目录'
    $result = & $overviewScript -LiteralPath (Join-Path $junction 'sub') | ConvertFrom-Json
    Assert-True ($result.overview.status -eq 'error') '拒绝重解析点后代路径'
}

# 模拟系统接口只覆盖受控返回值，不改注册表、进程、服务或任务。
function Get-CimInstance {
    param($ClassName, $Property, $ErrorAction)
    if ($ClassName -eq 'Win32_Service') {
        1..4 | ForEach-Object {
            [pscustomobject]@{
                Name = "[literal].$_"
                DisplayName = '软件'
                State = 'Running'
                StartMode = 'Auto'
                PathName = 'C:\Program Files\test.exe --token=very-secret'
                StartName = 'LocalSystem'
            }
        }
    } else {
        [pscustomobject]@{
            Name = '[literal].exe'
            ProcessId = 42
            ParentProcessId = 1
            SessionId = 1
            ExecutablePath = 'C:\test.exe'
            CommandLine = 'C:\test.exe --password "very-secret"'
        }
    }
}

$result = & $evidenceScript -Needle '[literal].' -Section Services -MaxScanned 2 -MaxResults 1 | ConvertFrom-Json
$sectionResult = $result.sections[0]
Assert-True ($sectionResult.status -eq 'partial' -and $sectionResult.scanTruncated -and $sectionResult.resultTruncated -and $sectionResult.records.Count -eq 1) '候选与输出数量双重上限'
Assert-True ($sectionResult.records[0].rawCommand -like 'C:\Program Files\test.exe*' -and $sectionResult.records[0].rawCommand -notmatch 'very-secret') '服务原命令结构与秘密遮盖'

$result = & $evidenceScript -Needle '.*' -Section Services | ConvertFrom-Json
Assert-True ($result.sections[0].status -eq 'complete' -and $result.sections[0].records.Count -eq 0) '正则元字符按字面匹配'

$result = & $evidenceScript -Needle '[literal]' -Section Processes | ConvertFrom-Json
Assert-True ($result.sections[0].records[0].PSObject.Properties.Name -notcontains 'commandLine') '默认无进程命令行'

$result = & $evidenceScript -Needle '[literal]' -Section Processes -IncludeCommandLine | ConvertFrom-Json
Assert-True ($result.sections[0].records[0].commandLine -match 'REDACTED' -and $result.sections[0].records[0].commandLine -notmatch 'very-secret') '显式进程命令行遮盖'

function Get-CimInstance {
    param($ClassName, $Property, $ErrorAction)
    foreach ($scheme in @('Bearer', 'Basic')) {
        [pscustomobject]@{
            Name = 'review-target.exe'
            ProcessId = 42
            ParentProcessId = 1
            SessionId = 1
            ExecutablePath = 'C:\review-target.exe'
            CommandLine = ('C:\review-target.exe --header "Authorization: ' + $scheme + ' synthetic-secret-928"')
        }
    }
}
$result = & $evidenceScript -Needle 'review-target' -Section Processes -IncludeCommandLine | ConvertFrom-Json
Assert-True ($result.sections[0].records.Count -eq 2 -and ($result | ConvertTo-Json -Depth 12) -notmatch 'synthetic-secret-928' -and @($result.sections[0].records | Where-Object { $_.commandLine -match 'REDACTED' }).Count -eq 2) 'Authorization Bearer 和 Basic 完整凭据遮盖'

function Get-CimInstance {
    param($ClassName, $Property, $ErrorAction)
    foreach ($missingCommand in @($null, '')) {
        [pscustomobject]@{
            Name = '[literal].exe'
            ProcessId = 42
            ParentProcessId = 1
            SessionId = 1
            ExecutablePath = 'C:\test.exe'
            CommandLine = $missingCommand
        }
    }
}
$result = & $evidenceScript -Needle '--parameter-only' -Section Processes -IncludeCommandLine | ConvertFrom-Json
Assert-True ($result.sections[0].status -eq 'partial' -and $result.sections[0].records.Count -eq 0 -and $result.sections[0].errors.Count -eq 2 -and $result.sections[0].errors[0].kind -eq 'unavailableField') '显式要求但命令行为空时不能证明参数无匹配'

$result = & $evidenceScript -Needle '[literal]' -Section Processes | ConvertFrom-Json
Assert-True ($result.sections[0].status -eq 'complete' -and $result.sections[0].errors.Count -eq 0) '未要求命令行时不因命令行为空降低完整性'

function Get-ScheduledTask {
    param($ErrorAction)
    [pscustomobject]@{
        TaskName = '[literal]'
        TaskPath = '\'
        State = 'Ready'
        Actions = @([pscustomobject]@{ Execute = 'cmd.exe'; Arguments = '/c arbitrary-secret' })
    }
}
function Export-ScheduledTask {
    param($TaskName, $TaskPath, $ErrorAction)
    if ($TaskName -cne '[literal]' -or $TaskPath -cne '\') {
        throw '任务名称和路径必须按原样传递。'
    }
    '<Task><Actions><Exec><Command>cmd.exe</Command><Arguments>/c arbitrary-secret</Arguments></Exec></Actions><Triggers><BootTrigger /></Triggers></Task>'
}
$result = & $evidenceScript -Needle '[literal]' -Section Tasks | ConvertFrom-Json
Assert-True ($result.sections[0].status -eq 'complete' -and $result.sections[0].records[0].xml -match 'BootTrigger' -and ($result | ConvertTo-Json -Depth 12) -notmatch 'arbitrary-secret') '任务完整结构保留与参数遮盖'

function Get-ScheduledTask {
    param($ErrorAction)
    throw [UnauthorizedAccessException]::new('模拟任务查询拒绝访问')
}
$result = & $evidenceScript -Needle 'x' -Section Tasks | ConvertFrom-Json
Assert-True ($result.sections[0].status -eq 'error' -and $result.sections[0].errors.Count -gt 0) '查询失败不能作为空结果'

$rejected = $false
try {
    $null = & $evidenceScript -Needle 'x' -Section 'Unsupported'
} catch {
    $rejected = $true
}
Assert-True $rejected '拒绝不支持的查询节'

# 本机只读烟测输出仅限状态，不泄漏用户条目。
$smoke = & $evidenceScript -Needle '__collector_no_match_58403__' -Section Installed,Environment,Commands | ConvertFrom-Json
Assert-True ($smoke.sections.Count -eq 3 -and @($smoke.sections | Where-Object { $_.status -eq 'error' }).Count -eq 0) '本机注册表环境命令只读烟测'

[pscustomobject]@{
    status = 'passed'
    passed = $passed.ToArray()
    skipped = $skipped.ToArray()
    testDirectory = $run
    smoke = @($smoke.sections | Select-Object name, status, scanned, matchedCount)
} | ConvertTo-Json -Depth 6
