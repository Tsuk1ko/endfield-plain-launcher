# Endfield Plain Launcher

通过指定官方 `Games.exe` 为父进程启动《明日方舟：终末地》的 PowerShell 脚本。已有启动器进程时直接复用；没有时创建一个主线程保持挂起的官方进程，使游戏获得对应的父进程身份，而无需执行启动器的界面和业务初始化。

脚本不修改游戏或启动器文件，也不向它们注入代码。它仍然依赖已安装的官方启动器组件。

## 使用

从 [Releases](../../releases/latest) 下载 `Launcher.exe`，直接执行该程序即可

> [!NOTE]
> `Launcher.exe` 由 `Launcher.ps1` 通过 [PS2EXE](https://github.com/MScholtes/PS2EXE) 封装而来

| 参数           | 默认值   | 含义                                                                                    |
| -------------- | -------- | --------------------------------------------------------------------------------------- |
| `LauncherRoot` | 空字符串 | 启动器根目录，例如 `D:\Program Files\Hypergryph Launcher`。省略或为空时通过注册表查找。 |

指定安装目录：

```powershell
.\Launcher.exe -LauncherRoot 'D:\Program Files\Hypergryph Launcher'
```

传入的是包含 `Launcher.exe` 和版本子目录的**启动器根目录**，不是 `Games.exe` 所在的版本目录，也不是游戏目录。安装结构如下，其中版本号仅为示例：

```text
Hypergryph Launcher\
├── Launcher.exe
├── 1.6.0\
│   └── Games.exe
└── games\
    └── Endfield Game\
        └── Endfield.exe
```

正常退出游戏后由脚本完成启动器进程清理。

同一 Windows 会话内只允许运行一个 Endfield Plain Launcher 实例，直接运行脚本和封装后的 EXE 共用单实例锁。游戏退出并完成清理前，重复启动会静默返回，不显示重复运行提示。

## 父进程检测机制

以下说明来自 2026-10-16 对本机游戏组件的 REA 静态分析及已有启动日志，只描述当时追踪到的检查链，不代表所有版本或游戏中的全部检查。

游戏启动过程中，`U8SDK.dll` 调用 `OneChannelLC.dll` 执行启动检查。该检查会：

1. 通过进程快照取得当前游戏进程的父进程 PID。
2. 使用 `OpenProcess` 和 `QueryFullProcessImageNameW` 取得父进程的实际映像路径。
3. 将映像文件名与配置中的 `parentNames` 比较。
4. 校验对应磁盘文件的数字签名，并按配置中的 `fingerprints` 检查签名证书指纹。

已有日志中，父进程为 `explorer.exe` 时出现名称不匹配错误 `10100`；父进程为官方版本目录中的 `Games.exe` 时检查成功。因此，仅让启动器在后台运行并不充分，游戏创建时的父进程身份也是检查条件。仅将其他程序改名为 `Games.exe` 也不足以满足签名检查。

在已追踪的这条检查链中，未发现要求父进程显示窗口、响应通信或完成启动器初始化的条件。脚本据此利用真实官方进程的身份：挂起的进程仍然有 PID 和映像路径，其磁盘文件仍可接受签名验证。**这是方案的静态依据，不能据此保证游戏其他模块或后续版本也接受这种启动方式。**

此外，`U8SDK.dll` 在加载 `OneChannelLC.dll` 前还会验证其签名并比较签名相关信息；本脚本不修改这两个模块的检测逻辑。

## 脚本逻辑

### 1. 定位并检查路径

传入非空 `LauncherRoot` 时，直接使用指定目录，不读取安装目录或版本注册表。未传入或传入空字符串时，依次查找：

| 顺序 | 注册表位置                                                             | 使用的信息                                               |
| ---- | ---------------------------------------------------------------------- | -------------------------------------------------------- |
| 1    | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`             | 匹配启动器名称，读取 `InstallLocation`、`DisplayVersion` |
| 2    | `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall` | 同上                                                     |
| 3    | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`             | 同上                                                     |
| 4    | `HKCU\Software\HyperGryph\Launcher` 的直接子项                         | 读取 `install_path`                                      |
| 5    | `HKCR\hypergryphlauncher-abYeZZ16BPluCFyT\shell\open\command`          | 解析带引号的 `Launcher.exe` 路径，取得所在目录           |

注册表候选目录须包含 `Launcher.exe` 才会被接受。协议命令只作为文本解析，不会被执行。

确定根目录后，按以下优先级寻找 `Games.exe`，每个候选都须实际存在：

1. `<根目录>\<DisplayVersion>\Games.exe`，仅在通过卸载注册表取得版本时使用。
2. 读取根目录 `Launcher.exe` 的文件版本，取前三段拼接版本目录。例如 `1.6.0.1604` 对应 `1.6.0\Games.exe`。
3. 枚举根目录的直接子目录，将可解析为版本号且包含 `Games.exe` 的目录按数字版本降序排列，选择最高版本。此时会显示回退提示；`1.10.0` 会排在 `1.9.0` 前面。

游戏路径固定为 `<根目录>\games\Endfield Game\Endfield.exe`。脚本不搜索其他磁盘，也不提供独立游戏路径参数。根目录或任一程序无法找到时，会在创建或复用进程之前报错退出。

### 2. 优先复用已有的 Games.exe

脚本枚举当前会话中可读取的 `Games` 进程，通过进程句柄查询实际映像路径。候选路径必须与选定的 `Games.exe` 一致，或位于同一启动器根目录的另一个数字版本子目录中。

匹配后取得包含 `PROCESS_CREATE_PROCESS` 权限的句柄，再次核对路径和存活状态，供创建游戏进程使用。脚本本身按路径筛选，不额外执行证书验证；前述签名检查仍由游戏组件负责。

复用的进程不会被脚本挂起、恢复或结束。若匹配进程无法取得创建子进程所需的权限，脚本会报错。

### 3. 没有可复用进程时，创建挂起的 Games.exe

脚本调用 `CreateProcessW`，将官方 `Games.exe` 的完整路径作为应用程序路径，将其所在目录作为工作目录，并设置 `CREATE_SUSPENDED`（`0x00000004`）。

该标志使新进程的**主线程从创建起就处于挂起状态**，无需先让启动器运行再暂停它。脚本不会调用 `ResumeThread`，因此不会由该主线程执行启动器的用户态启动流程；Windows 仍会创建进程对象并执行相关系统操作。参见 [Process Creation Flags](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags)。

脚本保存新进程及线程句柄，并将 `ownsParent` 标记为真，用于区分本次创建的进程和借用的已有进程。

### 4. 指定父进程并启动游戏

脚本创建 `STARTUPINFOEX` 属性列表，通过 `UpdateProcThreadAttribute` 设置 `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`，其值为选定的 `Games.exe` 进程句柄。

随后调用 `CreateProcessW` 启动 `Endfield.exe`，设置 `EXTENDED_STARTUPINFO_PRESENT`（`0x00080000`），工作目录为游戏目录。游戏进程不带挂起标志，可以正常执行。父进程属性让 Windows 在创建游戏时采用指定的父进程，无需让挂起的 `Games.exe` 自己执行启动游戏的代码。参见 [UpdateProcThreadAttribute](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute)。

创建完成后释放临时属性列表和分配的内存，保留进程句柄用于等待及清理。

### 5. 等待游戏退出并清理

脚本对游戏进程句柄调用 `WaitForSingleObject`，超时参数为 `INFINITE`。线程等待内核发出进程退出信号，参见 [WaitForSingleObject](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject)。

游戏退出后读取并显示退出码，在 `finally` 中执行清理：

| 父进程来源         | 清理行为                                                             |
| ------------------ | -------------------------------------------------------------------- |
| 脚本新建的挂起进程 | 若仍存活，调用 `TerminateProcess`，最多等待 5 秒确认结束，再释放句柄 |
| 复用的已有进程     | 只释放脚本持有的句柄，保留该进程                                     |

游戏创建失败也会进入相同的清理流程。脚本通过持有的句柄操作本次进程，不按名称批量结束启动器。

## 使用边界

- 等待对象仅为直接创建的 `Endfield.exe`。如果游戏重新启动或把运行任务转交给另一个进程，脚本不会跟踪整个进程树。
- 路径推断针对上述安装结构。版本目录、注册表格式或游戏相对路径发生变化后，可能需要更新脚本；目录最高版本回退也无法判断某次更新是否已完整安装。
