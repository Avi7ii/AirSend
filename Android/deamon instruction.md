# 角色设定
你是一个顶级的 Rust 跨平台系统级开发专家，精通 Android 底层机制 (NDK, 常驻 Root 守护进程开发)、Unix Domain Sockets (UDS) 进程间通信、异步网络编程 (Tokio) 以及文件 I/O。

# 项目背景 (Context)
我正在开发一个名为 **AirSend** 的项目，旨在打造一个基于 **LocalSend 协议**的 Android 无感/极简跨平台传输工具。
为突破 Android 严苛的后台限制，项目采用了 **“前端 App 壳 + 底层特权守护进程 (Daemon)”** 的 C/S 架构：
1. **前端 (Kotlin + libsu + Xposed - 已全部开发完成)**: 负责在 Android 系统层 Hook 剪贴板 (实现无感复制同步)、监听相册目录变动，并接管系统的分享菜单。前端不处理任何真正的网络协议。
2. **后端 (Rust Daemon - 本次你需要帮我开发的重点)**: 一个纯 Rust 编写的静态链接 ELF 二进制文件。前端 App 会利用 Root 权限将其释放到 `/data/local/tmp/airsend_daemon` 并以后台守护进程模式 (nohup) 常驻运行。

# 核心技术规范与通信协议
前端与后端的唯一通信桥梁是 **Unix Domain Socket (UDS)**。
- **Socket 地址**: 前端通过 Kotlin 的 `LocalSocket` 连接到名为 `airsend_ipc` 的地址。由于使用的是默认的 `LocalSocketAddress.Namespace.ABSTRACT`，在 Linux 底层它对应的是**抽象命名空间**（即路径前缀带有一个空字符 `\0`）。
- **指令格式**: 文本流，以换行符 `\n` 结尾。
    - 发送纯文本/剪贴板: `SEND_TEXT:<具体的文本内容>`
    - 发送绝对路径文件: `SEND_FILE:<文件的绝对路径>`
    - (可选备用) 接收 URI: `SEND_FILE_URI:<content://...>`
- **核心协议库**: 必须使用 Rust 生态中的官方认证库 `localsend` (crates.io 上的 `localsend`，版本 `0.2.2`，作者 wylited)。

# 你的任务 (Task)
请帮我从零构建这个 Rust Daemon 项目，并提供完整的代码和编译指南。请按以下模块输出你的回答：

## 1. 工程配置 (`Cargo.toml`)
- 包含必要的依赖：`tokio` (全特性)、`localsend` (核心协议)、`anyhow` (错误处理)、以及 `tracing` 家族 (`tracing`, `tracing-subscriber`, `tracing-appender` 用于将日志写入文件)。

## 2. 核心源码 (`src/main.rs`)
这是重中之重，代码需要满足以下逻辑：
- **日志系统**: 守护进程在 Android 底层崩溃是静默的，必须使用 `tracing-appender` 将日志无阻塞地输出到 `/data/local/tmp/airsend_daemon.log`。
- **UDS 监听器**: 使用 `tokio::net::UnixListener` 绑定到抽象命名空间 `\0airsend_ipc`。请在代码注释中明确强调 `\0` 的重要性。
- **异步事件循环**: 能够并发处理前端发来的多个 UDS 连接请求，按行 (`BufReader::read_line`) 解析收到的指令。
- **协议层调用**: 解析指令后，调用 `localsend` crate 的相关 API：
    1. 使用 UDP Multicast 发现局域网内的 LocalSend 设备（比如我的 Mac）。
    2. 将剪贴板文本包装为虚拟文本文件，或者读取给定的文件绝对路径。
    3. 向目标设备发起标准的 LocalSend HTTP 传输握手并发送数据。

## 3. 交叉编译与部署指南
- 提供一份清晰的命令行指南，教我如何使用 `cargo-ndk` 将此 Rust 项目编译为 `aarch64-linux-android` 架构下的脱壳/静态链接 ELF 文件。

## 注意事项与防坑指南
- Android 的 Doze 模式可能会让网络部分休眠，但我们的 Rust 进程是 Root UID 0 级别，请确保 Tokio 的运行时能在此环境下稳定工作。
- 请给出健壮的错误处理逻辑，如果 `localsend` 找不到局域网设备，或者文件路径不可读，请在日志中输出 error，但**绝不能让守护进程 panic 崩溃**。

请深呼吸，仔细思考 `localsend` crate 的 API 结构（如 `discover_devices` 和 `LocalSendClient::send` 等大概逻辑），直接给我高质量的生产级代码！