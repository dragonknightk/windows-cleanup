#requires -Version 7.2
<#
.SYNOPSIS
按字面候选词查询软件证据，输出 JSON；不执行任何目标文件或卸载入口。
.DESCRIPTION
Section 支持 Installed、Processes、Services、Tasks、Startup、Environment、Commands。
默认查询前三节。Needle 为忽略大小写的字面子串；Commands 在当前会话与 PATH 可发现命令中匹配。
Startup 查询 Run、RunOnce（两种注册表视图）及当前用户/公共启动目录的直接条目。
不解析快捷方式，不查询其他用户配置，不推断可删除或目标可执行文件是否缺失。
MaxScanned 限制每节消费的候选数，额外观察一项判定截断；底层系统查询可能缓冲更多数据。
MaxResults 限制每节输出条数。任务 XML 完整导出后遮盖参数字段；大于 MaxTaskXmlChars 时整段省略并标记 partial。
进程命令行仅 IncludeCommandLine 时查询、匹配和输出。常见秘密格式会遮盖，无法保证识别任意自定义秘密。
缺失注册表根记录 missing，查询失败记录 error；complete 仅描述该节声明的数据源范围。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Needle,
    [ValidateSet('Installed','Processes','Services','Tasks','Startup','Environment','Commands')]
    [string[]]$Section = @('Installed','Processes','Services'),
    [ValidateRange(1,50000)][int]$MaxScanned = 10000,
    [ValidateRange(1,1000)][int]$MaxResults = 200,
    [ValidateRange(1024,1048576)][int]$MaxTaskXmlChars = 131072,
    [switch]$IncludeCommandLine
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($value in $Needle) { if ([string]::IsNullOrWhiteSpace($value)) { throw 'Needle 不允许空白候选词。' } }

function Protect-Text([AllowNull()][string]$Text) {
    if ($null -eq $Text) { return $null }
    # 先识别认证方案与完整凭据，避免通用字段规则只吃掉 Bearer/Basic 留下秘密。
    $Text = [regex]::Replace($Text, '(?i)(authorization["'']?\s*[:=]\s*["'']?)(?:Bearer|Basic)\s+[^"''\s;,]+', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)((?:Bearer|Basic)\s+)[^"''\s;,]+', '$1[REDACTED]')
    $secret = '(?:password|passwd|pwd|token|api[_-]?key|secret|client[_-]?secret|access[_-]?key|authorization)'
    $pattern = '(?i)(["'']?(?:--?|/)?' + $secret + '["'']?\s*(?:=|:|\s)\s*)(?:"[^"]*"|''[^'']*''|[^\s;&]+)'
    $Text = [regex]::Replace($Text, $pattern, '$1[REDACTED]')
    [regex]::Replace($Text, '(?i)(https?://)[^/\s:@]+:[^/\s@]+@', '$1[REDACTED]@')
}
function Test-LiteralMatch($Record) {
    foreach ($field in $Record.Values) {
        foreach ($word in $Needle) {
            if ([string]$field -and ([string]$field).IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    return $false
}
function Add-QueryError([string]$Source, $Record) {
    $script:queryErrors.Add([pscustomobject]@{ source = $Source; kind = 'queryError'; message = Protect-Text $Record.Exception.Message })
}
function Get-RegistryRecords([bool]$Startup) {
    foreach ($hiveName in @('CurrentUser','LocalMachine')) {
        foreach ($viewName in @('Registry64','Registry32')) {
            if (-not [Environment]::Is64BitOperatingSystem -and $viewName -eq 'Registry64') { continue }
            $paths = if ($Startup) { @('Software\Microsoft\Windows\CurrentVersion\Run','Software\Microsoft\Windows\CurrentVersion\RunOnce') } else { @('Software\Microsoft\Windows\CurrentVersion\Uninstall') }
            foreach ($path in $paths) {
                $source = "$hiveName/$viewName/$path"
                $base = $null; $root = $null
                try {
                    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$hiveName, [Microsoft.Win32.RegistryView]::$viewName)
                    $root = $base.OpenSubKey($path, $false)
                    if ($null -eq $root) { $script:sources.Add(@{ source = $source; status = 'missing' }); continue }
                    $script:sources.Add(@{ source = $source; status = 'queried' })
                    if ($Startup) {
                        foreach ($name in $root.GetValueNames()) {
                            [ordered]@{ location = "${source}::$name"; name = $name; command = $root.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
                        }
                    } else {
                        foreach ($name in $root.GetSubKeyNames()) {
                            $key = $null
                            try {
                                $key = $root.OpenSubKey($name, $false)
                                if ($null -eq $key) { throw "枚举后注册表项已消失：$source/$name" }
                                $row = [ordered]@{ location = "$source/$name" }
                                foreach ($field in @('DisplayName','DisplayVersion','Publisher','InstallLocation','UninstallString','QuietUninstallString')) { $row[$field] = $key.GetValue($field, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
                                $row
                            } catch { Add-QueryError "$source/$name" $_ }
                            finally { if ($null -ne $key) { $key.Dispose() } }
                        }
                    }
                } catch { Add-QueryError $source $_ }
                finally { if ($null -ne $root) { $root.Dispose() }; if ($null -ne $base) { $base.Dispose() } }
            }
        }
    }
}
function Get-Records([string]$Name) {
    switch ($Name) {
        'Installed' { Get-RegistryRecords $false }
        'Processes' {
            $properties = @('ProcessId','ParentProcessId','Name','ExecutablePath','SessionId')
            if ($IncludeCommandLine) { $properties += 'CommandLine' }
            Get-CimInstance -ClassName Win32_Process -Property $properties -ErrorAction Stop | ForEach-Object {
                $row = [ordered]@{ location = "Win32_Process/ProcessId=$($_.ProcessId)"; name = $_.Name; processId = $_.ProcessId; parentProcessId = $_.ParentProcessId; sessionId = $_.SessionId; executablePath = $_.ExecutablePath }
                if ($null -eq $_.ExecutablePath) { $script:queryErrors.Add(@{ source = $row.location; kind = 'unavailableField'; message = 'ExecutablePath 不可用，可能由权限或进程状态导致。' }) }
                if ($IncludeCommandLine) {
                    $row.commandLine = $_.CommandLine
                    if ([string]::IsNullOrEmpty($_.CommandLine)) {
                        $script:queryErrors.Add(@{ source = $row.location; kind = 'unavailableField'; message = '已要求 CommandLine，但系统未提供非空命令行；参数匹配范围不完整。' })
                    }
                }
                $row
            }
        }
        'Services' {
            Get-CimInstance -ClassName Win32_Service -Property Name,DisplayName,State,StartMode,PathName,StartName -ErrorAction Stop | ForEach-Object {
                [ordered]@{ location = "Win32_Service/Name=$($_.Name)"; name = $_.Name; displayName = $_.DisplayName; state = $_.State; startMode = $_.StartMode; rawCommand = $_.PathName; startName = $_.StartName }
            }
        }
        'Tasks' {
            Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
                [ordered]@{ location = "$($_.TaskPath)$($_.TaskName)"; taskName = $_.TaskName; taskPath = $_.TaskPath; state = [string]$_.State; actions = ($_.Actions | Select-Object * -ExcludeProperty CimClass,CimInstanceProperties,CimSystemProperties | ConvertTo-Json -Depth 6 -Compress) }
            }
        }
        'Startup' {
            Get-RegistryRecords $true
            foreach ($folder in @('Startup','CommonStartup')) {
                $path = [Environment]::GetFolderPath([Environment+SpecialFolder]::$folder)
                try {
                    if ([string]::IsNullOrEmpty($path)) { throw "系统未提供 $folder 路径。" }
                    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "启动目录为重解析点：$path" }
                    Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | ForEach-Object { [ordered]@{ location = $_.FullName; name = $_.Name; attributes = $_.Attributes.ToString(); scope = $folder } }
                } catch {
                    if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $script:sources.Add(@{ source = $path; status = 'missing' }) } else { Add-QueryError $folder $_ }
                }
            }
        }
        'Environment' {
            foreach ($scope in @('Machine','User','Process')) {
                try {
                    foreach ($item in [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::$scope).GetEnumerator()) { [ordered]@{ location = "Environment/$scope/$($item.Key)"; scope = $scope; name = $item.Key; value = $item.Value } }
                } catch { Add-QueryError $scope $_ }
            }
        }
        'Commands' {
            # ListImported 避免自动导入模块；不输出函数正文或别名定义。
            Get-Command -Name * -All -ListImported -ErrorAction Stop | ForEach-Object { [ordered]@{ location = "Command/$($_.CommandType)/$($_.Name)"; name = $_.Name; commandType = $_.CommandType.ToString(); source = $_.Source; path = $(if ($_.PSObject.Properties['Path']) { $_.Path } else { $null }) } }
        }
    }
}

$sections = [Collections.Generic.List[object]]::new()
foreach ($name in ($Section | Select-Object -Unique)) {
    $script:queryErrors = [Collections.Generic.List[object]]::new()
    $script:sources = [Collections.Generic.List[object]]::new()
    $rows = [Collections.Generic.List[object]]::new()
    $scanned = 0; $scanTruncated = $false; $resultTruncated = $false
    try {
        if (-not $IsWindows) { throw '此查询只支持 Windows。' }
        Get-Records $name | Select-Object -First ($MaxScanned + 1) | ForEach-Object {
            if ($scanned -ge $MaxScanned) { $scanTruncated = $true; return }
            $scanned++
            $record = $_
            if (-not (Test-LiteralMatch $record)) { return }
            if ($rows.Count -ge $MaxResults) { $resultTruncated = $true; return }
            if ($name -eq 'Tasks') {
                try {
                    # 导出完整定义供后续审查；参数全文遮盖，保留任务结构与定位。
                    $xmlText = Export-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath -ErrorAction Stop
                    if ($xmlText.Length -gt $MaxTaskXmlChars) { throw "任务定义超过 MaxTaskXmlChars=$MaxTaskXmlChars，未输出；需单独定向审查。" }
                    $xml = [xml]$xmlText
                    foreach ($node in $xml.SelectNodes('//*[local-name()="Arguments" or local-name()="Password" or local-name()="Data"]')) { $node.InnerText = '[REDACTED]' }
                    $record.xml = Protect-Text $xml.OuterXml
                    $record.xmlArgumentsRedacted = $true
                } catch { Add-QueryError $record.location $_; $record.xml = $null }
            }
            $safe = [ordered]@{}
            foreach ($key in $record.Keys) {
                $value = $record[$key]
                if ($name -eq 'Environment' -and $key -eq 'value' -and $record.name -match '(?i)password|passwd|pwd|token|secret|key|credential|authorization') { $safe[$key] = '[REDACTED]' }
                elseif ($name -eq 'Tasks' -and $key -eq 'actions') { $safe[$key] = '[REDACTED: consult task XML structure]' }
                elseif ($value -is [string]) { $safe[$key] = Protect-Text $value }
                else { $safe[$key] = $value }
            }
            $rows.Add([pscustomobject]$safe)
        }
    } catch { Add-QueryError $name $_ }
    $partial = $scanTruncated -or $resultTruncated -or $queryErrors.Count -gt 0
    $sections.Add([pscustomobject]@{
        name = $name; status = $(if (-not $partial) { 'complete' } elseif ($scanned -eq 0 -and $queryErrors.Count -gt 0) { 'error' } else { 'partial' })
        scanned = $scanned; scannedCountIsLowerBound = $partial; matchedCount = $rows.Count
        truncated = ($scanTruncated -or $resultTruncated); scanTruncated = $scanTruncated; resultTruncated = $resultTruncated
        maxScanned = $MaxScanned; maxResults = $MaxResults; sources = $sources.ToArray(); errors = $queryErrors.ToArray(); records = $rows.ToArray()
    })
}
[pscustomobject]@{ schemaVersion = 1; observedAtUtc = [DateTime]::UtcNow.ToString('o'); matchMode = 'literalOrdinalIgnoreCase'; includeCommandLine = [bool]$IncludeCommandLine; maxTaskXmlChars = $MaxTaskXmlChars; sections = $sections.ToArray() } | ConvertTo-Json -Depth 14
