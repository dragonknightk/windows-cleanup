# 系统入口、文件关联与设备组件

用于坏快捷方式、URL 协议、打开方式、右键扩展、COM 及虚拟网卡残留。
完整软件先通过正式入口卸载，再检查具体登记和实际目标。

## 快捷方式与协议

同时考虑用户和全局开始菜单、桌面与 Startup；路径优先使用系统已知文件夹位置。
`.lnk` 需读取 TargetPath、Arguments、WorkingDirectory，而非仅看显示名。
普通 exe 快捷方式和 Shell/AppX 等特殊入口分开判断；目标为空不能一概算坏快捷方式。

```powershell
# $shortcutPath 是已定位的普通 .lnk 文件；只读，不保存快捷方式。
$shell = New-Object -ComObject WScript.Shell
$shortcut = $null
try {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut | Select-Object TargetPath, Arguments, WorkingDirectory, IconLocation
} finally {
    if ($null -ne $shortcut) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
    }
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}
```

URL 协议从 `Software\Classes\<scheme>\shell\open\command` 追踪执行目标。
读取键的 `URL Protocol` 标记、命令及相关委托配置；缺少传统 command 的入口可能走委托。
目标盘离线、网络不可达或目标读取失败时，不宣称入口已断链。
删除坏入口会改变菜单或双击行为，报告实际目标路径及影响，不只报入口数量。

## 文件类型、打开方式与右键扩展

| 位置/关系 | 含义 | 判断与清理粒度 |
| --- | --- | --- |
| `Software\Classes\.<ext>` 默认值 | 扩展名的 ProgID 引用 | 只处理指向目标软件的值 |
| `Software\Classes\<ProgID>` | 打开命令、图标等定义 | 追到具体程序及其他引用 |
| `OpenWithProgids` | 备选 ProgID | 按目标值名处理 |
| `OpenWithList` | exe 打开历史 | 处理目标值并维护 MRUList |
| `Explorer\FileExts\.<ext>\UserChoice` | 用户默认应用选择 | 优先系统默认应用界面/正式机制 |
| `shellex\ContextMenuHandlers` | 右键扩展 CLSID | 追到实际 DLL，不能只查 PATH |

`HKCR` 是合并视图，实际处理前定位 HKCU/HKLM 及相应注册表位数视图。
不要把删除整个扩展名键当作解除关联；其中可能有系统和其他软件的有效值。
不要伪造 `UserChoice` 保护值；解除目标坏关联与选择新的默认应用分别处理。
系统压缩包、ISO 默认处理程序及其他压缩软件项独立保留。

```powershell
# $progId 是从目标扩展名或卸载前记录得到的精确标识。
foreach ($root in 'HKCU:\Software\Classes', 'HKLM:\Software\Classes') {
    $commandKey = Join-Path $root "$progId\shell\open\command"
    if (Test-Path -LiteralPath $commandKey -ErrorAction Stop) {
        $key = Get-Item -LiteralPath $commandKey -ErrorAction Stop
        [pscustomobject]@{
            Key = $commandKey
            Command = $key.GetValue('', $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    }
}
```

此示例仅查当前进程视图中的普通打开命令，不覆盖所有委托、包应用和 32 位注册。
需要时显式使用 `RegistryView.Registry32`/`Registry64` 读取对应位置，记录实际视图。
清理后验证命令、图标、扩展名引用及右键处理器，不以主目录消失代替关联复查。

## COM 与 SDK

SDK 可能由其他软件私有安装；正式卸载后仍有 COM 注册，不代表可以整片删除厂商键。
沿 `ProgID → CLSID → InprocServer32/LocalServer32 → TypeLib` 追踪，
还应核对发现的 `AppID`、服务关联、版本及 32/64 位视图。
DLL/EXE 不存在是坏注册证据，但路径解析失败或权限不足不能视为不存在。
COM 指向另一软件私有目录时，先明确共享/嵌入关系，再决定是当前范围还是关联候选。
TypeLib、AppID 或共享 DLL 删除前，确认已知其他 CLSID/消费者不会因此失效。
不要仅凭一个 ProgID 命中就批量删除所有相关 GUID。
受保护注册表键不能直接套用扩大权限方案；按通用执行规程定位精确对象。

## 虚拟网卡、打印与驱动依赖

虚拟化、VPN、远控软件可能同时安装服务、驱动包、虚拟网卡和网络绑定。
适配器名字相似、处于断开或禁用状态，不足以认定是目标残留。
结合接口描述、PnP 设备身份、驱动提供者、软件安装状态及现有绑定判断。

```powershell
# 仅筛查与已知身份相关的适配器。
Get-NetAdapter -IncludeHidden -ErrorAction Stop |
    Where-Object { ($_.Name, $_.InterfaceDescription -join ' ') -match $identityPattern } |
    Select-Object Name, InterfaceDescription, InterfaceGuid, Status, ifIndex
```

查询结果还需关联设备/驱动信息；查不到 NetAdapter 不等于没有相关驱动包。
已有明确适配器后才查看其绑定，卸载使用软件或设备的正式机制，避免手工删 `.sys`。
共享隧道驱动可能由另一 VPN 使用；移除后会影响网络连通性，当前远程通道也需纳入影响判断。
打印驱动应核对打印机对象和 DriverName，离线打印机仍可能是用户有效设备。

## 历史与完成状态

AppCompat、MuiCache、FeatureUsage 与打开历史可用于来源判断，但不能证明软件仍运行。
文件名含 `.7z.exe` 的历史可能是自解压资产，不能作为压缩软件残留批量清除。
按目标分别报告坏入口、注册关系、设备组件和历史记录的状态。
驱动卸载有待重启结果时保留该状态；历史记录保留不妨碍运行层面已完成的结论。

参考：[HKCR 合并视图](https://learn.microsoft.com/en-us/windows/win32/sysinfo/hkey-classes-root-key)、
[Windows 默认应用设置](https://support.microsoft.com/en-us/windows/apps/change-default-apps-in-windows)。
