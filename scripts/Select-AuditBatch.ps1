#requires -Version 7.2
<#
.SYNOPSIS
从当前父目录的候选集合中选择最多 10 项，保持稳定顺序；仅输出结果，不更新记录。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [string[]]$PreferredId = @(),
    [ValidateRange(1, 10)][int]$Limit = 10,
    [switch]$SummaryOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [System.IO.Path]::IsPathFullyQualified($LiteralPath)) {
    throw 'LiteralPath 必须为候选记录的绝对路径。'
}
$inputItem = Get-Item -LiteralPath $LiteralPath -Force
if ($inputItem.PSProvider.Name -ne 'FileSystem' -or $inputItem.PSIsContainer) {
    throw 'LiteralPath 必须指向 JSON 文件。'
}
$json = Get-Content -LiteralPath $inputItem.FullName -Raw -Encoding utf8
# 保留字符串原值与空数组；常规 ConvertFrom-Json 会自动改写 ISO 时间字段。
function ConvertFrom-JsonElement([System.Text.Json.JsonElement]$Element) {
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $value = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if ($value.Contains($property.Name)) { throw "JSON 字段重复：$($property.Name)" }
                $value.Add($property.Name, (ConvertFrom-JsonElement $property.Value))
            }
            return $value
        }
        'Array' {
            $value = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $value.Add((ConvertFrom-JsonElement $item)) }
            return ,($value.ToArray())
        }
        'String' { return $Element.GetString() }
        'Number' {
            $integer = 0L
            if ($Element.TryGetInt64([ref]$integer)) { return $integer }
            $decimal = [decimal]0
            if ($Element.TryGetDecimal([ref]$decimal)) { return $decimal }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw '不支持的 JSON 值。' }
    }
}
$document = [System.Text.Json.JsonDocument]::Parse($json)
try { $record = ConvertFrom-JsonElement $document.RootElement } finally { $document.Dispose() }
if ($record -isnot [System.Collections.IDictionary] -or -not $record.Contains('schemaVersion') -or
    $record.schemaVersion -isnot [long] -or $record.schemaVersion -ne 2) {
    throw '仅接受 schemaVersion 为 2 的会话记录；旧记录必须重新整理。'
}
if ($SummaryOnly -and $PreferredId.Count -gt 0) { throw 'SummaryOnly 不能与非空 PreferredId 同用。' }
foreach ($field in @('currentParent', 'inventory', 'exclusions', 'groups')) {
    if (-not $record.Contains($field)) { throw "记录缺少字段：$field" }
}
function ConvertTo-CanonicalPath($Path) {
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathFullyQualified($Path)) { throw '范围中的路径必须为绝对文件系统路径。' }
    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
}
$currentParent = ConvertTo-CanonicalPath $record.currentParent
function ConvertTo-DirectChildPath($Path) {
    $canonical = ConvertTo-CanonicalPath $Path
    $parentPath = [IO.Path]::GetDirectoryName($canonical)
    if ([string]::IsNullOrEmpty($parentPath) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals((ConvertTo-CanonicalPath $parentPath), $currentParent)) {
        throw "路径必须是 currentParent 的直接子项：$Path"
    }
    $canonical
}
$inventory = $record.inventory
if ($inventory -isnot [Collections.IDictionary]) { throw 'inventory 必须为对象。' }
foreach ($field in @('observedAtUtc', 'status', 'directChildPaths')) {
    if (-not $inventory.Contains($field)) { throw "inventory 缺少字段：$field" }
}
if ($inventory.status -isnot [string] -or $inventory.status -cnotin @('complete', 'partial')) {
    throw 'inventory.status 仅接受 complete 或 partial。'
}
$observedAtUtc = $inventory.observedAtUtc
$parsedTime = [DateTimeOffset]::MinValue
if ($observedAtUtc -isnot [string] -or $observedAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$' -or
    -not [DateTimeOffset]::TryParse($observedAtUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsedTime)) { throw 'observedAtUtc 必须为有效 ISO UTC 时间字符串。' }
if ($inventory.directChildPaths -isnot [array] -or $record.exclusions -isnot [array] -or $record.groups -isnot [array]) {
    throw 'directChildPaths、exclusions 和 groups 必须为数组。'
}
$directPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in $inventory.directChildPaths) {
    $canonical = ConvertTo-DirectChildPath $path
    if (-not $directPaths.Add($canonical)) { throw "枚举路径重复：$path" }
}
$excludedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($exclusion in $record.exclusions) {
    if ($exclusion -isnot [Collections.IDictionary]) { throw '每个排除项必须为对象。' }
    foreach ($field in @('path', 'category', 'reason', 'evidence')) {
        if (-not $exclusion.Contains($field)) { throw "排除项缺少字段：$field" }
    }
    if ($exclusion.category -isnot [string] -or $exclusion.category -cnotin @('userProfile', 'compatibilityLink', 'folderAppearance', 'pagingFile', 'bootRecovery', 'volumeMetadata')) {
        throw '排除项 category 无效。'
    }
    if ($exclusion.reason -isnot [string] -or [string]::IsNullOrWhiteSpace($exclusion.reason) -or
        $exclusion.evidence -isnot [array] -or $exclusion.evidence.Count -eq 0) { throw '排除项必须包含非空 reason 和 evidence 数组。' }
    foreach ($evidence in $exclusion.evidence) {
        if ($evidence -isnot [string] -or [string]::IsNullOrWhiteSpace($evidence)) { throw 'evidence 每项必须为非空字符串。' }
    }
    $canonical = ConvertTo-DirectChildPath $exclusion.path
    if (-not $directPaths.Contains($canonical)) { throw "排除项不在 inventory 中：$canonical" }
    if (-not $excludedPaths.Add($canonical)) { throw "排除项重复：$canonical" }
}
$ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$memberOwners = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$pending = [System.Collections.Generic.List[object]]::new()
$byId = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($group in $record.groups) {
    if ($group -isnot [System.Collections.IDictionary]) { throw '每个集合必须为对象。' }
    foreach ($field in @('id', 'name', 'members', 'auditStatus')) {
        if (-not $group.Contains($field)) { throw "集合缺少字段：$field" }
    }
    if ($group.id -isnot [string] -or [string]::IsNullOrWhiteSpace($group.id) -or
        $group.name -isnot [string] -or [string]::IsNullOrWhiteSpace($group.name)) {
        throw '集合的 id 和 name 必须为非空字符串。'
    }
    if (-not $ids.Add($group.id)) { throw "集合编号重复：$($group.id)" }
    if ($group.auditStatus -isnot [string] -or $group.auditStatus -cnotin @('pending', 'reviewed', 'deferred')) { throw "无效审查状态：$($group.id)" }
    if ($group.members -isnot [array] -or $group.members.Count -eq 0) { throw "集合必须有成员：$($group.id)" }
    foreach ($member in $group.members) {
        if ($member -isnot [string] -or [string]::IsNullOrWhiteSpace($member) -or
            -not [System.IO.Path]::IsPathFullyQualified($member)) { throw "成员必须为绝对路径：$($group.id)" }
        $canonicalMember = ConvertTo-DirectChildPath $member
        if ($excludedPaths.Contains($canonicalMember)) { throw "成员与排除项重叠：$canonicalMember" }
        if ($group.auditStatus -cne 'reviewed' -and -not $directPaths.Contains($canonicalMember)) {
            throw "未完成集合的成员不在 inventory 中：$canonicalMember"
        }
        if ($memberOwners.ContainsKey($canonicalMember)) { throw "成员在集合中重复：$canonicalMember" }
        $memberOwners.Add($canonicalMember, $group.id)
    }
    $byId.Add($group.id, $group)
    if ($group.auditStatus -ceq 'pending') { $pending.Add($group) }
}
foreach ($path in $directPaths) {
    if (-not $excludedPaths.Contains($path) -and -not $memberOwners.ContainsKey($path)) { throw "已枚举子项尚未分配：$path" }
}
$pending.Sort([System.Comparison[object]]{
    param($left, $right)
    $comparison = [System.StringComparer]::OrdinalIgnoreCase.Compare([string]$left.name, [string]$right.name)
    if ($comparison -ne 0) { return $comparison }
    return [System.StringComparer]::Ordinal.Compare([string]$left.id, [string]$right.id)
})

$preferred = [System.Collections.Generic.List[object]]::new()
$preferredIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($id in $PreferredId) {
    if (-not $byId.ContainsKey($id)) { throw "点名编号不存在：$id" }
    if ($byId[$id].auditStatus -cne 'pending') {
        throw "点名集合 $id 已审查或待单独展开；请按追问或展开流程处理。"
    }
    if ($preferredIds.Add($id)) { $preferred.Add($byId[$id]) }
}
$ordered = [System.Collections.Generic.List[object]]::new()
foreach ($group in $preferred) { $ordered.Add($group) }
foreach ($group in $pending) {
    if (-not $preferredIds.Contains($group.id)) { $ordered.Add($group) }
}
$selected = @($ordered | Select-Object -First $Limit)
if ($SummaryOnly) { $selected = @() }
$deferredPreferred = @($preferred | Select-Object -Skip $Limit | ForEach-Object { $_.id })
$candidateScope = $inventory.status
[ordered]@{
    schemaVersion = 2
    source = $inputItem.FullName
    candidateScope = $candidateScope
    inventoryObservedAtUtc = $observedAtUtc
    directChildCount = $directPaths.Count
    directChildCountIsLowerBound = $inventory.status -ceq 'partial'
    defaultExcludedCount = $excludedPaths.Count
    includedDirectChildCount = $directPaths.Count - $excludedPaths.Count
    groupCount = $record.groups.Count
    reviewedCount = @($record.groups | Where-Object { $_.auditStatus -ceq 'reviewed' }).Count
    deferredCount = @($record.groups | Where-Object { $_.auditStatus -ceq 'deferred' }).Count
    limit = $Limit
    sort = 'preferred-input-order, name-OrdinalIgnoreCase, id-Ordinal'
    pendingCount = $pending.Count
    selectedCount = $selected.Count
    remainingPendingCount = $pending.Count - $selected.Count
    deferredPreferredIds = $deferredPreferred
    selected = $selected
} | ConvertTo-Json -Depth 100
