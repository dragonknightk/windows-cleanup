# 环境变量与命令入口

用于开发工具卸载、旧版本工具链与环境变量整理。软件仍安装时先确认正式卸载入口；环境变量处理围绕卸载结果与用户选定目标开展。

## 三个层级分别判断

| 层级 | 含义 | 复查重点 |
| --- | --- | --- |
| Machine | 系统持久环境，通常位于 HKLM | 系统原值及指定项是否已更新 |
| User | 当前用户持久环境，通常位于 HKCU | 用户原值及指定项是否已更新 |
| Process | 当前进程继承后可能再修改的副本 | 当前终端或宿主是否仍保留旧值 |

- **进程继承与刷新验证：** Process 中有旧值不能证明持久层修改失败；子进程也不能反向修改父进程环境。新建子进程通常继承其父进程，因而在旧终端里再启动 `pwsh` 不足以证明刷新成功。需从已刷新环境的宿主启动新终端，必要时重启相关应用或重新登录，并报告待生效范围。

```powershell
foreach ($scope in 'Machine', 'User', 'Process') {
    [pscustomobject]@{
        Scope = $scope
        Path = [Environment]::GetEnvironmentVariable('Path', $scope)
    }
}
```

- **按需读取与密钥保护：** `JAVA_HOME`、`MAVEN_HOME`、SDK 位置等只读本次已知相关变量，不输出整个环境中的密钥。

## PATH 项目的判断

保留原字符串、层级和顺序，再生成用于比较的展开视图；比较结果不能直接覆盖原值。以下情况分别说明：

- **明确指向已删除软件目录的项：** 坏引用候选。
- **指向暂未挂载磁盘、网络位置或尚未展开变量的项：** 存在性未确定。
- **同层或跨层重复：** 需检查顺序与命令解析影响，不能自动移动到另一层。
- **旧版本目录：** 可能是并行工具链，结合项目和用户用途决定是否保留。
- **空段、相对路径或包管理器 shim 目录：** 单独解释解析含义与来源，不按普通绝对目录处理。

- **展开语义与原值保留：** 变量展开必须按目标环境理解；当前 Process 的展开结果可能仍引用旧变量。不能简单把 Machine 与 User PATH 拼接后当成所有应用真实使用的 PATH。整理只改变选定项目，保留其他项目原有顺序、可展开表达式和注册表值类型。

```powershell
# 只展开展示 User PATH 的片段；本示例不决定哪些项目可删除。
$rawPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -ne $rawPath) {
    $segments = $rawPath.Split(';')
    for ($index = 0; $index -lt $segments.Count; $index++) {
        [pscustomobject]@{ Index = $index; Raw = $segments[$index] }
    }
}
```

## 命令解析与功能影响

- **前后对比与同名命令保留：** 卸载前列出受影响命令及来源，卸载后检查当前结果是否仍来自目标安装实例。同名命令可能来自其他有效安装、别名、函数、Windows 应用执行别名或包管理器代理。保留有效的其他实现；不能要求所有同名命令在整台机器上消失。
- **禁止运行未知二进制探测：** 不要执行陌生二进制的 `--version` 作为默认识别手段。

```powershell
# $commandNames 是本次已确认相关的命令名数组。
foreach ($commandName in $commandNames) {
    try {
        Get-Command -Name $commandName -All -ListImported -ErrorAction Stop |
            Select-Object Name, CommandType, Source, Path
    } catch [System.Management.Automation.CommandNotFoundException] {
        [pscustomobject]@{ Name = $commandName; State = '当前会话未解析到' }
    }
}
```

- **查询边界与项目引用：** 这里的结果仅覆盖当前会话；查询发生其他错误时保留错误，不将其写成“无命令”。项目配置和 IDE 可直接引用工具路径；即使 PATH 干净，也应核对本轮已发现的这些引用。不为普通卸载额外扫描所有项目，只检查已知受影响项目或用户指定范围。

## 空变量与删除验证

- **存在性与空值区分：** 变量不存在与存在但为空是两个状态，特别是 PowerShell/.NET 版本变化时。不能仅凭 `SetEnvironmentVariable` 没有报错就宣称变量已彻底删除。必要时按值名查持久注册表，并保留类型与原始未展开内容。

```powershell
# $variableName 为本轮指定名称；本例检查 User 层。
$environmentKey = Get-Item -LiteralPath 'HKCU:\Environment' -ErrorAction Stop
$present = $environmentKey.GetValueNames() -contains $variableName
[pscustomobject]@{
    Name = $variableName
    Present = $present
    RawValue = if ($present) {
        $environmentKey.GetValue($variableName, $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } else { $null }
    Kind = if ($present) { $environmentKey.GetValueKind($variableName) } else { $null }
}
```

- **持久层核对与通知边界：** Machine 对应位置为 `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`。清理空值仅针对已确认无需保留的名称，修改后同时验证值名存在性与持久层内容。环境变化通知不能强制已运行程序重载，通知成功与实际生效分开报告。

参考：[PowerShell 环境变量文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables?view=powershell-7.5)。
