# AirSend 跨端发现、稳定性与功耗收敛计划

- 状态：Phase 1 code-complete，待真机/真实网络验收
- 日期：2026-07-14
- 范围：Android App、Android root/no-root daemon、macOS AirSend
- 原则：AirSend 是独立产品；兼容协议只作为边界适配层，不作为架构与参数的设计权威。

## 1. 决策摘要

AirSend 的目标架构收敛为：

1. 每个平台只有一个网络状态真相源。
   - Android：`airsend_daemon` 是设备、传输、健康状态的权威；App 只订阅和发命令。
   - macOS：一个 `DiscoveryCoordinator` 统一持有 path、socket、peer registry 和发现状态。
2. 发现从定时轮询改为事件驱动。
   - 启动、网络稳定变化、UI/菜单打开、分享动作、实际发送前触发。
   - 稳态不做 1/3/5/30 秒固定扫描，不自动扫完整网段。
3. 快速路径固定为“已知端点直探 + 短促 announce burst”。
   - 先验证历史上成功的 AirSend 端点，同时发送 0 ms / 250 ms / 1000 ms 三段 burst。
   - 一旦目标确认可达，立即取消该轮剩余探测。
4. Android 只保留一个进程监管者。
   - root 模式由模块 supervisor 通过阻塞 `wait` 管理 daemon，不再以 `pidof` 代替健康检查。
   - daemon 换网时原地重绑 socket，不再自行拉起新进程后退出。
5. 跨端采用同一个 AirSend discovery vNext 契约。
   - 相同的触发原因、去重、租约、退避、端点缓存和指标名称。
   - 新字段保持向后可忽略，兼容适配器留在网络边界。
6. 以硬性稳定性和功耗门槛约束延迟优化。
   - 先满足“无泄漏、无崩溃、无后台违规”，再在可接受参数范围内选择最低延迟、最低功耗的 Pareto 点。

## 2. 当前实现为何没有收敛

当前两端存在多套互不知情的轮询和恢复机制：

| 层 | 当前行为 | 结构性问题 |
| --- | --- | --- |
| Android UI | 每 5 秒执行一次完整 refresh | 已有 IPC event stream，仍重复发多条 IPC 请求 |
| Android Service | 每 30 秒 `GET_PEERS` | App Service 与 daemon 同时维护后台节奏 |
| Android daemon | 每 3 秒检查网络绑定，变化后自重启 | 把网络变化升级成全进程重启；与 root/App 重启入口竞争 |
| Android discovery | 有 peer 时 30 秒 announce；无 peer 时 5 秒 announce，并每 30 秒主动扫 `/24` | peer 没有可靠租约，旧 peer 会压制正确恢复；稳态持续唤醒 |
| Android recovery | `pidof` 成功即认为 daemon 健康 | “进程活着、IPC 已坏”时无法恢复 |
| Android FGS | `dataSync` + `START_STICKY` + 开机启动 | Android 15+ 有累计 6 小时限制，且当前已出现 timeout/start-not-allowed |
| macOS discovery | 30 秒广播；菜单打开后每 1 秒扫描 | UI 状态直接控制网络定时器，重复 burst 和端点探测 |
| macOS fallback | 自动整网段探测，最高 320 并发 | 在 `/16` 等网络上成本不可控，也不能解决 AP isolation |

因此不能继续叠加新定时器或 fallback。正确方向是删去并行控制面，建立一个事件驱动状态机。

## 3. 目标状态机

### 3.1 状态

跨端统一使用以下状态：

- `idle`：socket 已绑定，等待事件，不主动发包。
- `probing_known`：验证同一网络签名下最近成功的端点。
- `announcing`：执行有界 announce burst。
- `ready`：至少一个目标已在本轮确认可达。
- `degraded`：网络存在，但 multicast/broadcast 或端点验证失败。
- `recovering`：正在重绑 socket 或重启异常 daemon。
- `stopped`：用户关闭、平台禁止或 supervisor 进入熔断。

UI 不再用“服务运行中”代表一切，而是分别呈现：进程、IPC、网络绑定、peer 可达性和最近一次失败原因。

### 3.2 触发与动作

| 触发 | Android | macOS | 共同动作 |
| --- | --- | --- | --- |
| runtime 启动 | root: netlink 初始化；no-root: `NetworkCallback` | `NWPathMonitor` 初始 path | 直探已知端点 + burst |
| 网络稳定变化 | netlink 地址/路由事件；no-root 用 `ConnectivityManager` | `NWPathMonitor.pathUpdateHandler` | 500 ms debounce，原地重绑，触发 burst |
| 打开 AirSend 页面/菜单 | lifecycle resume | `menuWillOpen` | 先探选中目标，再探最近端点；没有 1 秒循环 |
| 分享或自动同步事件 | 发送前 preflight | 发送前 preflight | 已知目标直探；失败后 burst；仍失败才进入手动恢复 |
| 收到 announce | 更新 peer lease | 更新 peer lease | 20–80 ms jitter 后单次响应；2 秒内同一消息去重 |
| 用户手动“重新发现” | IPC 命令 | coordinator action | 新一轮有界发现；不清空可用 peer，不重启进程 |

### 3.3 初始参数

这些参数是受控实验的起点，不是未经验证的永久常量：

- announce burst：`0 ms, 250 ms, 1000 ms`，每次附加 `0–80 ms` jitter。
- 已知端点：最多 8 个，优先选中目标和最近成功目标；并发 4；单次超时 350 ms。
- endpoint cache：最多 32 个，按 AirSend identity + 匿名网络签名分组，LRU 淘汰。
- peer 状态：
  - 本轮验证成功：`reachable`；
  - 超过 90 秒未验证：`last_known`，不再冒充在线；
  - UI 打开或发送前立即重新验证。
- announce response 去重窗口：2 秒；缓存上限 256 条。
- 网络变化 debounce：500 ms；同一路径抖动不重复重绑。
- 稳态：无固定周期 announce。仅保留一个默认关闭的 10 分钟 safety pulse 实验开关；只有实测证明平台事件存在漏报才考虑启用。

## 4. 正常发现与恢复边界

### 4.1 正常路径

正常路径只允许：

1. 已知 AirSend 端点直探。
2. AirSend multicast/broadcast announce。
3. 收到 announce 后的单次定向响应。

任何完整子网扫描都不能进入正常后台路径。

### 4.2 手动恢复路径

只有用户主动触发、且正常路径失败后，才允许候选扫描：

- 候选来源：近期成功端点、ARP/neighbor cache、当前 `/24` slice。
- 每轮最多 512 个 endpoint，最大并发 32，总预算 3 秒，冷却 60 秒。
- 找到目标立即取消其余任务。
- `/16` 或更大网络不穷举；AP isolation 明确报告为网络边界，不用暴力扫描掩盖。
- Campus fallback 保持独立、显式、受大小和时间窗口约束，不能反向变成常规发现通道。

## 5. Android 收敛设计

### 5.1 IPC

- 一次性请求严格“一请求、一响应、服务端关闭”。
- 只有 `subscribe` 可以保持长连接；本机 Unix socket 不发送周期 heartbeat，daemon 退出时由 EOF 触发重连。
- daemon 使用 semaphore 限制最多 16 个 IPC client；首包 5 秒超时；写超时 5 秒；payload 保持有界。
- 新增原子 `get_snapshot`，一次返回 hello、health、config、peers 和 transfer summary。
- Android UI 在页面进入时取一次 snapshot，随后只消费 event；退出页面即取消订阅。删除 5 秒 refresh loop。
- Direct Share 使用持久化的 `last_known` 目标，真实发送前验证，不再由 30 秒 Service 轮询维护。

### 5.2 root 模式

- root daemon 是唯一后台网络引擎，Android App 不再额外常驻 FGS。
- 模块 supervisor 以阻塞 `wait` 监控子进程，不轮询：
  - 正常退出：按显式退出码决定是否重启；
  - 异常退出：`1, 2, 4, 8, 30 s` 有上限退避；
  - 2 分钟内 5 次异常退出进入 5 分钟熔断，并写入可读状态文件。
- 健康判定必须完成 `hello` + protocol/version handshake；`pidof` 只能证明进程存在。
- “修复 AirSend”流程：请求优雅退出，2 秒后仍未退出则强制结束，由 supervisor 拉起；即使旧 PID 存在也必须能恢复。
- 网络变化由 netlink 的 link/address/route 事件驱动，重建 discovery socket；IPC、传输状态、配置和历史库不随网络重绑销毁。

### 5.3 no-root 模式

- “始终可用”必须由用户显式启用，并使用 `connectedDevice` FGS，而不是 `dataSync`。
- 声明对应 FGS permission 和网络/multicast 前置条件；开机启动只在用户启用该模式后执行。
- 未启用“始终可用”时采用 session 模式：App 可见或用户正在发送时运行，结束后停止。
- 长文件传输保持用户可见通知与取消入口；必要时按系统版本采用 user-initiated data transfer job。
- no-root 能力边界要在 UI 中如实呈现，不能用不断重启 Service 假装具有 root 模式的后台可靠性。

## 6. macOS 收敛设计

- 新增单一 `DiscoveryCoordinator`，从 `AppDelegate` 收回以下职责：
  - `NWPathMonitor`；
  - `NWConnectionGroup` / broadcast socket 生命周期；
  - endpoint cache；
  - peer lease 与状态机；
  - 本轮发现的取消和指标。
- 删除菜单打开后的 1 秒 repeating scan；菜单打开只启动一轮可取消 burst。
- 删除稳态 30 秒 broadcast timer；网络变化、启动和用户动作足以恢复发现。
- 删除 multicast ready 时自动整网段扫描；manual recovery 才能进入有界候选扫描。
- path 变化后只重建 discovery transport，不重启整个 networking stack，不清空仍可验证的 peer。
- 已知端点与 Android 使用相同排序、并发、超时和取消规则。
- peer registry 区分 `reachable` 与 `last_known`；菜单打开先验证再展示在线状态，避免长 TTL 制造假在线。
- 剪贴板轮询与发现彻底解耦：
  - 只在自动同步开启且存在目标时运行；
  - 前台/近期活动阶段 1 秒，稳定空闲阶段退到 5 秒并设置至少 20% tolerance；
  - 屏幕锁定、无目标或同步关闭时停止；
  - 单独测量“发现 idle”和“剪贴板自动同步 idle”，避免把两者功耗混为一谈。

## 7. AirSend discovery vNext 契约

在现有可兼容消息上增加可选字段：

- `airsendProtocolVersion`
- `sessionId`
- `messageId`
- `messageKind`: `probe | response`
- `replyTo`
- `endpointSet`
- `capabilities`
- `triggerReason`

规则：

1. identity/fingerprint 是设备身份，IP/port 只是可变 endpoint。
2. 相同 `messageId` 在去重窗口内只处理一次。
3. `response` 不再触发 response，避免响应风暴。
4. 旧端只读到已有字段时仍可工作；AirSend 新端优先走 vNext 语义。
5. 所有时延从 trigger 到 `peer_reachable` 统一计时，不能由两端各算一套口径。

## 8. 可观测性

两端输出同名、默认脱敏的结构化事件：

- `discovery_triggered(reason, path_generation)`
- `known_probe_started(candidate_count)`
- `announce_sent(sequence)`
- `announce_received(peer_id_hash, duplicate)`
- `peer_state_changed(from, to, reason)`
- `discovery_completed(duration_ms, path, packets, probes)`
- `network_rebound(duration_ms)`
- `ipc_connection_opened/closed(active_count)`
- `supervisor_restart(reason, backoff_ms)`

禁止记录剪贴板、文件内容、完整 URL、header、token、证书或原始 fingerprint。

### 8.1 无服务器阶段的收集方式

当前没有统计服务器，因此第一版不做自动上传：

- Android 和 macOS 只在本地保存滚动聚合值，不保存原始事件明细；默认关闭。
- 聚合内容包括成功率、P50/P95/P99、FD 峰值、重启/熔断次数、版本和平台类型。
- 提供“导出 AirSend 诊断摘要”，生成脱敏 JSON/压缩包；用户可以通过分享、ADB `pull` 或手动附加到 issue/对话中发送。
- 不把 GitHub、第三方分析 SDK 或任意公共 URL 当作隐式收集后端。
- 将来若需要自动汇总，必须另行选择并公开一个 collector endpoint、保留期限和删除机制；在此之前不启用网络上传代码。

## 9. 科学验收门槛

### 9.1 发现速度

每个场景至少 200 次，报告 P50/P95/P99 和成功率：

| 场景 | 门槛 |
| --- | --- |
| 同网、已知 peer、两端 runtime 已运行 | P95 ≤ 800 ms；P99 ≤ 1.5 s |
| 同网、新 peer 或一端冷启动 | P95 ≤ 2.0 s；成功率 ≥ 99.5% |
| Wi-Fi 重连、睡眠唤醒、热点切换 | 网络稳定后 P95 ≤ 3.0 s |
| IPC/daemon 卡死后的自动恢复 | ≤ 10 s，并给出真实恢复原因 |

网络矩阵：家庭 `/24`、手机热点、校园 `/16`、VPN 开/关、Wi-Fi 断开重连、Mac sleep/wake、Android screen-off/Doze。

### 9.2 稳定性

- 72 小时双端 soak test，0 crash、0 ANR、0 FGS timeout。
- 10,000 次 IPC one-shot + 1,000 次 subscribe/cancel：FD 回到基线，无正斜率。
- 500 次网络 path 变化/重绑：单 daemon、单 socket owner，无重复 supervisor。
- 500 次 daemon kill/stuck/restart 注入：恢复成功率 100%，熔断按设计工作。
- steady-state RSS 漂移不超过 10 MiB；若缓存增长，必须能由明确上限解释。
- 发布二进制的 protocol/version/hash 与 App 报告一致，防止“源码已修、设备仍跑旧 daemon”。

### 9.3 功耗

采用同设备、同网络、同亮度/充电状态的 A/B/A 三轮测试；以系统记录的 charge/energy 和进程指标为准，不只看电量整数百分比。

Android，8 小时熄屏、每种模式至少 3 轮：

- AirSend enabled 相对 disabled 的增量 ≤ 满电容量的 1% / 8 h。
- discovery steady-state CPU time ≤ 30 s/h。
- discovery 主动 wakeup ≤ 6 次/h；无长期 wakelock。
- 无自动 subnet scan；网络包数量能由触发事件逐一解释。

macOS，2 小时 idle、每种模式至少 3 轮：

- CPU P95 < 0.2%，平均 idle wakeups ≤ 1/min。
- Xcode Energy / Activity Monitor 无持续高能耗。
- 分开报告 discovery-only 与 clipboard-auto-sync，后者必须满足其自有时延目标：活跃阶段 P95 ≤ 2 s，空闲阶段 P95 ≤ 6 s。

若设备测量噪声高于门槛，使用 95% 置信区间和 baseline-relative 差值判断，不通过放宽一次实验来“调绿”。

## 10. 参数收敛方法

只调三组高杠杆参数：

1. burst：`[0, 200, 800]`、`[0, 250, 1000]`、`[0, 300, 1200]`。
2. known-probe 并发：2、4、8。
3. path debounce：300、500、800 ms。

选择规则：

1. 任一方案触发泄漏、崩溃、重复进程或功耗门槛失败，直接淘汰。
2. 在剩余方案中，先比较发现成功率，再比较 P95，最后选择主动包和 wakeup 更少者。
3. 不用增大子网扫描范围换取表面成功率。
4. 参数在 Android 与 macOS 保持同一语义；只有平台 API 的实现不同。

## 11. 实施顺序与用户验收点

执行口径：这里的 Phase 是内部工作包，不把每个小步骤都变成验收点。代码层面的构建、单元测试、静态检查和可重复探针由 agent 自行完成；只有真实设备/真实网络行为需要用户确认。当前仓库 `AGENTS.md` 要求每个真正的 major code change 完成后暂停，等待用户实机验证，确认后单独 commit，再进入下一组 major change；因此会尽量合并工作包、减少暂停次数，但不能跨越该边界连续堆叠多个 major 改动。

### Phase 1：先修复当前 Android 失联基础问题

- IPC 生命周期、连接上限和原子 snapshot。
- 正确区分 PID、IPC 和健康握手。
- 单 supervisor + 可强制恢复 stuck-alive daemon。
- root 模式停止依赖 `dataSync` FGS；no-root 改为合规模式。
- 在当前手机上部署并验证 FD、FGS、重启和 2 小时稳定性。

代码级完成项（2026-07-14）：

- Android IPC 一次性请求改为有界读取，只有成功 `subscribe` 保持长连接；daemon 端增加 16 个并发连接上限，订阅不靠周期 heartbeat。
- 增加 `get_snapshot` 能力；新版 App 优先用 `hello + get_snapshot`，旧 daemon 仍走兼容的多请求路径；移除 UI 5 秒 refresh loop。
- Android Service 的 Direct Share peer 更新改为单一事件订阅 + 失败退避，不再每 30 秒轮询 `GET_PEERS`。
- root daemon 增加单一 supervisor、崩溃退避/熔断、stuck-alive 强制修复；停止/修复路径会先停止 supervisor，避免其把 daemon 重新拉起。
- no-root FGS 从 `dataSync` 切换到 `connectedDevice`，并声明 multicast 前置权限。
- 增加 root module 构建复制、权限和包内容校验；无服务器统计仍只保留计划约束，未加入联网上传。
- 代码验收：Rust 48 项测试通过；Android `:app:testDebugUnitTest` 通过；root module shell 语法、service policy tests、debug APK 和 root ZIP 内容校验通过。

当前只剩用户真机验收：安装该 debug APK/root ZIP 后，按本回复列出的清单验证 stuck-alive 修复、FD 不增长、Android 15 FGS 不再报错，以及 root/no-root 的真实后台边界。统计仍不联网；现有日志可主动导出，滚动聚合摘要导出会作为下一项独立代码工作。

验收后 commit；此阶段不改变跨端发现协议。

### Phase 2：建立跨端契约和测试器，先不默认启用

- discovery vNext 可选字段、统一事件名、fake clock/state-machine tests。
- Android 与 macOS 同时加入 feature flag 和兼容解析。
- 建立 200 次 discovery benchmark、network-flap 和 packet-loss 注入脚本。

验收后 commit。

### Phase 3：Android 切换事件驱动引擎

- netlink/`NetworkCallback`、in-process rebind、known endpoint cache。
- 删除 3/5/30 秒网络与发现轮询、后台 `/24` scan、UI 5 秒 refresh、Service 30 秒 peer sync。
- 保持 vNext 默认关闭，先与兼容 Mac 联调。

验收后 commit。

### Phase 4：macOS 切换同一状态机并双端启用

- `DiscoveryCoordinator` + `NWPathMonitor`。
- 删除 30 秒 broadcast、菜单 1 秒 scan 和自动 subnet probe。
- 加入相同 endpoint cache、lease、burst、取消和指标。
- 两端同时打开 vNext 默认开关，完成完整网络矩阵。

验收后 commit。

### Phase 5：功耗与 72 小时发布闸门

- 执行 burst/concurrency/debounce 小型参数实验。
- 完成 Android 8 小时 A/B/A、Mac 2 小时 A/B/A、72 小时 soak。
- 只保留胜出的单组参数，删除实验 flag、旧 timer 和死代码。
- 更新工程架构图与最终运行手册。

最终验收后 commit。

## 12. 明确不做

- 不把端口差异本身当作故障；端口属于显式 endpoint 契约。
- 不用“再加一个 watchdog/Timer”修复已有 watchdog/Timer。
- 不把 `pidof`、通知常驻或 Service running 等同于 AirSend 可用。
- 不在正常后台路径扫 `/16`、全私网或多个端口组合。
- 不让 Android 和 macOS 各自形成不同的发现参数与状态语义。
- 不在缺乏 AirSend 遥测时宣称具体用户故障比例；代码级风险与平台级约束可以确认，普遍发生率必须由匿名健康指标或用户报告统计证明。

## 13. 执行前已确认的决策

- 2026-07-14：当 IPC 已失效但 daemon 进程仍存活时，允许“修复 AirSend”直接终止并重启 daemon；活动传输可以被中断，优先保证恢复出口确定且不会被 stuck-alive 进程阻塞。
- 2026-07-14：daemon 连续崩溃时允许 supervisor 按 `1/2/4/8/30 秒`退避，2 分钟内最多自动重启 5 次，随后熔断 5 分钟并报告明确原因；不允许无限重启。
- 2026-07-14：discovery vNext 必须兼容当前 AirSend 3.5.x，允许 Android 与 macOS 分批升级；新字段采用可选扩展，旧发现入口继续保留。
- 2026-07-14：root 模式负责屏幕关闭后的持续发现、剪贴板和截图同步；no-root 只承诺前台/session 模式与用户主动传输，不承诺同等后台能力。
- 2026-07-14：macOS 在没有可达 peer，或电池供电且长时间无交互时，允许暂停剪贴板自动同步；发现服务与剪贴板同步分开治理。
- 2026-07-14：在没有统计服务器的阶段，匿名健康统计采用本地滚动聚合 + 用户主动导出，不做自动上传；后续必须单独批准 collector endpoint 后才能增加网络上报。
- 2026-07-14：统计先锁定为本地滚动聚合与用户主动导出，不加入任何联网统计代码；本次核心稳定性代码块只保留现有脱敏日志导出，聚合摘要导出作为下一项独立代码工作，避免把诊断收集和 daemon 修复绑成不可回滚的大改动。
- 2026-07-14：执行时不按每个内部 Phase 逐一打断；代码级验证由 agent 完成，用户主要验收真机和实际网络；但仍遵守仓库对 major code change 的暂停与确认规则。

## 14. 官方约束依据

- Android `dataSync` FGS 在 Android 15+ 有累计 6 小时/24 小时限制：<https://developer.android.com/develop/background-work/services/fgs/timeout>
- `connectedDevice` 用于需要网络连接的外部设备交互：<https://developer.android.com/develop/background-work/services/fgs/service-types>
- 用户主动长传输的 UIDT：<https://developer.android.com/develop/background-work/background-tasks/uidt>
- Android 默认网络变化回调：<https://developer.android.com/reference/android/net/ConnectivityManager#registerDefaultNetworkCallback(android.net.ConnectivityManager.NetworkCallback)>
- Android multicast lock 会带来明显额外耗电，必须按需持有：<https://developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock>
- Apple `NWPathMonitor` 用于响应 path 变化：<https://developer.apple.com/documentation/network/nwpathmonitor>
- Apple `NWConnectionGroup` 用于本地 multicast group：<https://developer.apple.com/documentation/network/nwconnectiongroup>
- Apple 建议以事件替代轮询并尽量减少 Timer：<https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html>

## 15. 2026-07-14 Android 真机安装与故障注入记录

- 设备：PKX110（Android ARM64，Magisk root）；安装 `versionCode=351` debug APK 与 `AirSend-root-v3.5.1.zip` 后完成重启。
- 修复了三项实际启动链问题：禁止 root daemon 自行派生第二进程；把 App 可操作的 supervisor 控制锁移到 `/data/local/tmp`；锁同时校验 boot ID、PID 和进程命令行，避免跨重启陈旧锁或 PID 重用误判。
- root 产物改用 `cargo ndk -t arm64-v8a -P 35` 交叉编译；APK、root ZIP 与 assets 内 daemon 的 SHA-256 已核对一致，禁止再把 macOS Mach-O 产物装入 Android。
- daemon 因网络重绑以退出码 `0` 请求重启时，supervisor 现在视为受控重启，清零 crash counter，不进入崩溃退避或熔断。
- 重启验收：锁内 boot ID 与当前 boot ID 一致；只有一份 root daemon；supervisor 与 daemon 父子关系正确；未再出现 `Address already in use`、Mach-O shell syntax error 或双 daemon。
- 卡死注入：对 daemon PID `18009` 发送 `SIGSTOP`，确认状态进入 `T (stopped)`；执行修复链后旧 supervisor/daemon 被清理，新 supervisor PID `5450` 托管新 daemon PID `5564`，daemon 恢复 `S` 状态并重新绑定抽象 UDS、multicast 与 HTTPS 服务。
- 代码验收：Rust 48/48 测试通过，Android Kotlin 编译与单元测试通过，root module service policy 与 shell 语法检查通过。

## 16. 2026-07-14 macOS 冷启动闪退修复记录

- 现场证据：macOS 26.5.2 上的 AirSend v3.5.4 build 354 在 `12:47:26`、`12:47:31`、`12:47:36` 连续生成三份相同 `.ips`；均为 `EXC_BREAKPOINT / SIGTRAP`，触发队列是 `com.apple.root.utility-qos.cooperative`。
- 根因链：`UDPDiscoveryService.probeCurrentSubnet` → `subnetProbeCandidates` → `preferredProbeHosts` → 同步 provider → `@MainActor AppDelegate.prioritizedDiscoveryHosts`。Swift 运行时在后台队列执行主 actor 隔离 closure 时触发 `_dispatch_assert_queue_fail`。
- 方案选择：不采用 `DispatchQueue.main.sync`、关闭 actor 检查或仅延迟启动；这些方案分别存在死锁、掩盖数据竞争或只改变复现概率的问题。
- 最终实现：删除 discovery 到 AppDelegate 的同步反向 provider；AppDelegate 在主 actor 上生成有序 host 数组，并在设备/known-host 变化时主动推送；`PreferredDiscoveryHostsStore` 用 `NSLock` 原子替换和读取不可变快照，后台 discovery 只读取自己的副本。
- 启动安全：新增发布闸门，只在 `startDiscovery` 后允许推送，避免 `loadDevices` 等启动期写入过早初始化 lazy discoveryService 并固化错误 fingerprint；重建网络或 discovery 服务时先关闭发布，再为新实例推送初始快照。
- 自动验收：快照规范化/替换测试通过；20,000 次并发读写测试通过；同一测试在 Thread Sanitizer 下通过；AirSend 完整 Swift build、Updater、DragHandoff、ConsoleSupport 自测全部通过。
- 真机验收：签名应用已安装到 `/Applications/AirSend.app`；首次冷启动稳定运行 12 秒，随后 5/5 次完整退出重启通过；每轮均实际执行 `startup-preferred` 与 subnet probe 并发现 Android，且没有新增 AirSend `.ips`。

## 17. 2026-07-14 Android 配置并发写入修复记录

- 现场表现：快速切换自动截图同步等设置时，App 报 `failed to atomically replace /data/adb/airsend/config.json with /data/adb/airsend/config.json.tmp`；同一时段截图实际仍能发送，说明至少一个竞争写成功，另一个写在 rename 阶段失败。
- 根因：daemon 的所有保存共用固定 `config.json.tmp`，而 IPC 最多并发处理 16 个连接；两个请求可以同时截断同一临时文件，其中一个 rename 后，另一个找不到临时文件。Android Repository 同时采用 `get_config → 修改完整快照 → set_config`，还存在不同设置互相覆盖的 lost-update 风险。
- daemon 修复：增加 `patch_config` IPC 能力；在单一配置事务锁内读取当前配置、校验字段、合并 patch、规范化并持久化。保留 `set_config` 兼容入口，但同样串行持久化。
- 文件修复：每次保存使用同目录、`create_new` 创建的唯一临时文件，名称包含 PID、时间戳和进程内序号；写入、文件 fsync、rename、目录 fsync 保持原子链，失败时尽力清理临时文件。IPC 错误改为保留完整 anyhow cause chain，后续能看到实际 errno。
- App 修复：每个设置只发送自身字段的 patch，不再读取和回写完整配置；App 内仍以 mutex 串行设置更新。连接旧 daemon 时，仅在明确返回 `unknown_operation` 后回退到锁内 `get_config + set_config`。
- 自动验收：Rust 51/51 通过，其中包含 32 路并发文件保存、两个并发字段 patch 合并、未知字段拒绝且不落盘；Android `AirSendRuntimeRepositoryTest` 与 debug APK 构建通过。
- 真机验收：PKX110 安装新版 APK 与 Magisk 模块后，新 daemon SHA-256 为 `788a3d3a07813dfd0e8a3fca7d64db34b38a67208037566539278dd3ae0a618d`；通过真实 `airsend_ipc` 连续执行 20 轮、每轮两个并发设置 patch，共 40 个响应全部成功、0 错误；最终两个字段一致、无 `.tmp` 残留，supervisor 为单实例且 `crashCount=0`。
- 状态恢复：压力测试结束后已把用户原有配置恢复为 `clipboardSyncEnabled=true`、`screenshotSyncEnabled=true`，重新打开 App 后仍由唯一 root daemon 提供 IPC，没有启动第二份 bundled daemon。

## 18. 2026-07-14 Android 常驻通知与后台服务语义收敛

- Android 前台服务的通知是系统契约，普通 no-root 模式不能一边维持该服务、一边真正移除通知；因此 no-root 下“状态栏通知”开关必须禁用并解释系统限制。
- Root + Magisk 模块可由 root daemon 独立承担发现与传输；关闭通知时停止 App 前台服务并移除其通知，不再用静默 channel 伪装成“已关闭”。
- 首页“后台服务”在 Root 模式映射到 root supervisor/daemon，在 no-root 模式映射到 App 前台服务，避免关闭通知后首页把健康的 root 后台误报为停止。
- App 启动与开机启动均遵循同一策略，不会因为进入设置页又偷偷拉起前台服务和常驻通知。

## 19. 2026-07-14 Android 系统原生快捷分享收敛

- 系统边界：普通应用可以注册为所有 MIME 的 `ACTION_SEND` / `ACTION_SEND_MULTIPLE` 接收方并发布 Direct Share 设备目标，但最终跨应用排序由 Android/ColorOS Sharesheet 决定，应用不能无条件强占第一。
- 原有缺陷：设备快捷目标发布绑在 App 前台服务；Root 模式关闭常驻通知后该服务停止，目标无法继续更新。旧实现也缺少长期目标、成功使用上报、默认设备排序和发布去重。
- 最终实现：设备快照成功刷新时事件驱动发布 Direct Share，不依赖常驻前台服务；默认设备 rank 0，只发布在线且有效的唯一设备，并遵守系统每 Activity 的快捷方式上限。
- 排名稳定性：peer ID 作为长期稳定 shortcut ID，设置 `longLived`；直达设备或 App 内发送成功后调用系统 usage reporting，让系统用真实频率和近期行为提升 AirSend，而不是用 LSPosed 篡改系统 Resolver 排序。
- 功耗控制：同一进程内对发布内容做签名去重；临时发现为空时保留上一批可用目标，不增加轮询、Alarm 或额外前台服务。
- 真机纠错：首次交付后系统已保存 `Thom的MacBook Air` shortcut 且 rank=0，但 Sharesheet 顶部仍不显示。`dumpsys shortcut` 证明 shortcut 归属启动入口 `LauncherAlias`，而 `android.app.shortcuts` 元数据误挂在 `ShareTargetActivity`；已按 Android 对 `activity-alias` 的明确要求把元数据移动到 `LauncherAlias`，使动态 shortcut 与 `share-target` 声明能够匹配。
- 交互收敛：旧 shortcut 的系统分享 glyph 改为按 phone/tablet/laptop/desktop/TV 生成的紫色自适应设备图标；应用更新后由一次性 `MY_PACKAGE_REPLACED` 事件刷新，不需用户先开 App，也不增加常驻任务。真机 ShortcutManager 已从系统资源图标切换到 216×216 自有 bitmap，并保持 rank 0/long-lived。
- 分享交互：`ShareTargetActivity` 仅作为不可见路由，不再直接发送或显示 Toast/通知；所有系统分享入口统一进入 InstallerX 同款 `WindowBottomSheet`。在线设备在交互层内可选，Direct Share 设备只作为默认预选项，用户点击“发送”后才执行 IPC。发送中锁定选择，成功或失败都留在原交互层，成功后由用户点击“完成”关闭，不自动消失。
- 官方依据：Android 11+ Direct Share 只接受 Sharing Shortcuts API；系统按 rank、历史、近期和频率综合排序。见 <https://developer.android.com/training/sharing/direct-share-targets> 与 <https://developer.android.com/develop/ui/compose/system/shortcuts/managing-shortcuts>。
