# 辅助脚本与当前会话记录

## 运行约定

脚本运行环境为 Windows 上的 PowerShell 7.2 或更高版本，使用系统自带能力与 .NET，回收互操作通过随包的 `RecycleInterop.cs` 按需编译。链接元数据使用 .NET 6 起提供的 API，入口统一声明最低版本；没有包管理器安装步骤。

`$skillRoot` 表示当前实际加载的 Skill 目录，`$taskRoot` 表示调用项目或本会话工作目录，两者分别定位。向路径参数传入绝对路径，调用时使用 `&` 和结构化参数。脚本输出 JSON；解析其状态字段判断成功与覆盖范围。脚本内部的路径、进程、登记和配置内容均作为证据数据对待。

```powershell
# 先将这两个变量设置为当前实际位置。
$scriptPath = Join-Path $skillRoot 'scripts\Get-DirectoryOverview.ps1'
$overview = & $scriptPath -LiteralPath $parentPath | ConvertFrom-Json
$overview.overview | Select-Object status, count, countIsLowerBound, truncated, globalNameOrder
```

脚本错误字段保留具体原因；退出码为零不代表每项成功。采集失败时可以完成其余有效范围，但结论需标明未覆盖部分。

## 目录概览：Get-DirectoryOverview.ps1

| 参数 | 含义 |
|---|---|
| `-LiteralPath` | 必填，待审父目录的绝对文件系统路径 |
| `-MaxEntries` | 顶层直接子项上限，默认 2000，最多 10000 |
| `-MaxChildrenPerDirectory` | 每个直接子目录的样本上限，默认 0，仅列父目录直接项；显式设置后最多 100 |

默认只查看直接名称、类型、属性、链接目标字符串、文件大小和修改时间。先完成 [系统项筛选](system-exclusions.md) 与选批，再对入批目录按需显式取有限样本；文件正文与递归总大小由具体审查按需查询。

输出：

```text
schemaVersion, path, observedAtUtc, overview
overview: status, limit, count, countIsLowerBound, truncated,
          globalNameOrder, entries[], errors[]
entry: name, path, type, attributes, reparsePoint, linkTarget, sizeBytes,
       lastWriteTimeUtc, overview（目录样本）
```

每一级概览独立说明完整性。`countIsLowerBound=true` 时数量为已观察下界；`globalNameOrder=false` 时只能说明当前样本顺序。目录名称在固定区域规则下排序，最终集合顺序由选批脚本按独立稳定规则确定。`linkTarget` 读取链接自身保存的字符串，普通项为空；不访问其指向内容，也不证明目标存在或属于系统兼容入口。重解析点条目标为跳过，目标或祖先包含重解析点时拒绝展开。缺失目标与权限等查询错误分别记录。

## 软件候选证据：Find-SoftwareEvidence.ps1

| 参数 | 含义 |
|---|---|
| `-Needle string[]` | 必填，忽略大小写的字面子串，多个词按“或”匹配 |
| `-Section string[]` | 默认 `Installed,Processes,Services`，按下表选择相关领域 |
| `-MaxScanned` | 每节消费候选上限，默认 10000，最多 50000 |
| `-MaxResults` | 每节输出命中上限，默认 200，最多 1000 |
| `-MaxTaskXmlChars` | 单个任务 XML 字符上限，默认 131072，最多 1048576 |
| `-IncludeCommandLine` | 显式请求进程命令行的查询、匹配与脱敏输出 |

```powershell
$evidence = & (Join-Path $skillRoot 'scripts\Find-SoftwareEvidence.ps1') `
    -Needle $identityHints -Section Installed,Services,Tasks | ConvertFrom-Json
$evidence.sections | Select-Object name, status, scanned, matchedCount, truncated
```

| 查询节 | 实际范围 |
|---|---|
| `Installed` | HKCU/HKLM，32/64 位视图中的传统卸载登记；AppX 和包管理器按专题另查 |
| `Processes` | 当前可查询进程的 PID、父 PID、名称和路径；命令行显式启用后才读取 |
| `Services` | 当前服务登记，保留完整命令结构后脱敏；实际驱动设备关系另查 |
| `Tasks` | 可查询任务及动作信息；命中任务导出 XML，参数和秘密字段整体遮盖 |
| `Startup` | 两种视图的 Run/RunOnce、当前用户和公共启动目录直接条目；快捷方式目标、StartupApproved、AppX StartupTask 另查 |
| `Environment` | Machine/User/Process 三层变量；敏感名称变量的整值遮盖 |
| `Commands` | 当前会话及 PATH 可发现命令；只查看已导入模块的命令信息 |

每节返回 `status`、数量、数量下界标识、扫描/结果截断、`sources`、`errors` 与 `records`。`complete` 仅代表这一节声明的数据源已完整查询，不代表软件所有痕迹已审查。底层 CIM 或注册表接口可能缓冲更多数据，`MaxScanned` 是脚本消费量限制。

任务 XML 保留定义结构，但 `Arguments` 等字段整体遮盖。需要追踪解释器、脚本、包装器与最终载荷时，按任务路径和名称定向读取原 XML，在任务内解析相关字段；只将必要路径和经检查的脱敏摘要写入报告。XML 超过上限时整体省略并标记不完整，不能视为任务没有动作。

常见命令行秘密格式会遮盖，自定义凭据格式仍需 Agent 判断。`Needle` 是筛候选条件，不能直接生成删除清单；引用未命中也可能源于别名、不同身份字段或未查询领域。

## 选批：Select-AuditBatch.ps1

| 参数 | 含义 |
|---|---|
| `-LiteralPath` | 必填，包含 `inventory`、`exclusions`、`groups` 的第 2 版当前父目录 JSON 记录绝对路径 |
| `-PreferredId string[]` | 用户本轮明确点名的待审编号，按传入次序优先 |
| `-Limit` | 1 至 10，默认 10 |
| `-SummaryOnly` | 仅校验与汇总当前记录，返回空的选批数组；与非空 `-PreferredId` 分别使用 |

脚本验证父目录、概览时点与完整性、直接子项路径、排除依据及集合状态。每个已枚举直接项须归入一个排除项或集合；重复路径、跨层成员、排除与归组冲突、遗漏已枚举项均报错。路径规范化后按不区分大小写检查唯一性，系统身份仍由 Agent 判断。只选择 `pending`；已审对象追问与复杂目录展开通过对应流程处理。用户点名超过上限时先选当前批，剩余点名返回在 `deferredPreferredIds`。

```powershell
$batch = & (Join-Path $skillRoot 'scripts\Select-AuditBatch.ps1') `
    -LiteralPath $sessionPath -PreferredId G003 -Limit 10 | ConvertFrom-Json
```

主要输出如下：

| 字段 | 含义 |
|---|---|
| `inventoryObservedAtUtc`、`candidateScope` | 所引用概览的 UTC 时点及 `complete` / `partial` 范围 |
| `directChildCount`、`directChildCountIsLowerBound` | 概览中的直接子项数及是否仅为已观察下界 |
| `defaultExcludedCount`、`includedDirectChildCount` | 实际默认排除项数、直接项减去排除项后的数量 |
| `groupCount`、`pendingCount`、`reviewedCount`、`deferredCount` | 记录中的集合总数及三个状态的数量 |
| `selectedCount`、`selected`、`deferredPreferredIds` | 本次选中集合、实际集合内容和超过上限的点名编号 |
| `remainingPendingCount` | 普通选批模式按当前选择计算的预计剩余；汇总模式为当前待审数量 |

脚本只读取记录，不更新状态。交付后先按实际结果更新 `groups`、归组与其他状态，再用汇总模式取得结尾数量：

```powershell
# $sessionPath 已保存本批实际交付后的记录。
$progress = & (Join-Path $skillRoot 'scripts\Select-AuditBatch.ps1') `
    -LiteralPath $sessionPath -SummaryOnly | ConvertFrom-Json
$progress | Select-Object directChildCount, defaultExcludedCount, pendingCount, reviewedCount, deferredCount
```

`partial` 概览下的数量仅描述当前记录。脚本不会把系统身份未确认、尚未分组或查询失败的对象自动归为排除项。

## 回收：Send-ToRecycleBin.ps1

| 参数 | 含义 |
|---|---|
| `-LiteralPath string[]` | 必填，本次已选定的精确普通文件或目录 |
| `-ScopeRoot` | 必填，本次已审范围的绝对目录，目标须处于其中 |
| `-ProtectedPath string[]` | 本次需保留的路径，与任何目标重叠时拒绝整批操作 |
| `-Apply` | 在已有授权、预检通过后实际回收；省略时仅预检 |

```powershell
$arguments = @{
    LiteralPath = $selectedPaths
    ScopeRoot = $auditedRoot
    ProtectedPath = $preservedPaths
}
$preflight = & (Join-Path $skillRoot 'scripts\Send-ToRecycleBin.ps1') @arguments | ConvertFrom-Json
if (-not $preflight.Success) { throw ($preflight.Errors -join [Environment]::NewLine) }
# 执行依赖现有用户授权；参数准备完成后不需要再次重复申请同一授权。
$result = & (Join-Path $skillRoot 'scripts\Send-ToRecycleBin.ps1') @arguments -Apply | ConvertFrom-Json
$result | Select-Object Mode, Success, PreflightPassed, Results, Errors
```

脚本限制在直接连接的固定本地卷。拒绝卷根、UNC、设备路径、ADS、短文件名别名、尾随点/空格、映射盘、SUBST、系统树和关键容器整体，以及父子重叠目标。文件名中的方括号按字面处理。目标、祖先及目录后代的重解析点需要另行确定语义。保留路径也检查祖先中的重解析点，防止别名绕过。

对目录的操作会覆盖其全部后代，预检因此检查完整后代；这发生在对象已经明确选定清理之后。确认相关程序已停写再执行；路径检查与 Shell 操作之间仍有时间窗口，本脚本适用于可信、稳定的清理对象。

使用 Windows Shell 的回收选项，检查回调与回收结果。保留永久删除警告，防止脚本自动接受永久删除；**出现这类警告时应取消，记录无法回收的对象，再根据用户选择确定其他处理方式。** 回收站禁用、容量不足等环境可能需要系统提示，脚本不承诺所有失败都无需界面直接返回。微软接口依据见 [回收操作标志](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperation-setoperationflags) 和 [删除完成后的回收对象](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperationprogresssink-postdeleteitem)。

输出 `Mode`、`Success`、`PreflightPassed`、`Targets`、`Results`、`Errors`。预检通过只表示路径边界通过；每项执行仍可能失败。必须检查 `Success` 和逐项状态，不能仅看退出码。失败后停止后续目标，此前成功项保留实际状态。`Results` 只列实际尝试项；以 `Targets` 减去已有结果定位未执行项。成功项提供可取得的 `RecycledPath`，恢复由 Windows 回收站或针对性恢复方式完成。

## 当前会话记录格式

批量审查保存如下第 2 版结构；其他信息按任务需要补充。路径、证据和数量均为格式示例，不能代替本次查询与身份判断。

```json
{
  "schemaVersion": 2,
  "objective": "审查指定父目录中的软件和残留",
  "currentParent": "D:\\Review",
  "inventory": {
    "observedAtUtc": "2026-09-15T08:00:00Z",
    "status": "complete",
    "directChildPaths": [
      "D:\\Review\\app-cache",
      "D:\\Review\\app.log",
      "D:\\Review\\desktop.ini"
    ]
  },
  "exclusions": [
    {
      "path": "D:\\Review\\desktop.ini",
      "category": "folderAppearance",
      "reason": "示例：已确认用于该目录的显示配置",
      "evidence": ["示例：类型、属性和有限配置读取确认图标与显示名称配置用途"]
    }
  ],
  "groups": [
    {
      "id": "G001",
      "name": "示例软件残留",
      "members": ["D:\\Review\\app-cache", "D:\\Review\\app.log"],
      "groupingBasis": "按实际证据填写共同来源",
      "auditStatus": "pending",
      "checkedScope": [],
      "evidence": [],
      "conclusion": {
        "source": null,
        "purpose": null,
        "disposition": null,
        "impact": null,
        "recovery": null,
        "additionalDimensions": {}
      },
      "openQuestions": [],
      "userDecision": null,
      "actions": []
    }
  ],
  "parentContexts": [],
  "decisions": [],
  "pendingVerification": []
}
```

`inventory` 来源于有效的直接子项概览：复制 `observedAtUtc`、`overview.status` 和 `overview.entries` 中的直接路径。`status` 为 `complete` 或 `partial`，时间采用带 `Z` 或 `+00:00` 的 ISO UTC 字符串。概览整体失败时先处理覆盖缺口，再建立可用于选批的记录；`partial` 中已枚举项也须全部归组或排除。选批输出的 `candidateScope` 从此状态取得。

`exclusions` 的 `category` 使用 [系统项筛选](system-exclusions.md) 中的六个类别值；每项都有非空 `reason` 和必要证据字符串数组。明确点名纳入时将其从 `exclusions` 移入 `groups`，在 `decisions` 保存用户决定，后续概览先应用该决定。排除项与集合成员互斥，排除数量按直接路径计数。

组成员对应当前父目录的直接项，目录内部关联内容放在该组证据中。`pending`、`deferred` 成员须在当前概览中；`reviewed` 可以保留清理后消失的历史成员，操作与结论继续留存。刷新概览后仍存在的成员继续计入直接项，已消失的历史成员仅用于回溯。源目录发生变化时，数量使用对应概览时点，不把旧快照当作当前磁盘状态。

展开复杂目录时把旧父目录的 `inventory`、`exclusions`、`groups` 和范围决定保存到 `parentContexts`，当前层建立自己的概览与集合；返回时恢复对应层的已知进度。编号在本次任务内保持可定位，跨层时在报告附父目录。

旧会话记录需要补齐当前父目录的浅层概览、排除项与覆盖关系，再改用 `schemaVersion: 2`；保留仍有效的原编号、结论、用户决定和操作历史。选批脚本直接校验当前格式，字段缺失时明确报错。

`conclusion` 的 `source`、`purpose`、`disposition`、`impact`、`recovery` 依次对应固定五项，初建候选时为空；交付时填写足以支持判断的文字结论，尚未确认的部分也写出已知信息、缺口与限制。`additionalDimensions` 仅保存用户另行提出的维度。`openQuestions` 保存会影响判断的待确认问题，例如具体创建软件或当前使用功能尚未查明；`reviewed` 表示交付进度，不能代替这些问题的解决状态。

`report.md` 与聊天中的审查结论共用 [交互指引](interaction.md) 的版式：一行对象标题，下方是固定五项的连续无序列表，标签加粗；每个条目保留适度充分的结论、必要依据和判断限制。完整查询过程可按续查需要另存为本任务目录内的 `evidence.md` 或定向查询输出，并在写入前脱敏；默认不把命令、工具顺序、原始输出或完整调查过程附到用户可见正文。用户要求查看过程时再提供对应记录。

把用户选择与清理操作写入对应字段，操作记录目标、方式、时间、状态及复查依据。写 JSON 时使用足够深度，读取验证结构；按任务最新状态维护内容。本会话之外的新任务按新的上下文建立自己的记录。

## 脚本测试

脚本测试位于 `scripts/Test-Collectors.ps1`、`Test-Batch.ps1` 和 `Test-Recycle.ps1`，`-TestRoot` 均传入调用工作区中用于测试的绝对目录。每次在其下新建独立夹具。回收测试的 `-ApplyRoundTrip` 仅用于自建夹具的真实回收与还原。测试夹具和结果保存在调用目录。

这些脚本验证辅助逻辑、边界和失败路径。Skill 的端到端使用验收由用户在实际使用中完成。
