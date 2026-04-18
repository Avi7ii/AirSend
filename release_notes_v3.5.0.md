## 中文

`v3.5.0` 把最近两条主线能力正式合并进发布版本：一条是菜单栏设置入口与设置窗口整理，另一条是 DropZone 拖拽链路的重构与稳定性修复。

这次更新的重点不是再堆新功能，而是把过去“能用但不稳”的关键体验补到可持续发布的状态：

- 菜单栏新增更清晰的设置入口，状态栏交互路径更完整。
- DropZone 的触发、锚点定位、显示隐藏与拖拽接管逻辑重新梳理，明显减少文件拖拽时的“弹回”“静默消失”“位置错乱”和窗口被裁切。
- 本地文件拖拽识别与 drag session 维持逻辑更稳，对访达拖拽、菜单栏附近预热和进入目标区后的接管更可靠。
- macOS、Android、Magisk 模块和运行时协议版本统一对齐到 `3.5.0`，发布产物与运行时代码保持一致。

### 主要改动

- 合入状态栏设置窗口分支改动，补齐菜单栏设置入口。
- 合入 DropZone 重构分支改动，修复窗口错误出现在屏幕中央、半截裁切、难以触发、拖拽松手无响应和高概率回弹等问题。
- 调整 DropZone 触发带、keepalive 区域和拖拽接管顺序，让状态栏附近更容易拉起 DropZone，同时离开目标区后也能正确收起。
- 刷新 macOS `.app`、Android APK、Magisk 模块版本号和模块元数据。

### 发布资产

- `AirSend-v3.5.0-macOS.zip`
- `AirSend_Magisk_v3.5.0.zip`

### 更新建议

- 建议更新最新的 Mac 版本。
- Magisk 模块可以不更新，因为这次除了版本号之外没有任何改动。

## English

`v3.5.0` brings the two recent feature lines into one release: the new menu-bar settings entry and the DropZone drag-and-drop stability rewrite.

The point of this release is not to add flashy features, but to make the core workflow feel publishable and dependable:

- A cleaner settings entry is now available from the menu bar, with a more complete status-item workflow.
- DropZone trigger, anchoring, show/hide behavior, and drag-session ownership were reworked to reduce bounce-backs, silent dismissals, mispositioned windows, and clipped panels.
- Local-file drag detection and drag-session retention are more reliable, especially for Finder drags, status-bar prewarm, and handoff after entering the target zone.
- macOS, Android, the Magisk module, and runtime protocol strings are now aligned on version `3.5.0`, so shipped assets match the running code.

### Highlights

- Merged the status-bar settings window branch into the release line.
- Merged the DropZone refactor branch and fixed center-screen placement, half-clipped windows, hard-to-trigger activation, no-op drop release, and frequent drag bounce-back failures.
- Tuned the DropZone activation band, keepalive area, and drag handoff order so it appears more easily near the menu bar and dismisses correctly after leaving the target area.
- Refreshed the macOS `.app`, Android APK, Magisk module metadata, and release version strings.

### Release Assets

- `AirSend-v3.5.0-macOS.zip`
- `AirSend_Magisk_v3.5.0.zip`

### Update Recommendation

- Updating to the latest Mac build is recommended.
- You can skip updating the Magisk module, because this release does not change anything in it except the version number.
