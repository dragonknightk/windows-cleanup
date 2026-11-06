#requires -Version 7.2
<#
.SYNOPSIS
对已审范围内的指定文件或目录执行路径边界预检，并在显式传入 -Apply 时移入 Windows 回收站。
.DESCRIPTION
默认仅执行路径、作用域、保护路径与重解析点预检；指定 -Apply 时调用 Windows Shell IFileOperation 将目标移入回收站。
仅接受直接连接的固定本地卷绝对路径；拒绝卷根、UNC、设备路径、ADS、短文件名别名、尾随点或空格、系统关键树和关键容器整体。
遇到永久删除警告时保留警告并要求取消操作，禁止静默转为永久删除；单项失败后立即停止后续目标。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$LiteralPath,
    [Parameter(Mandatory)][string]$ScopeRoot,
    [string[]]$ProtectedPath = @(),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$results = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[string]]::new()

function Normalize-LocalPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or
        $Path.Substring(2).Contains(':') -or
        $Path -match '[*?~]' -or
        $Path -match '(^|[\\/])[^\\/]*[ .]([\\/]|$)') {
        throw "仅接受无通配符、短文件名别名（~）、ADS、设备前缀和尾随点/空格的绝对本地路径：$Path"
    }
    if (-not [WindowsCleanup.Recycle]::IsDirectVolume($Path.Substring(0, 2))) {
        throw "拒绝网络映射、SUBST 或非直接本地卷：$Path"
    }
    $drive = [IO.DriveInfo]::new($Path.Substring(0, 3))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw "仅接受固定本地卷：$Path"
    }
    $full = [IO.Path]::GetFullPath($Path).Replace('/', '\').TrimEnd('\')
    if ($full.Length -eq 2) {
        throw "拒绝卷根：$Path"
    }
    return $full
}

function Is-Within([string]$Child, [string]$Parent) {
    return $Child.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Child.StartsWith($Parent + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparse([string]$Path, [bool]$Descendants) {
    $current = $Path
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "拒绝目标或路径祖先中的重解析点：$current"
        }
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($parent) { $parent.FullName } else { $null }
    }
    if ($Descendants -and (Get-Item -LiteralPath $Path -Force).PSIsContainer) {
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($Path)
        while ($pending.Count) {
            foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "拒绝后代中的重解析点：$($child.FullName)"
                }
                if ($child.PSIsContainer) {
                    $pending.Push($child.FullName)
                }
            }
        }
    }
}

function Assert-ProtectedPath([string]$Path) {
    # 不存在的保留路径有效；沿路径向上仅跳过明确不存在的节点。
    $current = $Path
    while ($current) {
        try {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "保护路径不能包含重解析点或重解析祖先：$current"
            }
        } catch [System.Management.Automation.ItemNotFoundException] {
            # 保留将来出现的路径；仍继续检查所有现存祖先。
        }
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($parent) { $parent.FullName } else { $null }
    }
}

$targets = @()
try {
    if (-not $IsWindows) {
        throw '本脚本仅支持 Windows。'
    }
    if (-not ('WindowsCleanup.Recycle' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'RecycleInterop.cs')
    }
    $scope = Normalize-LocalPath $ScopeRoot
    if (-not (Get-Item -LiteralPath $scope -Force).PSIsContainer) {
        throw 'ScopeRoot 必须是存在的目录。'
    }
    Assert-NoReparse $scope $false
    $protected = @(
        $ProtectedPath | ForEach-Object {
            $normalizedProtected = Normalize-LocalPath $_
            Assert-ProtectedPath $normalizedProtected
            $normalizedProtected
        }
    )

    # 系统树禁止任意下钻；其他关键容器禁止整体及其祖先被回收。
    $systemTrees = @(
        $env:SystemRoot,
        (Join-Path $env:SystemDrive 'System Volume Information'),
        (Join-Path $env:SystemDrive '$Recycle.Bin')
    )
    $containers = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        (Join-Path $env:SystemDrive 'Users')
    ) | Where-Object { $_ }

    foreach ($raw in $LiteralPath) {
        $target = Normalize-LocalPath $raw
        if (-not (Is-Within $target $scope)) {
            throw "目标在本次已审范围之外：$target"
        }
        foreach ($p in $protected) {
            if ((Is-Within $target $p) -or (Is-Within $p $target)) {
                throw "目标与保护路径重叠：$target；$p"
            }
        }
        foreach ($p in $systemTrees) {
            if ((Is-Within $target $p) -or (Is-Within $p $target)) {
                throw "拒绝系统关键路径：$target"
            }
        }
        foreach ($p in $containers) {
            if (Is-Within $p $target) {
                throw "拒绝系统或用户关键容器：$target"
            }
        }
        if ($target -match '^[A-Za-z]:\\(\$Recycle\.Bin|System Volume Information)(\\|$)') {
            throw "拒绝卷元数据：$target"
        }
        foreach ($prior in $targets) {
            if ((Is-Within $target $prior) -or (Is-Within $prior $target)) {
                throw "目标重复或存在父子重叠：$target；$prior"
            }
        }
        Assert-NoReparse $target $true
        $targets += $target
    }
    if ($targets.Count -eq 0) {
        throw '目标列表不能为空。'
    }
} catch {
    $errors.Add($_.Exception.Message)
}

if ($errors.Count -eq 0 -and $Apply) {
    foreach ($target in $targets) {
        try {
            # 紧邻操作再次检查；本脚本不提供针对恶意并发替换的原子隔离。
            foreach ($p in $protected) {
                Assert-ProtectedPath $p
            }
            Assert-NoReparse $target $true
            $r = [WindowsCleanup.Recycle]::One($target)
            $results.Add([pscustomobject]@{
                Path = $target
                Status = $(if ($r.Success) { 'Recycled' } else { 'Failed' })
                RecycledPath = $r.RecycledPath
                Error = $r.Error
                HResult = $r.HResult
            })
            if (-not $r.Success) {
                $errors.Add("回收失败，已停止：$target")
                break
            }
        } catch {
            $results.Add([pscustomobject]@{
                Path = $target
                Status = 'Failed'
                Error = $_.Exception.Message
            })
            $errors.Add($_.Exception.Message)
            break
        }
    }
}

[pscustomobject]@{
    Mode = $(if ($Apply) { 'Apply' } else { 'Preflight' })
    Success = ($errors.Count -eq 0)
    PreflightPassed = ($targets.Count -eq $LiteralPath.Count -and $targets.Count -gt 0)
    Note = '预检仅确认路径边界，不能保证回收站可用或执行成功。执行要求回收；若 Shell 显示永久删除警告，必须取消，禁止自动接受。失败后停止，此前成功项保持原结果，不会自动还原。'
    Targets = $targets
    Results = @($results.ToArray())
    Errors = @($errors.ToArray())
} | ConvertTo-Json -Depth 8
