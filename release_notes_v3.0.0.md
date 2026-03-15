## 中文

AirSend 3.0.0 是相对 GitHub 最新正式版 `v2.4.2` 的一次大跨步更新。重点不只是继续打磨日常传输，而是正面解决了校园网、宿舍网、复杂局域网这类“能发现但几乎传不动”的环境，同时把 Mac 侧拖拽投递体验做到了更稳、更顺手。

### 复杂网络与校园网突破

- 新增手动 `HTTP 兼容模式`，默认关闭，默认仍优先保持 LocalSend 标准 HTTPS 传输。
- 当校园网里设备发现正常、但 HTTPS 数据面频繁超时或悬空时，可在 macOS 菜单栏 `Advanced -> Compatibility Mode (HTTP)` 手动切换到兼容链路。
- macOS 端新增 plain HTTP 接收器，并把局域网接收端口独立到 `53318`；Android 守护进程侧使用独立传输端口 `53319`，让发现面和数据面职责更清晰。
- 发送前会做真实数据面预检，并在 HTTPS / HTTP 之间选择当前真正可用的链路，减少“设备明明在线却一直发不出去”的假在线情况。
- Android -> Mac 的主动发送链路补上了 peer 记忆与连接重建逻辑，网络切换后更不容易掉进 `No target found` 或旧连接悬挂。
- Android 守护进程增加网络绑定变化检测与自重绑能力，热点、校园网、接口切换后的恢复速度更快。

### DropZone 与拖拽体验升级

- 重做本地文件拖拽识别，只接受真实的本地文件拖拽，忽略文本选择、窗口移动或其他伪拖拽来源。
- 新增拖拽负载缓存与回读逻辑，修复 AppKit 在边界抖动时丢失 pasteboard 内容导致的“松手弹回”问题。
- DropZone 预热、显示、隐藏与最小化流程重新梳理，拖拽飞行中尽量不做破坏 session 的窗口层级变更。
- 边界命中、退出延迟和后台收起策略都做了收紧，拖拽目标更稳，失败时也更少打断操作。

### 传输与全链路稳定性

- macOS 出站发送器补充了更强的预检、重试与协议切换策略。
- Android 守护进程和 LocalSend patch 继续强化复杂网络下的链路恢复能力。
- Magisk 模块与 Android 侧 daemon 资产一并刷新，发版构建产物与运行时代码保持一致。

### 兼容性说明

- 默认安全模式仍然优先使用 HTTPS，继续保留与官方 LocalSend 的标准协议兼容能力。
- `HTTP 兼容模式` 是 AirSend 针对复杂校园网场景额外提供的能力，官方 LocalSend 当前不提供这条手动兼容路径。
- 建议家庭路由器、手机热点等正常局域网继续使用默认安全模式；只有在“能发现、但几乎传不动”的校园网环境下再手动打开兼容模式。

## English

AirSend 3.0.0 is a major step forward from the latest GitHub release, `v2.4.2`. The focus is not only on polishing everyday transfers, but on finally addressing campus Wi-Fi, dorm networks, and other difficult LANs where devices can be discovered yet transfers are nearly unusable, while also making the macOS drag-and-drop experience much more resilient.

### Breakthroughs for campus and complex LAN environments

- Added a manual `HTTP Compatibility Mode`. It is off by default, and secure LocalSend-style HTTPS remains the default path.
- When discovery works on a campus network but the HTTPS data plane keeps timing out or hanging, you can manually switch macOS to `Advanced -> Compatibility Mode (HTTP)`.
- macOS now has a dedicated plain-HTTP receiver and a separate LAN transfer port on `53318`; the Android daemon uses its own transfer port `53319`, keeping discovery and transport concerns cleaner.
- Before sending, AirSend now performs real data-plane preflight checks and chooses the transport that is actually reachable, reducing the classic “device looks online but transfers never start” failure mode.
- The Android -> Mac active-send path now remembers peers and rebuilds the connection state more reliably after network churn, reducing `No target found` and stale-route failures.
- The Android daemon now watches for binding changes and can rebind itself after hotspot, campus Wi-Fi, or interface transitions.

### DropZone and drag-and-drop improvements

- Reworked local-file drag detection so only real local file drags are accepted; text selections, window moves, and other false-positive drags are ignored.
- Added staged drag payload caching and recovery to fix the AppKit boundary case where the pasteboard payload disappears and the drop “bounces back”.
- Reworked DropZone prewarm, show, hide, and minimize behavior to avoid window-layer changes that can break the drag session mid-flight.
- Tightened boundary handling, exit timing, and background minimization behavior so the target feels more stable and less disruptive during drag-and-drop.

### Transport and end-to-end stability

- The macOS sender now uses stronger preflight, retry, and protocol-switching behavior.
- The Android daemon and LocalSend patches continue to harden recovery on unstable or policy-heavy LANs.
- The Magisk module and Android daemon assets have been refreshed together so release artifacts stay aligned with the runtime code.

### Compatibility notes

- The default secure mode still prioritizes HTTPS and preserves standard protocol compatibility with official LocalSend in normal LAN environments.
- `HTTP Compatibility Mode` is an AirSend-specific answer for difficult campus-style networks; official LocalSend does not currently offer this manual compatibility path.
- For home routers and mobile hotspots, the default secure mode is still recommended. Turn on compatibility mode only for networks where discovery works but actual transfers repeatedly stall.
