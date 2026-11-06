#requires -Version 7.2
<#
.SYNOPSIS
对绝对字面目录路径进行有限只读概览，输出 JSON。
.DESCRIPTION
默认仅枚举直接子项；显式指定时采集子目录的有限样本，不读取正文、不统计递归大小。
遇到重解析点（含祖先）停止展开。截断时排序仅适用于已枚举样本。
计数描述本次枚举，并非文件系统的原子快照；扫描期间发生的变更可能影响结果。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [ValidateRange(1,10000)][int]$MaxEntries = 2000,
    [ValidateRange(0,100)][int]$MaxChildrenPerDirectory = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BoundedEntries([string]$Path, [int]$Limit) {
    $items = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[object]]::new()
    $truncated = $false
    $observed = 0
    $iterator = $null
    try {
        $options = [IO.EnumerationOptions]::new()
        $options.AttributesToSkip = 0
        $options.IgnoreInaccessible = $false
        $options.RecurseSubdirectories = $false
        $iterator = [IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos('*', $options).GetEnumerator()
        while ($iterator.MoveNext()) {
            # 多观察一项来区分恰好达到上限和实际截断，不读取该项元数据。
            if ($observed -ge $Limit) { $truncated = $true; break }
            $observed++
            $item = $iterator.Current
            try {
                $attributes = $item.Attributes
                $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
                $items.Add([pscustomobject]@{
                    name = $item.Name; path = $item.FullName
                    type = $(if ($isDirectory) { 'directory' } else { 'file' })
                    attributes = $attributes.ToString()
                    reparsePoint = ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                    linkTarget = $item.LinkTarget
                    sizeBytes = $(if (-not $isDirectory) { $item.Length } else { $null })
                    lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
                })
            } catch { $errors.Add([pscustomobject]@{ path = $item.FullName; kind = 'metadata'; message = $_.Exception.Message }) }
        }
    } catch { $errors.Add([pscustomobject]@{ path = $Path; kind = 'enumeration'; message = $_.Exception.Message }) }
    finally { if ($null -ne $iterator) { $iterator.Dispose() } }
    $complete = -not $truncated -and $errors.Count -eq 0
    [pscustomobject]@{
        status = $(if ($complete) { 'complete' } elseif ($items.Count -gt 0 -or $truncated) { 'partial' } else { 'error' })
        limit = $Limit; count = $items.Count; countIsLowerBound = -not $complete
        truncated = $truncated; globalNameOrder = $complete
        entries = @($items | Sort-Object -Property name -Culture en-US); errors = $errors.ToArray()
    }
}

try {
    if (-not [IO.Path]::IsPathFullyQualified($LiteralPath) -or $LiteralPath -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)') {
        throw 'LiteralPath 必须是绝对文件系统路径。'
    }
    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    $ancestor = [IO.DirectoryInfo]::new($fullPath)
    $ancestors = [Collections.Generic.Stack[string]]::new()
    while ($null -ne $ancestor) {
        $ancestors.Push($ancestor.FullName)
        $ancestor = $ancestor.Parent
    }
    # 从根向下检查，防止先访问位于重解析点之后的路径。
    foreach ($ancestorPath in $ancestors) {
        $attributes = [IO.File]::GetAttributes($ancestorPath)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "拒绝展开重解析点或其后代：$ancestorPath" }
    }
    if (($attributes = [IO.File]::GetAttributes($fullPath)) -band [IO.FileAttributes]::Directory) {
        $result = Get-BoundedEntries $fullPath $MaxEntries
        foreach ($entry in $result.entries) {
            if ($entry.type -eq 'directory') {
                $overview = if ($entry.reparsePoint) {
                    [pscustomobject]@{ status = 'skipped'; reason = 'reparsePoint'; count = 0; countIsLowerBound = $true; truncated = $false; entries = @(); errors = @() }
                } elseif ($MaxChildrenPerDirectory -eq 0) {
                    [pscustomobject]@{ status = 'skipped'; reason = 'disabled'; count = 0; countIsLowerBound = $true; truncated = $false; entries = @(); errors = @() }
                } else { Get-BoundedEntries $entry.path $MaxChildrenPerDirectory }
                $entry | Add-Member -NotePropertyName overview -NotePropertyValue $overview
            }
        }
        [pscustomobject]@{ schemaVersion = 1; path = $fullPath; observedAtUtc = [DateTime]::UtcNow.ToString('o'); overview = $result } | ConvertTo-Json -Depth 12
    } else { throw 'LiteralPath 指向文件，要求目录。' }
} catch {
    $kind = if ($_.Exception -is [IO.FileNotFoundException] -or $_.Exception -is [IO.DirectoryNotFoundException] -or $_.Exception.InnerException -is [IO.FileNotFoundException] -or $_.Exception.InnerException -is [IO.DirectoryNotFoundException]) { 'missing' } else { 'queryError' }
    [pscustomobject]@{ schemaVersion = 1; path = $LiteralPath; overview = @{ status = 'error'; count = 0; countIsLowerBound = $true; truncated = $false; globalNameOrder = $false; entries = @(); errors = @(@{ kind = $kind; message = $_.Exception.Message }) } } | ConvertTo-Json -Depth 8
}
