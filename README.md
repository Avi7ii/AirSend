<p align="center">
  <img src="m3-icon-dynamic-rose.png" width="200" height="200" alt="AirSend Icon">
</p>

<h1 align="center">🚀 AirSend (macOS)</h1>

<p align="center">
  <img src="https://komarev.com/ghpvc/?username=Avi7ii&repo=AirSend&label=Views&color=007ec6&style=social" alt="Views">
  <a href="https://github.com/Avi7ii/AirSend/releases"><img src="https://img.shields.io/github/downloads/Avi7ii/AirSend/total?style=social&logo=github" alt="Total Downloads"></a>
  <a href="https://github.com/Avi7ii/AirSend"><img src="https://img.shields.io/github/stars/Avi7ii/AirSend?style=social" alt="GitHub stars"></a>
  <a href="https://github.com/Avi7ii/AirSend/releases/latest"><img src="https://img.shields.io/github/v/release/Avi7ii/AirSend?color=pink&include_prereleases" alt="Latest Release"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/Platform-macOS%2013%2B-blue.svg" alt="Platform: macOS"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.2-orange.svg" alt="Swift: 6.2"></a>
</p>

<p align="center">
  <a href="README_en.md">English</a> | <b>简体中文</b>
</p>

<h2 align="center">📖 你是否也和我一样？</h2>

你深爱着 Mac 丝滑的 UI 和卓越的生产力，但口袋里却揣着一部自由而强大的 Android 手机。

每当你想要把手机里的照片传到电脑，或者想要把手机上的验证码、链接瞬间同步到 Mac 剪贴板时，那道“生态围墙”便横亘在眼前：
*   **AirDrop**？那是 Apple 用户的内部狂欢，Android 只能在墙外张望。
*   **微信/QQ 传输助手**？为了传几个字节，你得忍受流量损耗、隐私扫描和繁琐的登录。
*   **官方 LocalSend**？虽然解决了连通性，但作为跨平台框架（Flutter）的产物，它在 Mac 上显得过于迟钝、臃肿，甚至连窗口圆角都和系统格格不入。

**直到 AirSend 的出现。**

---

<h2 align="center">🔥 AirSend：打破边界，回归本能</h2>

`AirSend` 是一款跨越生态鸿沟的“系统级增强”。我们坚信：**伟大的工具不应该抢夺用户的注意力。**

### 1. 零 UI 设计：它甚至没有一个多余的窗口
AirSend 彻底摒弃了繁琐的主界面。它的全部生命力都凝结在 macOS 菜单栏的一个小巧图标中。
没有复杂的菜单嵌套，没有沉重的面板。它像空气（Air）一样轻盈：
*   **拖拽即发**：直接扔给菜单栏图标，握手自动完成。
*   **静默守候**：只有在传输那一瞬间，它才会优雅地弹出微动画。

### 2. 剪贴板云同步：让 Android 具备“通用剪贴板”
这是 AirSend 的隐形必杀技。基于 LocalSend 协议的深度定制，它能实现**跨平台的剪贴板自动同步**。
当你手机复制了一段文字，Mac 剪贴板已瞬间更新。无需任何操作，两端就像共用了一个大脑。

---

<h2 align="center">💎 为什么选择 AirSend 而不是官方客户端？</h2>

我们在每一个像素 and 每一行代码上都进行了针对 macOS 的“重度”优化。

| 维度           | 官方客户端 (Flutter) | **AirSend (Native)**  | 评价                    |
| :------------- | :------------------- | :-------------------- | :---------------------- |
| **内存占用**   | ~300MB               | **~20MB**             | **15倍** 的资源效率提升 |
| **交互路径**   | 开启窗口 -> 点击发送 | **0路径 (拖拽即发)**  | 用户心智负担降至最低    |
| **启动速度**   | 等待框架初始化       | **微秒级即时启动**    | 原生二进制的绝对优势    |
| **UI 风格**    | 模拟组件，手感僵硬   | **100% 系统原生质感** | 毛玻璃与物理回弹动画    |
| **剪贴板同步** | 需手动确认/刷新      | **全自动后台同步**    | 真正的“隐形”科技        |
| **应用存在感** | 占 Dock 栏，占桌面   | **仅状态栏一个图标**  | 洁癖患者的终极答案      |

---

<h2 align="center">✨ 核心亮点 (Key Features)</h2>

*   **🔒 LocalSend 协议全兼容**：这是一切的基础。AirSend 可以与手机、Windows 上的官方 LocalSend 无缝互通。不需要改变你的跨平台生态。
*   **⚡ 性能怪兽**：基于 Apple 原生 `Network.framework`。针对碎片文件优化了并发 Socket 调度，GB 级大文件传输时磁盘 0 缓存。
*   **📂 智能归档**：它懂你的文件。手机发来的图片、文档、附件，AirSend 会帮你在后台自动分类入库。
*   **🚀 开机即用**：一次开启，永久化身为 Mac 的系统功能。

---

<h2 align="center">快速上手</h2>

1.  从 [GitHub Releases](https://github.com/Avi7ii/AirSend/releases/tag/v1.0) 获取 `AirSend.app`。
2.  拖入 `Applications` 文件夹，开启“开机自启”。
3.  安卓手机请下载 [官方 LocalSend 客户端](https://github.com/localsend/localsend/releases) 以实现完美互通。
4.  **从此，你甚至会忘了它的存在。** 因为当你需要发送文件时，它就在那里；当你不需要时，它就是空气。

---

<h2 align="center">🤝 贡献与反馈</h2>

如果您也觉得 Android 和 Mac 应该是天生一对，或者讨厌臃肿的工具，请点亮一个 🌟。

---

<p align="center">
  <b>AirSend</b> - <i>Simple is the new smart. AirDrop, but for everyone.</i>
</p>
