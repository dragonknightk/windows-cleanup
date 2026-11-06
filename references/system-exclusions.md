# 批量审查的系统基础项筛选

常规父目录批量审查在归组前应用本规则。先用直接子项的元数据和已有证据确定范围，让需要用户判断的软件、文件和目录进入候选。用户明确点名的对象或系统范围优先纳入；后续“下一批”沿用当前决定。

## 默认排除的六类对象

Agent 判断系统身份，脚本负责清单一致性、计数与选批。`category` 是 [会话记录](tools.md) 中的类别值。

| 类别与 `category` | 常见对象 | 足以支持默认排除的关系 |
|---|---|---|
| 用户配置基础文件 `userProfile` | `NTUSER.DAT`、`UsrClass.dat` 及其配套日志、事务、配置文件 | 已确认的 Windows 用户配置位置、正确的文件类型及明确的配套关系。用户配置根目录和 `AppData\Local\Microsoft\Windows` 的角色结合实际用户位置确认 |
| 系统兼容目录链接 `compatibilityLink` | `Application Data`、`Local Settings`、`My Documents`、`SendTo` 等兼容入口 | 对象确为系统兼容链接，所在位置与链接目标符合该用户的已知 Windows 目录映射；同时支持系统本地化名称 |
| 文件夹显示配置 `folderAppearance` | `desktop.ini` | 所在目录、类型、属性及必要的有限配置读取能够确认它用于图标、显示名称等正常文件夹配置 |
| 系统分页文件 `pagingFile` | `pagefile.sys` | 实际路径与系统当前使用的分页文件相符，可按需用 `Win32_PageFileUsage` 等只读配置证据确认 |
| 当前系统启动与恢复文件 `bootRecovery` | 引导文件、启动配置、Windows 恢复环境文件 | 路径和系统启动或恢复配置能证明当前用途；必要时按范围查看 `bcdedit /enum` 或 `reagentc /info` 的只读结果 |
| 卷管理基础目录 `volumeMetadata` | 卷根目录下的 `System Volume Information` | 已确认的卷根位置、目录类型及系统用途相符；目录内部的还原、快照等空间管理留给相关专项审查 |

系统位置按当前机器和用户实际配置定位，不硬编码用户名或假定所有配置都在 C 盘。普通资料目录中的同名副本、无法确认配套关系的日志、目标不符的链接继续保留为候选。

隐藏、系统属性、微软名称、文件扩展名及目录名只是线索。不能用所有隐藏项、所有重解析点、`*.dat`、`*.log` 等宽泛条件替代身份判断。`AppData`、`ProgramData`、文档、下载、软件配置和共享运行库继续保留审查入口；实际复杂时按批量规程单独展开。临时文件、缓存、旧安装材料和回收站内容保留清理审查入口。

## 筛选的工作量与顺序

1. 首次概览使用 `Get-DirectoryOverview.ps1` 的默认浅层模式，保留直接子项、属性与 `linkTarget`。此时不采样各子目录的内容。
2. 先应用本会话已经明确的纳入范围，再按表中关系识别系统基础项。必要身份核对限于定位、元数据和相关系统配置；不为决定排除而完成一套深入审查。
3. 将已确认的排除对象写入 `exclusions`，保存实际路径、类别、简短理由与必要证据。其他直接项进入 `groups`；来源未知时可暂作独立集合。只将组成员计入选批范围。
4. 选定最多 10 个集合后，再按本批对象进行有限目录概览或深入取证。系统链接只检查入口及目标字符串；实际数据目录按其自己的路径与用户选择处理。

发现元数据与系统惯例有实质冲突时，保留候选并说明具体疑点。没有充分身份依据时正常进入审查流程，不把未知对象隐藏起来。

## 用户点名与范围变化

用户说“看看被排除的项目”时，提供对应名单、类别和排除依据。用户要求审查某项时，从 `exclusions` 移入 `groups`，记录这项用户决定，分配或复用稳定编号，并按固定五项交付；不重复确认已明确的审查请求。用户要求将系统项整体纳入时同样应用批次上限。

泛指“审查这个父目录”“下一批”沿用常规筛选。用户已经明确指定系统目录本身或明确包含系统项时，按其目标确定范围；重新概览时保留用户已作出的纳入决定。

默认排除记录与 `reviewed`、`deferred` 分别管理。它只表示本轮的范围选择。清理仍按用户授权、已审处理范围和清理规程执行完整预检，并独立确定保护路径。

## 系统空间专项入口

用户明确要求检查系统占用或优化磁盘空间时，结合当前发现提示可审查休眠文件、还原点等相关系统占用，由用户选择展开。分页、休眠、还原或恢复组件的调整按对应系统功能说明处理方式和影响。

例如：“系统基础项已按默认规则排除。若你还想检查系统占用，可以继续审查休眠文件、还原点等项目。”普通批量任务只提示与当前目标有关的后续动作。

## 报告与依据

报告只汇总实际排除类别及数量，完整名单留在调用任务记录，按需展示。排除项不需要五项报告，也不占每批 10 个集合名额。计数口径和不完整概览的表达见 [批量审查](batch.md)；零排除也明确显示。

以下官方资料用于理解系统角色，实际判断仍结合本次证据：

- [用户配置与 NTUSER.DAT](https://learn.microsoft.com/en-us/windows/win32/shell/about-user-profiles)、[UsrClass.dat 与配置加载](https://learn.microsoft.com/en-us/troubleshoot/windows-server/user-profiles-and-logon/desktop-location-unavailable)。
- [Windows 兼容目录链接](https://learn.microsoft.com/et-ee/windows/win32/vss/junction-points)、[desktop.ini 的用途](https://learn.microsoft.com/en-us/windows/win32/shell/how-to-customize-folders-with-desktop-ini)。
- [分页文件](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/how-to-determine-the-appropriate-page-file-size-for-64-bit-versions-of-windows)、[启动机制](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/boot-options-in-windows)、[Windows 恢复环境](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-recovery-environment--windows-re--technical-reference?view=windows-11)。
- [系统卷目录与还原点空间](https://devblogs.microsoft.com/oldnewthing/20181218-00/?p=100505)、[休眠文件](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/disable-and-re-enable-hibernation)。
