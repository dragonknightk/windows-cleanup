# 网页应用、浏览器元数据与 WebView2

用于 Windows 应用列表中的小型网页应用、重复网页入口及浏览器相关后台进程。
优先通过对应浏览器的应用管理入口或 Windows 正式卸载入口移除目标，再查残留。

## 先确定承载方式与身份

PWA 可能由浏览器托管，也可能与 Windows 包注册集成；不能要求所有 PWA 都有 AppX 包。
小体积、发布者为域名、入口名字普通仅是线索，不足以直接判定为 PWA。
若存在包，读取 PackageFullName、PackageFamilyName、Manifest、安装位置与启动参数；
再结合浏览器、用户配置目录、app id、start URL 形成身份链。
Manifest 中的 `HostId=PWA`、`--app-id` 等字段按实际存在情况取证，不能当跨版本固定契约。
同名入口可能来自不同浏览器、配置文件或历史包；同域名也可能同时存在网页与桌面应用。
包身份、app id、浏览器配置文件分别记录，不能只凭显示名或域名合并清理。

## 有限查询与 AppX 兼容性

先检测当前命令和模块，不默认切换到 Windows PowerShell 5.1。

```powershell
Get-Command Get-AppxPackage, Get-AppxPackageManifest -ErrorAction SilentlyContinue |
    Select-Object Name, Source, Version
Get-Module -ListAvailable Appx | Select-Object Name, Version, Path, CompatiblePSEditions
```

实际导入或调用提示 Appx 与当前 PowerShell 不兼容时，再确认系统存在 Windows PowerShell 5.1，
通过 `Import-Module Appx -UseWindowsPowerShell` 使用兼容会话；保存真实错误与使用的宿主。
无模块、无权限与没有匹配包分开报告，不能把兼容性失败当作已卸载。
兼容会话返回对象可能是反序列化对象，不能假定仍有原对象方法。

```powershell
# 命令已经可用；$packageNamePattern 为本轮限定的包名模式。
$packages = @(Get-AppxPackage -Name $packageNamePattern -ErrorAction Stop)
$packages | Select-Object Name, PackageFullName, PackageFamilyName, InstallLocation, Status
foreach ($package in $packages) {
    Get-AppxPackageManifest -Package $package.PackageFullName -ErrorAction Stop
}
```

本示例只查询当前用户；本轮不涉及其他用户时，不扩大为所有用户卸载或预配包处理。
不要手动移除 WindowsApps 或 AppModel 注册来替代正式包卸载。

## 卸载后的分层检查

| 层级 | 查什么 | 解释 |
| --- | --- | --- |
| 浏览器应用登记 | 对应配置文件中 app id 的安装状态 | 浏览器实际是否仍认为应用已安装 |
| Windows 集成 | 已发现的包、用户包目录、开始菜单、后台登记 | 仅检查该承载方式实际存在的部分 |
| 应用资源 | app id 对应的图标/Manifest 资源目录 | 可成为精确残留候选 |
| PWA 元数据 | 应用窗口、安装指标、链接处理等相关对象 | 确认当前版本结构及归属后处理 |
| 普通站点数据 | 权限、缩放、Cookie、登录、浏览历史等 | 与卸载网页应用独立的范围 |
| 浏览器/运行时 | 浏览器本体、更新服务、WebView2 | 不随某个 PWA 连带卸载 |

卸载 PWA 不自动包含清除同域名登录与网站设置。
即使一个元数据键包含目标域名，也须确认它绑定的对象及其他应用引用。
历史案例中的 `app_shims`、`link_handling_info`、`window_placement`、`install_metrics`
仅用于定位线索，不是可以跨浏览器、跨版本直接套用的删除键清单。

## 配置文件与 JSON 定点修改

从已知浏览器/应用命令行及实际配置位置定位用户数据目录，不默认只有 `Default`。
常见文件为用户数据根目录的 `Local State` 和具体配置文件目录的 `Preferences`。
需要处理多个配置文件时，分别确认归属；共享 Local State 的修改不得覆盖其他配置。

```powershell
# $preferencesPath 是已定位的精确配置文件；本示例只读解析与查看顶层结构。
$rawJson = Get-Content -LiteralPath $preferencesPath -Raw -ErrorAction Stop
$preferences = ConvertFrom-Json -InputObject $rawJson -AsHashtable -Depth 100 -ErrorAction Stop
$preferences.Keys | Sort-Object
```

采用正式卸载后仍有明确残留且需要直接修改时：

1. 记录精确文件与键路径，核对对象属于当前 app id/配置文件。
2. 关闭相关浏览器并确认写入者已退出；使用中的浏览器不可边运行边改配置。
3. 在本次任务记录目录保存可恢复副本，记录其位置，不复制到报告中。
4. 解析 JSON 后按对象路径删除指定项，保留其他字段；不得用字符串替换域名或 app id。
5. 按足够深度序列化到临时文件，检查可解析性与结构差异；深度截断或意外字段变化即停止替换。
6. 确认原文件未被其他写入者改变后替换；本任务不默认用哈希生成完整性材料。
7. 复查具体键、资源及应用登记，并确认非目标配置没有被改动。

JSON 文档结构不适合现有序列化工具无损修改时，换用能保留结构的方式或正式浏览器机制，
不能把能重新解析等同于所有字段语义都保持一致。
资源目录按 app id 精确处理，不删除整个 `Web Applications` 或整个浏览器用户目录。

## WebView2：查实际宿主

`msedge.exe` 可能是浏览器、PWA 或后台功能；读取参数及配置文件后分别判断。
`msedgewebview2.exe` 属于嵌入式 WebView2 运行时；它存在不证明目标 PWA 没卸载干净。
结合父进程链、时间、`--webview-exe-name`、`--user-data-dir` 与宿主安装信息归因。
同一用户数据目录和环境设置可能共享进程，父进程信息不足时保留未确认的消费者。
WMI/父进程查询示例见 [启动与后台组件](startup-runtime.md)。
宿主的 WebView2 用户数据可能含登录和应用状态，不将其整体称为可再生缓存。
保留仍有消费者的共享运行时；是否卸载宿主、关闭自启动或处理宿主数据按目标分别决定。

参考：[Windows PowerShell 兼容机制](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_windows_powershell_compatibility)、
[WebView2 进程模型](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model)。
