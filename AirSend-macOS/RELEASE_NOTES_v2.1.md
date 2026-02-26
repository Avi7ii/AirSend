# AirSend v2.1

## 中文更新说明

- 拖拽分享体验优化：Drop Zone 不再在检测到拖拽后立即可见，而是靠近状态栏图标时再显示。
- 稳定性增强：拖拽开始时先预热窗口（定位并入层但保持不可见），减少拖拽过程中弹回/抖动问题。
- 显隐逻辑改进：拖拽进行中支持软隐藏（仅透明化不出层），远离图标可隐藏，回到图标附近可平滑恢复显示。
- 传输与 UI 细节优化：改进上传链路日志与临时文件处理，设备列表标题展示更清晰。

## English Release Notes

- Improved drag-to-share UX: the Drop Zone no longer appears immediately on global drag detection; it appears when the cursor is near the menu bar icon.
- Better drag stability: the window is prewarmed at drag start (positioned and ordered in but invisible) to reduce bounce/flicker during active drags.
- Refined visibility control: while dragging, soft-hide is used (alpha only, no order-out), so the window can hide when far away and smoothly reappear near the icon.
- Transfer and UI refinements: improved upload logging/temp-file handling and clearer device title presentation in the menu.
