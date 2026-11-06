#requires -Version 7.2
<#
.SYNOPSIS
验证纯数据选批逻辑，所有文件均写入指定的测试工作目录。
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [System.IO.Path]::IsPathFullyQualified($TestRoot)) { throw 'TestRoot 必须为绝对路径。' }
$TestRoot = [System.IO.Path]::GetFullPath($TestRoot)
$skillRoot = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
if ($TestRoot.Equals($skillRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $TestRoot.StartsWith($skillRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw '测试目录必须位于调用工作区，处于 Skill 安装目录之外。'
}
$ancestor = $TestRoot
while ($ancestor) {
    if (Test-Path -LiteralPath $ancestor) {
        $ancestorItem = Get-Item -LiteralPath $ancestor -Force
        if (($ancestorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '测试目录及其祖先须使用直接路径，避免重解析点改变写入位置。'
        }
    }
    $parent = [IO.Directory]::GetParent($ancestor)
    $ancestor = if ($parent) { $parent.FullName } else { $null }
}
$caseRoot = Join-Path $TestRoot ('batch-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $caseRoot
$caseFile = Join-Path $caseRoot '候选[固定].json'
$scriptPath = Join-Path $PSScriptRoot 'Select-AuditBatch.ps1'
$checks = [System.Collections.Generic.List[string]]::new()
function Assert-Case([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "测试失败：$Name" }
    $checks.Add($Name)
}
function Write-Candidates($Groups) {
    $paths = @($Groups | ForEach-Object { $_.members } | Select-Object -Unique)
    Write-Record (New-Record $Groups $paths @())
}
function New-Record($Groups, $Paths, $Exclusions) {
    @{schemaVersion=2; currentParent=$caseRoot; inventory=@{observedAtUtc='2026-09-15T00:00:00Z'; status='complete'; directChildPaths=@($Paths)}; exclusions=@($Exclusions); groups=@($Groups)}
}
function Write-Record($Record) {
    $Record | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $caseFile -Encoding utf8
}
function Assert-Rejected([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert-Case $rejected $Name
}
$groups = @(1..13 | ForEach-Object {
    @{id = 'G{0:D3}' -f $_; name = '软件{0:D2}' -f (14 - $_); members = @((Join-Path $caseRoot "对象$_.bin")); auditStatus = 'pending'}
})
Write-Candidates $groups
$before = Get-Content -LiteralPath $caseFile -Raw
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case ($result.selectedCount -eq 10 -and $result.remainingPendingCount -eq 3) '默认最多十项'
Assert-Case ($result.schemaVersion -eq 2 -and $result.directChildCount -eq 13 -and $result.defaultExcludedCount -eq 0 -and $result.includedDirectChildCount -eq 13 -and $result.groupCount -eq 13 -and -not $result.directChildCountIsLowerBound) '零排除计数与版本'
Assert-Case (($result.selected.id -join ',') -eq 'G013,G012,G011,G010,G009,G008,G007,G006,G005,G004') '名称固定排序'
Assert-Case ((Get-Content -LiteralPath $caseFile -Raw) -ceq $before) '候选记录保持原内容'
$result = & $scriptPath -LiteralPath $caseFile -PreferredId G002,G001,G002 -Limit 3 | ConvertFrom-Json
Assert-Case (($result.selected.id -join ',') -eq 'G002,G001,G013') '点名优先并去重'
$allIds = @($groups | ForEach-Object { $_.id })
$result = & $scriptPath -LiteralPath $caseFile -PreferredId $allIds | ConvertFrom-Json
Assert-Case ($result.selectedCount -eq 10 -and ($result.deferredPreferredIds -join ',') -eq 'G011,G012,G013') '超过上限的点名留待后续'
Assert-Rejected { & $scriptPath -LiteralPath $caseFile -Limit 11 } '拒绝超限参数'
Assert-Rejected { & $scriptPath -LiteralPath $caseFile -PreferredId G999 } '拒绝未知编号'
$groups[0].auditStatus = 'reviewed'
$groups[1].auditStatus = 'deferred'
Write-Candidates $groups
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case ($result.pendingCount -eq 11 -and 'G001' -notin $result.selected.id -and 'G002' -notin $result.selected.id) '下一批沿用已审与待展开状态'
Assert-Case ($result.reviewedCount -eq 1 -and $result.deferredCount -eq 1 -and $result.groupCount -eq 13) '已审与待展开数量分别统计'
Assert-Rejected { & $scriptPath -LiteralPath $caseFile -PreferredId G002 } '展开目录通过独立流程处理'
$groups[2].members = @((Join-Path $caseRoot 'a.log'), (Join-Path $caseRoot 'b.log'))
Write-Candidates $groups
$result = & $scriptPath -LiteralPath $caseFile -PreferredId G003 -Limit 1 | ConvertFrom-Json
Assert-Case ($result.selectedCount -eq 1 -and $result.selected[0].members.Count -eq 2) '同组多文件只占一项'
Assert-Case ($result.directChildCount -eq 14 -and $result.includedDirectChildCount -eq 14 -and $result.groupCount -eq 13) '多文件归组保留直接项计数'
$groups[2].auditStatus = 'typo'
Write-Candidates $groups
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝未知审查状态'
$groups[2].auditStatus = 'pending'
$groups[3].id = $groups[2].id
Write-Candidates $groups
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝重复编号'
$groups[3].id = 'G004'
$groups[3].members = @($groups[2].members[0])
Write-Candidates $groups
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝重复归组成员'
$groups[3].members = @('relative.txt')
Write-Candidates $groups
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝相对成员路径'
Write-Candidates @()
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case ($result.selectedCount -eq 0 -and $result.selected.Count -eq 0) '空候选保持数组且不选项'
$ties = @(
    @{id='G002'; name='alpha'; members=@((Join-Path $caseRoot 'two')); auditStatus='pending'},
    @{id='G001'; name='Alpha'; members=@((Join-Path $caseRoot 'one')); auditStatus='pending'}
)
Write-Candidates $ties
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case (($result.selected.id -join ',') -eq 'G001,G002') '名称同序时按稳定编号排序'

$categories = @('userProfile','compatibilityLink','folderAppearance','pagingFile','bootRecovery','volumeMetadata')
$excluded = @($categories | ForEach-Object { @{path=(Join-Path $caseRoot $_); category=$_; reason='受控模拟身份判断'; evidence=@('受控模拟证据')} })
$record = New-Record @() @($excluded.path) $excluded
Write-Record $record
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case ($result.directChildCount -eq 6 -and $result.defaultExcludedCount -eq 6 -and $result.includedDirectChildCount -eq 0 -and $result.pendingCount -eq 0 -and $result.selected.Count -eq 0) '六类排除记录与全部排除'
$record.exclusions = @($excluded | Select-Object -Skip 1)
$record.groups = @(@{id='G001'; name='显式纳入'; members=@($excluded[0].path); auditStatus='pending'; userDecision='用户明确要求审查'; extra=@{keep=$true; time='2026-09-15T08:00:00+08:00'; empty=@(); absent=$null}})
Write-Record $record
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case ($result.defaultExcludedCount -eq 5 -and $result.includedDirectChildCount -eq 1 -and $result.pendingCount -eq 1 -and $result.selected[0].extra.keep -and $result.selected[0].userDecision -eq '用户明确要求审查') '用户显式纳入减少排除并保留集合扩展字段'
$rawResult = & $scriptPath -LiteralPath $caseFile
Assert-Case ($rawResult -match '2026-09-15T08:00:00\+08:00' -and $result.selected[0].extra.empty.Count -eq 0 -and $null -eq $result.selected[0].extra.absent) '扩展字段保留时间字符串与空数组及空值'
$result = & $scriptPath -LiteralPath $caseFile -SummaryOnly | ConvertFrom-Json
Assert-Case ($result.pendingCount -eq 1 -and $result.selectedCount -eq 0 -and $result.selected.Count -eq 0 -and $result.remainingPendingCount -eq 1 -and $result.deferredPreferredIds.Count -eq 0) '仅统计不启动下一批'
Assert-Rejected { & $scriptPath -LiteralPath $caseFile -SummaryOnly -PreferredId G001 } '仅统计拒绝非空点名'
$record.inventory.status = 'partial'
$record.candidateScope = 'ignored'
Write-Record $record
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case ($result.candidateScope -eq 'partial' -and $result.directChildCountIsLowerBound -and $result.directChildCount -eq 6 -and [DateTimeOffset]$result.inventoryObservedAtUtc -eq [DateTimeOffset]'2026-09-15T00:00:00Z') '部分枚举下界与时间且忽略旧范围字段'
foreach ($badStatus in @('unknown','error','Complete',42)) {
    $record.inventory.status = $badStatus
    Write-Record $record
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } "拒绝枚举状态 $badStatus"
}
$record.inventory.status = 'complete'
foreach ($badTime in @('yesterday','2026-02-30T00:00:00Z','2026-09-15T08:00:00+08:00',42)) {
    $record.inventory.observedAtUtc = $badTime
    Write-Record $record
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } "拒绝无效 UTC 时间 $badTime"
}
$record.inventory.observedAtUtc = '2026-09-15T00:00:00Z'
$record.exclusions = @($excluded)
Write-Record $record
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '排除项与集合冲突'
$record.groups = @()
$record.exclusions = @($excluded) + @($excluded[0])
Write-Record $record
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝重复排除'
$record.exclusions = @($excluded)
$record.inventory.directChildPaths = @($excluded.path) + @($excluded[0].path.ToUpperInvariant())
Write-Record $record
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝大小写别名重复枚举'
$record.inventory.directChildPaths = @($excluded.path | Select-Object -Skip 1)
Write-Record $record
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '排除项必须来自枚举'
$record.inventory.directChildPaths = @($excluded.path)
$record.exclusions = @($excluded | Select-Object -Skip 1)
foreach ($scope in @('complete','partial')) {
    $record.inventory.status = $scope
    Write-Record $record
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } "$scope 已知项不得漏组"
}
$record.exclusions = @($excluded)
$record.inventory.status = 'complete'
foreach ($badCategory in @('unknown','UserProfile')) {
    $excluded[0].category = $badCategory
    Write-Record $record
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } "拒绝排除类别 $badCategory"
}
$excluded[0].category = 'userProfile'
foreach ($badEvidence in @(@(), @(''), @('有效',42))) {
    $excluded[0].evidence = $badEvidence
    Write-Record $record
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝空或非字符串证据'
}
$excluded[0].evidence = @('证据')
$excluded[0].reason = ' '
Write-Record $record
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝空排除原因'
$excluded[0].reason = '原因'

$directoryPath = Join-Path $caseRoot '含多层子项的目录'
$null = [IO.Directory]::CreateDirectory((Join-Path $directoryPath 'sub'))
[IO.File]::WriteAllText((Join-Path $directoryPath 'sub/file.txt'), 'fixture')
$single = @(@{id='D001';name='目录';members=@($directoryPath);auditStatus='pending'})
$record = New-Record $single @($directoryPath) @()
Write-Record $record
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case ($result.directChildCount -eq 1 -and $result.groupCount -eq 1) '目录及其后代仅算一个直接项'
foreach ($badPath in @($caseRoot, (Join-Path $directoryPath 'sub'), (Join-Path ([IO.Path]::GetDirectoryName($caseRoot)) 'sibling'), 'relative')) {
    $record.groups[0].members = @($badPath)
    Write-Record $record
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } "拒绝非直属集合路径 $badPath"
}
$record.groups[0].members = @($directoryPath)
foreach ($badPath in @($caseRoot, (Join-Path $directoryPath 'sub'))) {
    $record.inventory.directChildPaths = @($badPath)
    Write-Record $record
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '枚举拒绝父目录本身与跨层路径'
}
$record.inventory.directChildPaths = @($directoryPath, (Join-Path $caseRoot './含多层子项的目录/'))
Write-Record $record
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '路径规范化后拒绝重复枚举'
$record.inventory.directChildPaths = @()
foreach ($status in @('pending','deferred')) {
    $record.groups[0].auditStatus = $status
    Write-Record $record
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } "$status 成员不得缺失于枚举"
}
$record.groups[0].auditStatus = 'reviewed'
Write-Record $record
$result = & $scriptPath -LiteralPath $caseFile | ConvertFrom-Json
Assert-Case ($result.directChildCount -eq 0 -and $result.groupCount -eq 1 -and $result.reviewedCount -eq 1 -and $result.pendingCount -eq 0) '保留已清理成员的已审历史集合'
$record.currentParent = 'relative'
Write-Record $record
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝相对父目录'
$record = New-Record $ties @($ties.members | ForEach-Object { $_ }) @()
$record.groups[1].members = @($ties[0].members[0].ToUpperInvariant())
Write-Record $record
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '跨集合大小写别名冲突'
foreach ($version in @(1, '2', $null)) {
    Write-Record @{schemaVersion=$version;candidateScope='complete';groups=@()}
    Assert-Rejected { & $scriptPath -LiteralPath $caseFile } "拒绝旧版或错误版本 $version"
}
Write-Record @{groups=@()}
Assert-Rejected { & $scriptPath -LiteralPath $caseFile } '拒绝未声明版本的旧记录'
[ordered]@{status='passed'; count=$checks.Count; checks=@($checks); fixtureRoot=$caseRoot} | ConvertTo-Json -Depth 6
