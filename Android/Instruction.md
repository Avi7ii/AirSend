# 无头(Headless) LocalSend 项目架构设计文档

## 1. 项目概述 (Overview)
本项目旨在基于 LocalSend Protocol v2 协议，构建一套**无感、极简、系统级整合**的跨平台局域网传输方案。摒弃传统 LocalSend 的臃肿 UI，将文件传输能力下沉为系统基础设施。

### 核心设计原则
*   **macOS 端**：原生化 (Native)，菜单栏驻留，深度集成。
*   **Android 端**：后台守护，root授权

---

## 2. 架构与功能规范 (Functional Specifications)

### 2.1 剪贴板同步 (Clipboard Sync)
> **目标**：实现 MacOS 与 Android 之间的双向、实时、无感剪贴板同步。

#### A. Android -> macOS (发送)
*   **触发机制**：**全自动系统级 Hook (LSPosed)**
    *   **实现原理**：开发 Xposed 模块注入 `com.android.server.clipboard.ClipboardService`。
    *   **拦截必须**：直接拦截 `setPrimaryClip` 方法，绕过 Android 10+ 后台读取限制。
    *   **流程**：用户复制 -> Hook 捕获 -> LocalSocket -> 守护进程 -> macOS。
*   **用户体验**：手机端任意 App 复制文字，Mac 端即刻收到通知并写入粘贴板。**零操作，无界面，无前台服务。**

#### B. macOS -> Android (接收)
*   **触发机制**：**后台监听 (NSPasteboard)**
    *   Mac 端应用监听系统粘贴板变化。
    *   **流程**：Mac 复制 -> HTTP POST -> Android 守护进程 -> Root 注入系统剪贴板。
*   **用户体验**：Mac 端复制，手机端即刻可用。

---

### 2.2 文件传输：Android -> macOS (Sending)
> **目标**：覆盖从“全自动同步”到“手动任意文件发送”的全场景，且不依赖主 App 界面。

#### Level 1: 魔法文件夹 (Magic Watch) - [全自动]
*   **功能**：后台守护进程通过 `FileObserver` 监听指定目录。
*   **默认配置**：
    *   `/sdcard/DCIM/Camera` (相机照片)
    *   `/sdcard/Pictures/Screenshots` (屏幕截图)
*   **行为**：一旦检测到新文件写入，立即自动发送至 Mac 默认下载目录。

#### Level 2: 幽灵分享 (Ghost Share) - [手动/任意文件]
*   **组件**：一个无 Launcher 图标的轻量级 APK。
*   **实现**：仅注册 `android.intent.action.SEND` Intent Filter。
*   **行为**：
    1. 用户在任意 App (如 MT管理器、图库) 点击“分享”。
    2. 选择 **“LocalSend (Daemon)”** 图标。
    3. Ghost Activity 启动 -> 获取文件 URI -> 将路径转发给守护进程 -> 立即关闭。
*   **场景**：传输任意位置的历史文件、文档或非多媒体文件。

---

### 2.3 文件传输：macOS -> Android (Receiving)
> **目标**：原生 macOS 体验。

*   **交互入口**：
    *   **菜单栏拖拽**：拖拽文件至 Menu Bar 图标即发送。
    *   **右键服务**：集成 Finder “共享” 菜单与 “服务” 菜单。
*   **接收逻辑**：
    *   **静默接收**：根据文件类型自动归档 (图片 -> Pictures，文档 -> Documents)。
    *   **通知**：仅在传输完成时发送系统原生通知。

---

## 3. 安卓端 (Configuration)
🛠️ 类 Scene 架构：Android 15 特权应用开发蓝图Scene 之所以能在 Android 极其严苛的后台限制下“为所欲为”，是因为它采用了一种 “前端 App 壳 + 底层特权守护进程 (Daemon)” 的 C/S（客户端/服务端）分离架构。如果你要开发剪贴板同步工具，必须完全抛弃传统 Android App 的开发思维，转而采用这种架构。1. 核心架构原理 (First Principles)Android 系统的限制（如 Doze 模式、后台剪贴板拦截）主要是针对 Zygote 孵化出来的普通 App 进程（UID 通常大于 10000）。破局点：如果你能以 root (UID 0) 或 adb shell (UID 2000) 的身份，在系统底层直接运行一个独立的二进制进程，这个进程将脱离 Android 框架层的生命周期管控。它不会被杀，网络不会被断，且能直接与系统的底层服务（Binder）对话。Scene 的标准工作流：用户打开 App UI。App 检查是否具有 Root 或 Shizuku 权限。App 将一个用 C/C++ 或 Rust 编译好的二进制文件 (Daemon) 释放到 /data/local/tmp 目录。App 利用 Root 或 Shizuku 权限，执行这个二进制文件。这个特权 Daemon 开始在底层常驻运行，并开启一个本地 Socket (LocalSocket) 或 WebSocket。App UI 通过 Socket 与底层的 Daemon 进行 IPC（进程间通信）。2. 你的剪贴板项目该如何模仿？要实现你的目标，你需要将项目拆分为两部分：Frontend (Kotlin) 和 Backend/Daemon (Kotlin/Rust/C++)。方案 A：极致极客版 (纯底层 Daemon)适合追求极限性能和 0 耗电的开发者。Backend (守护进程)：使用 Rust 或 C++ 编写。网络监听：在底层直接开启 TCP 5333 端口的监听。因为是 Root 进程，Android 的 Doze 模式管不到它，Mac 的 AirSend 随时可以连上。剪贴板操作：通过 C++ 直接调用 Android 底层的 binder 通信，向 clipboard 服务发送数据。通信机制：Mac -> TCP (5333) -> Rust Daemon -> Binder (系统剪贴板)。全程不需要启动你的 App UI。方案 B：主流开源方案版 (Java/Kotlin + Shizuku/libsu)开发成本更低，也是目前大多数 Root 工具（包括部分 Scene 功能）采用的模式。虽然我们不写 C++，但我们可以利用开源库在 Java 层模拟“特权进程”。依赖库推荐：Shizuku API (RikkaApps)：非 Root 提权的神器。libsu (topjohnwu)：Magisk 作者写的 Root 权限管理终极库。实现路径：利用 Shizuku 或 root，在后台启动一个独立的 Java 进程（注意：不是 Service，而是一个脱离 App 的独立进程）。1. 后台静默获取剪贴板 (Shizuku 提权)普通的 ClipboardManager 会拦截后台读取，但我们可以通过 Shizuku 以 shell (UID 2000) 的身份，直接与底层的 IClipboard 接口对话：// 伪代码：利用 Shizuku 反射获取底层的 IClipboard 接口
val clipboardService = ShizukuBinderWrapper(ServiceManager.getService("clipboard"))
val iClipboard = IClipboard.Stub.asInterface(clipboardService)

// shell 权限下，直接读取剪贴板，无视前后台状态！
val clipData = iClipboard.getPrimaryClip(pkgName, userId)
2. 突破 5333 端口的网络休眠通过 libsu 开启一个 Root 级的后台线程，在这个线程里跑一段轻量级的 HTTP Server 逻辑（可以用 Ktor）。当 Mac 推送文本过来时，这个 Root 线程接收数据，并利用上述的 IClipboard 接口强制写入剪贴板。3. 推荐的开源学习参考虽然 Scene 不开源，但有大量同样采用这种架构的优秀开源项目供你学习：Shizuku (RikkaApps)必看：这是你实现非 Root 模式的核心。仔细研究它的 API 文档和示例代码，看它是如何让一个普通的 Java App 拥有 Shell 权限去调用系统隐藏 API 的。libsu (topjohnwu)必看：如果你要做 Root 模式，这是行业标准。看里面的 NIO API 和 Root Services 部分。它提供了一种极为优雅的方式，让你用 Kotlin 写一个服务，然后以 Root 身份运行这个服务，完美解决了你需要的“底层常驻监听”问题。KDE Connect Android参考：开源界最著名的局域网互联工具。虽然它没有使用 Root 架构，但你可以去看看它的源码里是如何在正常的 Android 框架下痛苦地挣扎于剪贴板同步和网络唤醒的，这会让你深刻理解为什么要用 Shizuku/Root。Hail (冻结)参考：一款开源的冻结类应用，完美集成了 Root、Shizuku、设备管理员三种特权模式，代码非常干净，是学习“如何在一个 App 里同时兼容 Root 和非 Root 特权操作”的极佳模板。💡 总结你的开发路线用 Kotlin 构建你的 Android 工程。引入 libsu 库，创建一个 RootService。这个 Service 一旦启动，就是 UID 0 (Root) 级别。在这个 RootService 内部，启动一个简单的 ServerSocket 监听 5333 端口（接收来自 Mac 的握手）。在这个 RootService 内部，利用反射拿到 android.content.IClipboard，绕过上层权限检查，实现静默读写。引入 Shizuku API 作为备用方案，利用类似的代码逻辑服务非 Root 用户。


## 你需要做的

宏观工作流全景图

Phase 1: 构建核心网络引擎 (Rust Daemon)
这是整个方案的大脑，负责所有的网络协议和文件 I/O，完全用 Rust 编写。

初始化跨平台工程：

创建一个新的 Rust Binary 项目，引入 localsend-rs 作为核心依赖。

配置交叉编译工具链（推荐使用 cargo-ndk），目标架构主要为 aarch64-linux-android。

设计 IPC (进程间通信) 接口：

Rust Daemon 需要在本地建立一个 Unix Domain Socket (UDS) 监听（例如挂载在 /dev/socket/airsend_ipc 或 /data/local/tmp/airsend.sock）。

设定简单的内部指令集：当 LSPosed 模块或 Kotlin App 通过这个 Socket 传入文本或文件路径时，Rust Daemon 立即调用 localsend-rs 向 Mac 端发起传输。

实现截图监听 (File Watcher)：

在 Rust 内直接引入 notify crate。

监听 /sdcard/Pictures/Screenshots 目录。

物理直觉与防抖：不要监听文件创建 (Create)，必须监听 IN_CLOSE_WRITE（关闭写入）事件，以防止读取到大小为 0KB 或写入一半的损坏截屏文件。

编译与打包：

将项目编译为一个独立的 ELF 静态二进制文件（脱离所有 Android 动态库依赖）。

Phase 2: 开发宿主控制器 (Kotlin App 壳)
这是用户交互的入口，它的唯一生命周期使命是“释放并孵化”底层的 Rust Daemon。

环境探针与提权：

引入 libsu 库用于 Root 权限管理，引入 Shizuku API 作为备用提权通道。

在 App 启动时，检查当前环境的权限级别。

释放并运行 Daemon：

将 Phase 1 编译出的 Rust ELF 文件放在 Android 工程的 assets 目录下。

获取特权后，将 ELF 释放到 /data/local/tmp/airsend_daemon。

执行 chmod 755 赋予执行权限。

脱离生命周期：通过 Root Shell 以后台守护进程模式启动该二进制文件（例如使用 nohup 或将输出重定向到 /dev/null），确保即使用户在后台划掉 App，Rust Daemon 依然在底层奔跑。

Phase 3: 系统级拦截 (LSPosed 模块)
这是实现剪贴板“无感”同步的利器，工作在系统框架进程 (system_server) 内。

注入剪贴板服务：

在 Kotlin 工程中配置 Xposed API 依赖并声明 Meta-data。

寻找 Hook 目标：定位到 com.android.server.clipboard.ClipboardService 的 setPrimaryClip 方法。

极速数据转发：

拦截到剪贴板文本后，绝对不要在 Hook 方法里做任何耗时的网络操作（这会卡死整个系统 UI）。

立即建立一个 Client Socket，连接到 Phase 1 中 Rust Daemon 开启的 Unix Domain Socket，将文本内容“扔”过去，随后立即关闭 Socket 释放系统资源。

Phase 4: 降级方案与分享枢纽 (Ghost Share)
为了处理不支持 Hook 的长文本/任意文件，以及照顾未激活 LSPosed 的状态。

注册系统分享 Intent：

在 AndroidManifest.xml 中创建一个无 UI 的 GhostActivity，仅注册 android.intent.action.SEND 和 android.intent.action.SEND_MULTIPLE。

URI 解析与转发：

用户在图库或文件管理器点击“分享”到你的应用时，GhostActivity 瞬间启动。

提取 Intent 中的文件 URI，将其转换为真实的绝对路径。

通过 Unix Domain Socket 将路径发送给 Rust Daemon。

调用 finish() 瞬间关闭 Activity，实现“点击即发送，无界面阻断”的幽灵体验。

调试建议：
在开发初期，Native 进程的崩溃是静默的。建议在启动 Rust Daemon 时，将其 stdout 和 stderr 重定向输出到 /data/local/tmp/airsend.log 中，这样你可以直接通过 adb shell tail -f 来追踪网络协议握手和底层的执行状态。