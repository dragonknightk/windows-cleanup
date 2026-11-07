# 启动入口、服务、驱动与运行态归因

用于陌生启动项、卸载后后台活动、计划任务、服务与驱动残留。仍安装的软件优先使用正式卸载入口；取消自启动与卸载软件分别对应不同处理目标。

## 启动页不能代表全部入口

- **多源启动入口检查：** 检查命中对象对应的 User/Machine `Run`、`RunOnce`、Startup 文件夹和计划任务。任务管理器显示项还可能来自 AppX Manifest 中的 `StartupTask`。
- **状态记录与有效入口区分：** `StartupApproved` 是启用/禁用状态记录，不能独立证明实际启动入口存在。已禁用、手动启动、停止运行均不代表软件无用；有效 AppX 入口不能当坏路径删除。
- **新旧服务区分：** 同软件新旧服务并存时，用实际目标路径区分旧残留和有效服务。

```powershell
# $identityPattern 是依据目标身份准备的限定匹配模式，仅用于筛候选。
Get-CimInstance Win32_StartupCommand -ErrorAction Stop |
    Where-Object { ($_.Name, $_.Command -join ' ') -match $identityPattern } |
    Select-Object Name, Command, Location, User
```

- **查询覆盖说明：** 此查询不是完整启动项清单；查不到时按实际入口来源补查，不能据此宣称没有启动项。开始菜单快捷方式和文件关联见 [系统入口与文件关联](associations.md)。

## 服务与驱动：保存完整原值

```powershell
foreach ($className in 'Win32_Service', 'Win32_SystemDriver') {
    Get-CimInstance -ClassName $className -ErrorAction Stop |
        Where-Object { ($_.Name, $_.DisplayName, $_.PathName -join ' ') -match $identityPattern } |
        Select-Object @{Name='Class';Expression={$className}},
            Name, DisplayName, State, StartMode, PathName
}
```

- **保留原值与解析限制：** `PathName`/`ImagePath` 可能包含参数、环境变量、带空格路径或驱动专用路径形式。不得用空白切分后取首段，也不能对整条命令行直接 `Test-Path` 后判断坏服务。

解析时分别处理：

- **有配对引号的可执行路径：** 保留引号内完整路径和后续参数。
- **未加引号且含空格：** 记录歧义，结合服务配置、文件存在性和运行进程路径确认；不猜首词。
- **`%SystemRoot%`、`\SystemRoot\`、`\??\` 等形式：** 按其语义解析，不机械拼接当前目录。
- **`svchost.exe` 等宿主：** 继续查看该精确服务的 `Parameters\ServiceDll` 等配置和所属服务组。
- **驱动：** 同时核对服务登记、实际 `.sys`、设备/驱动包关系，不能仅删服务键或驱动文件。
- **路径读取被拒绝或变量未解析：** 记为未验证，不能归类为不存在。

- **驱动卸载与重启复查：** 驱动卸载按对应软件、设备和驱动包的正式机制处理，必要时重启后复查。重启前枚举仍显示、文件或登记已消失时，只记录暂态差异，不能提前宣布最终完成。虚拟网卡身份与有效绑定见 [系统入口与文件关联](associations.md)。

## 计划任务：从完整定义追到最终载荷

- **完整定义读取：** 任务名、摘要或 `Actions.Execute` 命中只产生候选；短词可能误撞系统任务。按完整 TaskPath 与 TaskName 定位，读取全部 Actions、Arguments、WorkingDirectory、Triggers、Principal 和设置；存在 COM Handler 时继续追踪 CLSID。

```powershell
# 两个变量均取自已定位任务，保留原始值。
$taskXmlText = Export-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
[xml]$taskXml = $taskXmlText
$taskXml.Task.Actions.OuterXml
$taskXml.Task.Triggers.OuterXml
$taskXml.Task.Principals.OuterXml
$taskXml.Task.Settings.OuterXml
```

- **递归展开引用链：** 递归展开引用关系：任务 → 解释器及参数 → 脚本 → 包装器 → 载荷与更新器。相对路径按任务工作目录、脚本逻辑或配置解释；不能默认相对于当前 PowerShell 目录。
- **只读解码与防循环：** 只读脚本与配置，不执行未知脚本；编码参数可离线解码后审阅，不直接调用。每发现新载荷路径，检查同目录组件及指向它的持久化入口，并记录已访问对象以防循环。
- **断点记录与候选边界：** 遇到动态生成路径、远程下载、无法展开的二进制包装器时记录断点，不能推断后续不存在。链条内所需补查围绕当前对象，独立的新软件对象按通用规程加入候选。

## 从运行现象反查实际调用者

```powershell
# $processId 是已定位 PID，不能使用只读自动变量 $PID 存目标编号。
$process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
$process | Select-Object Name, ProcessId, ParentProcessId, CreationDate, ExecutablePath, CommandLine
if ($null -ne $process) {
    Get-CimInstance Win32_Process -Filter "ProcessId = $($process.ParentProcessId)" -ErrorAction Stop |
        Select-Object Name, ProcessId, ParentProcessId, CreationDate, ExecutablePath, CommandLine
}
```

- **父进程校验与承载者线索：** 父进程可能已经退出或 PID 被复用，需对照创建时间和事件时间；无父进程信息不等于无宿主。`WmiPrvSE.exe`、服务宿主和 WebView2 是承载者线索，不能按进程显示名直接归罪或删除。
- **WMI 事件日志查询：** WMI 先查看异常时间附近的 `Microsoft-Windows-WMI-Activity/Operational`：

```powershell
# 只取与当前问题相关的短时间窗；日志不存在或无权限应保留错误。
Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-WMI-Activity/Operational'
    StartTime = (Get-Date).AddMinutes(-10)
} -MaxEvents 80 -ErrorAction Stop | Select-Object TimeCreated, Id, Message
```

- **WMI 与 WebView2 归因：** 结合 Operation、ClientProcessId、Provider 与对应时刻进程身份判断调用关系。单次错误日志不证明 CPU 异常的原因；事件不足时说明证据缺口，必要的短时追踪另定范围。WebView2 还需核对进程树、`--webview-exe-name`、`--user-data-dir` 与宿主安装身份；共享进程可能服务多个实例，不能仅凭一个父进程就删除共享运行时。

## 复查结论

- **状态分类与目标对齐：** 区分：入口已移除、载荷已处理、其他部署仍存在、有效组件保留、待重启及无法读取。保留历史状态不等于仍可启动，删除历史状态也不能替代删除实际入口。归因后返回软件身份与用户目标，选择正式卸载、仅取消启动或处理已确认残留。

参考：[服务类字段](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-service)、[任务 XML 导出](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/export-scheduledtask)、[WMI 高 CPU 诊断](https://learn.microsoft.com/en-us/troubleshoot/windows-server/system-management-components/troubleshoot-wmi-high-cpu-issues)。
