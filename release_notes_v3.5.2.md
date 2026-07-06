## 中文

`v3.5.2` 是一次小型 macOS 稳定性更新，主要修复最近反馈的两个问题。

### 主要改动

- 修复状态栏菜单偶发打开后立即消失的问题。
- 优化 macOS 冷启动网络栈初始化，降低启动几秒后退出的风险。
- 加固证书生成时的网卡 IP 枚举，避免异常网卡地址影响启动。

### 发布资产

- `AirSend-v3.5.2-macOS.zip`
- `AirSend_Magisk_v3.5.1.zip`（Android/Magisk 资产沿用上一版最新版）

## English

`v3.5.2` is a small macOS stability update for two recently reported issues.

### Highlights

- Fixed a status-bar menu issue where the menu could open and immediately disappear.
- Simplified macOS cold-start networking initialization to reduce early-exit risk.
- Hardened certificate IP enumeration so unusual network interfaces do not affect startup.

### Release Assets

- `AirSend-v3.5.2-macOS.zip`
- `AirSend_Magisk_v3.5.1.zip` (latest unchanged Android/Magisk asset)
