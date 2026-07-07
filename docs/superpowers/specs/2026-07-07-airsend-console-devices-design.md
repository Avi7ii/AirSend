# AirSend 控制台 Devices 页设计

## 目标

把现有的 AirSend Settings 窗口升级成 `Open AirSend...` 控制台，同时保留当前 `Devices` 页面作为默认首页。第一版应该像是在现有界面上谨慎进化，而不是重新设计一个新应用。

这个控制台打开后要能一眼回答三个问题：

- AirSend 现在会发给哪台设备？
- 局域网发现和传输链路是否健康？
- 最近发生了什么？

## 范围

本次包含：

- 将状态栏菜单里的 `Settings...` 改为 `Open AirSend...`。
- 将窗口从设置窗口语义调整为 AirSend 控制台语义。
- 将侧边栏副标题从 `Settings` 改为 `Console`。
- 继续让 `Devices` 作为默认选中页面。
- 将侧边栏页面调整为 `Devices`、`Transfers`、`Clipboard`、`Diagnostics`、`Settings`。
- 保留现有 Devices 页内容和视觉语言。
- 在 `CURRENT TARGET` 上方加入一条紧凑的健康状态条。
- 将底部 `Actions` 区域替换为两列：`Quick Actions` 和 `Recent Activity`。

本次不包含：

- Dock 图标或普通 App 激活策略调整。
- 持久化传输历史存储。
- 完整 Diagnostics 页面实现。
- 重试队列、规则系统、可信设备管理或剪贴板历史。

## 交互设计

`Devices` 页面仍然是默认首页。页面副标题改为：

`Targets, discovery, health, and recent AirSend activity.`

在 `CURRENT TARGET` 卡片前新增顶部健康状态条：

- 左侧：绿色状态点和 `Ready`
- 中间：可见设备数量
- 右侧：最近一次预检摘要，例如 `Last check: HTTPS preflight OK`
- 右侧操作：`Run Diagnostics`

`Current Target` 和 `LAN Devices` 两个卡片应尽量保持现有外观，不移动核心目标选择和设备列表。

底部 `Actions` 卡片替换为：

- `Quick Actions`：保留现有 `Rescan`、`Add by IP`、`Broadcast` 控件。
- `Recent Activity`：展示三到五条紧凑事件。第一版可以来自 AppDelegate 中的轻量内存事件。如果没有事件，显示空状态。

## 架构

在现有设置窗口基础上扩展，不新增第二个窗口控制器。

主要文件：

- `AirSendSettingsWindowController.swift`：调整窗口标题，并在需要时确保关闭窗口只是隐藏/关闭窗口本身，不退出状态栏进程。
- `AirSendSettingsView.swift`：更新侧边栏、Devices 页面布局，并新增小型复用行/卡片组件。
- `main.swift`：重命名菜单项，并扩展 `AirSendSettingsSnapshot` 以承载健康状态和最近活动数据。

新增状态字段应进入 `AirSendSettingsSnapshot`，SwiftUI 视图不直接读取全局 App 状态。`AppDelegate` 继续作为运行时状态来源。

## 数据流

`AppDelegate` 构建 snapshot，包含：

- 当前目标标题和副标题
- 协议标签
- 可见设备数和已记住设备数
- 健康状态
- 预检摘要
- 最近活动行

`AirSendSettingsStore` 发布 snapshot。UI 操作尽量复用现有 action closure：

- `rescan`
- `addDeviceByIP`
- `selectBroadcastTarget`
- `sendClipboardNow`

第一版最近活动使用 `AppDelegate` 中一个有上限的内存列表。记录事件包括：

- 发现或更新设备
- 剪贴板文字/图片发送成功或失败
- 接收传输完成
- 手动重新扫描
- 兼容模式切换

活动记录不得保存剪贴板正文。

## 错误处理

健康状态条采用保守判断：

- `Ready`：存在可见设备，或最近没有传输错误。
- `Needs attention`：最近发生传输、预检或发现错误。
- `Searching`：没有可见设备。

`Run Diagnostics` 第一版可以触发重新扫描，并记录一条诊断活动。完整 Diagnostics 页面后续再做。

如果没有活动数据，显示空状态，不应导致窗口异常。

## 测试

手动验证：

- 打开状态栏菜单，确认 `Open AirSend...` 能打开窗口。
- 关闭窗口后，确认状态栏应用仍然存活。
- 确认 `Devices` 仍为默认页面，现有目标选择和设备操作可用。
- 确认窗口缩放时文本不重叠。
- 确认 Recent Activity 不显示剪贴板正文。

构建验证：

- 运行本仓库现有的 macOS Swift 构建或自测目标。

## 已批准参考

已批准方向：保留当前 Devices 页，在原位加入控制台元素。生成图片仅作为方向参考，不作为像素级实现源。
