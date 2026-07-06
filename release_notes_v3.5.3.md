## 中文

`v3.5.3` 是一次 macOS 拖拽体验修复更新。

### 主要改动

- 修复首次拖拽文件时必须紧贴状态栏图标才能触发 DropZone 的问题。
- 拖拽靠近状态栏区域时会先显示候选 DropZone，再由系统拖放回调校验真实文件。
- 新增拖拽触发自测，并接入 CI。

### 发布资产

- `AirSend-v3.5.3-macOS.zip`
- `AirSend_Magisk_v3.5.1.zip`（Android/Magisk 资产沿用上一版最新版）

## English

`v3.5.3` is a macOS drag-and-drop usability fix.

### Highlights

- Fixed the first-drag case where DropZone only appeared when the pointer touched the status-bar icon.
- Shows a candidate DropZone near the status-bar area first, then lets the system drop callback validate real files.
- Added drag handoff self-tests and wired them into CI.

### Release Assets

- `AirSend-v3.5.3-macOS.zip`
- `AirSend_Magisk_v3.5.1.zip` (latest unchanged Android/Magisk asset)
