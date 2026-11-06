#requires -Version 7.2
<#
.SYNOPSIS
验证 Send-ToRecycleBin.ps1 的路径安全边界与 RecycleInterop 互操作；可选在自建夹具上执行真实回收与还原往返测试。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestRoot,
    [switch]$ApplyRoundTrip
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot 'Send-ToRecycleBin.ps1'
if ($TestRoot -notmatch '^[A-Za-z]:[\\/]' -or
    $TestRoot.Substring(2).Contains(':') -or
    $TestRoot -match '[*?~]' -or
    $TestRoot -match '(^|[\\/])[^\\/]*[ .]([\\/]|$)') {
    throw 'TestRoot 必须是无设备前缀、ADS、短文件名别名和尾随点/空格的绝对本地目录。'
}
if (-not ('WindowsCleanup.Recycle' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'RecycleInterop.cs')
}
if (-not [WindowsCleanup.Recycle]::IsDirectVolume($TestRoot.Substring(0, 2))) {
    throw 'TestRoot 不能使用网络映射、SUBST 或非直接本地卷。'
}

$fixtureParent = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$skillRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
if ($fixtureParent.Equals($skillRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $fixtureParent.StartsWith($skillRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'TestRoot 不能位于 windows-cleanup 技能目录内；请指定调用任务的工作目录。'
}

# 拒绝路径祖先中的重解析点，避免目录别名绕过技能目录排除边界。
$ancestor = $fixtureParent
while ($ancestor) {
    if (Test-Path -LiteralPath $ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "TestRoot 必须经过普通目录，不能含重解析点：$ancestor"
        }
    }
    $parent = [IO.Directory]::GetParent($ancestor)
    $ancestor = if ($parent) { $parent.FullName } else { $null }
}

$root = Join-Path $fixtureParent ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$folder = Join-Path $root 'folder'
New-Item -ItemType Directory -Path $folder | Out-Null
$file = Join-Path $root 'sample.txt'
Set-Content -LiteralPath $file -Value '仅用于 windows-cleanup 回收测试。'
Set-Content -LiteralPath (Join-Path $folder 'nested.txt') -Value '嵌套测试内容'

$checks = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [string[]]$Paths, [bool]$Expected, [string[]]$Protected = @()) {
    $r = & $helper -LiteralPath $Paths -ScopeRoot $root -ProtectedPath $Protected | ConvertFrom-Json
    if ($r.Success -ne $Expected) {
        throw "测试失败：$Name；$($r | ConvertTo-Json -Depth 8 -Compress)"
    }
    $checks.Add([pscustomobject]@{ Name = $Name; Passed = $true })
}

Check '普通文件预检' @($file) $true
Check '目录及后代扫描' @($folder) $true
Check '卷根' @('C:\') $false
Check '相对路径' @('sample.txt') $false
Check '作用域外' @($fixtureParent) $false
Check 'UNC' @('\\localhost\c$\Windows') $false
Check '设备路径' @('\\?\C:\Windows') $false
Check 'ADS' @($file + ':stream') $false
Check '短路径别名' @((Join-Path $root 'SAMPLE~1.TXT')) $false
Check '尾随点' @($file + '.') $false
Check '不存在' @((Join-Path $root 'missing')) $false
Check '重复目标' @($file, $file.ToUpperInvariant()) $false
Check '父子目标' @($folder, (Join-Path $folder 'nested.txt')) $false
Check '保护目标的祖先' @($file) $false @($root)
Check '保护目标的后代' @($folder) $false @((Join-Path $folder 'nested.txt'))
Check '同前缀但不同目录' @($file) $true @($root + '-other')

$junction = Join-Path $root 'junction'
New-Item -ItemType Junction -Path $junction -Target $folder | Out-Null
Check '重解析点目标' @($junction) $false
Check '重解析点祖先' @((Join-Path $junction 'nested.txt')) $false
Check '重解析点后代' @($root) $false
Check '保护路径通过重解析别名指向目标' @($folder) $false @($junction)
Check '保护路径具有重解析祖先' @($folder) $false @((Join-Path $junction 'nested.txt'))
Check '不存在的保护路径具有重解析祖先' @($file) $false @((Join-Path $junction 'missing\reserved.txt'))
Check '不存在的普通保留路径仍保护父目录' @($folder) $false @((Join-Path $folder 'missing\reserved.txt'))
Check '不存在且无重解析祖先的无关保留路径' @($file) $true @((Join-Path $root 'missing\reserved.txt'))

# 纯托管 sink 验证：回收标记缺失必须取消，缺少回收项目证据不得报告成功。
if (-not ('WindowsCleanup.Recycle' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'RecycleInterop.cs')
}
$flags = [WindowsCleanup.Recycle]::OperationFlags
$required = 0x00080000 -bor 0x00100000 -bor 0x0400 -bor 0x2000 -bor 0x4000
if (($flags -band $required) -ne $required -or ($flags -band (0x00040000 -bor 0x10000000)) -ne 0) {
    throw '回收标志缺少永久删除警告、回收要求或立即停止，或意外允许提权。'
}
$checks.Add([pscustomobject]@{ Name = '回收标志保留永久删除警告且不提权'; Passed = $true })

$sink = [WindowsCleanup.RecycleSink]::new()
if ($sink.PreDeleteItem(0, $null) -ge 0 -or
    $sink.PreDeleteItem(128, $null) -ne 0 -or
    $sink.PostDeleteItem(128, $null, 0, $null) -ge 0) {
    throw '进度 sink 安全边界测试失败。'
}
$checks.Add([pscustomobject]@{ Name = '非回收删除取消与回收证据缺失'; Passed = $true })

$roundtrip = @()
if ($ApplyRoundTrip) {
    # 无效批次在任何删除之前失败。
    $r = & $helper -LiteralPath @($file, (Join-Path $root 'missing')) -ScopeRoot $root -Apply | ConvertFrom-Json
    if ($r.Success -or $r.Results.Count -ne 0 -or -not (Test-Path -LiteralPath $file)) {
        throw '全量预检先于执行测试失败。'
    }
    $checks.Add([pscustomobject]@{ Name = '无效批次不执行'; Passed = $true })

    # 真实共享冲突：首项失败后，第二项目录必须保持原位。
    $handle = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $r = & $helper -LiteralPath @($file, $folder) -ScopeRoot $root -Apply | ConvertFrom-Json
        if ($r.Success -or $r.Results.Count -ne 1 -or -not (Test-Path -LiteralPath $file) -or -not (Test-Path -LiteralPath $folder)) {
            throw '失败停止后续项目测试失败。'
        }
    } finally {
        $handle.Dispose()
    }
    $checks.Add([pscustomobject]@{ Name = '真实共享冲突停止后续目标'; Passed = $true })

    # 只回收本次生成的两个夹具；junction 留在夹具目录，不操作其目标。
    foreach ($target in @($file, $folder)) {
        $r = & $helper -LiteralPath $target -ScopeRoot $root -Apply | ConvertFrom-Json
        if (-not $r.Success) {
            throw "实际回收失败：$($r | ConvertTo-Json -Depth 8 -Compress)"
        }
        $recycled = $r.Results[0].RecycledPath
        if (-not $recycled) {
            throw '回收成功但未提供可定位的回收路径，停止恢复测试。'
        }
        $shell = New-Object -ComObject Shell.Application
        try {
            $bin = $shell.NameSpace(10)
            $match = @($bin.Items() | Where-Object { $_.Path -eq $recycled })
            if ($match.Count -ne 1) {
                throw "无法唯一定位刚回收的测试夹具：$recycled"
            }
            # Windows Shell 的规范还原动词；不移动或修改其他回收项目。
            $match[0].InvokeVerb('undelete')
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while (-not (Test-Path -LiteralPath $target) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $target)) {
                throw "夹具还原未完成：$target"
            }
            $content = if ($target -eq $file) {
                Get-Content -LiteralPath $target -Raw
            } else {
                Get-Content -LiteralPath (Join-Path $target 'nested.txt') -Raw
            }
            if (($target -eq $file -and $content.Trim() -ne '仅用于 windows-cleanup 回收测试。') -or
                ($target -eq $folder -and $content.Trim() -ne '嵌套测试内容')) {
                throw '还原内容不符。'
            }
            $roundtrip += [pscustomobject]@{
                Path = $target
                Recycled = $true
                Restored = $true
                ContentVerified = $true
            }
        } finally {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}

[pscustomobject]@{
    Success = $true
    FixtureRoot = $root
    Checks = $checks.ToArray()
    RoundTrip = $roundtrip
    Note = '保留生成夹具，未清空回收站。'
} | ConvertTo-Json -Depth 8
