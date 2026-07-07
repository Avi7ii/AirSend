# AirSend Console Devices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将现有 AirSend 设置窗口升级为 `Open AirSend...` 控制台，并在保留 Devices 页主体结构的基础上加入健康状态和最近活动。

**Architecture:** 继续使用现有 `AirSendSettingsWindowController`、`AirSendSettingsView` 和 `AirSendSettingsStore`。`AppDelegate` 仍然负责收集运行时状态并生成 `AirSendSettingsSnapshot`；SwiftUI 只消费 snapshot 和 action closure，不直接读取全局状态。

**Tech Stack:** Swift 6.1、SwiftUI、AppKit、现有 macOS menu bar agent 架构。

---

### Task 1: 中文化设计文档并保留已批准范围

**Files:**
- Modify: `docs/superpowers/specs/2026-07-07-airsend-console-devices-design.md`

- [ ] **Step 1: 确认 spec 已改为中文**

Run:

```bash
sed -n '1,180p' docs/superpowers/specs/2026-07-07-airsend-console-devices-design.md
```

Expected: 文档标题为 `AirSend 控制台 Devices 页设计`，正文明确写明保留当前 Devices 页并原位加入控制台元素。

- [ ] **Step 2: 提交中文 spec**

Run:

```bash
git add docs/superpowers/specs/2026-07-07-airsend-console-devices-design.md
git commit -m "Translate AirSend console design spec"
```

Expected: 只提交中文 spec 变更，不包含 `.superpowers/`、`outputs/`、`screenshot/` 等未跟踪文件。

### Task 2: 扩展 settings snapshot 和 action

**Files:**
- Modify: `AirSend-macOS/Sources/AirSend/UI/AirSendSettingsWindowController.swift`
- Modify: `AirSend-macOS/Sources/AirSend/main.swift`

- [ ] **Step 1: 增加控制台快照模型字段**

Add these model definitions near `AirSendSettingsDeviceSummary`:

```swift
enum AirSendConsoleHealthTone: String, Hashable {
    case good
    case warning
    case neutral
}

struct AirSendActivitySummary: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let timeLabel: String
    let symbolName: String
    let tone: AirSendConsoleHealthTone
}
```

Extend `AirSendSettingsSnapshot` with:

```swift
var healthTitle: String
var healthDetail: String
var healthTone: AirSendConsoleHealthTone
var preflightSummary: String
var recentActivities: [AirSendActivitySummary]
```

Extend `AirSendSettingsStore.Actions` with:

```swift
let runDiagnostics: () -> Void
```

- [ ] **Step 2: 在 AppDelegate 构建新字段**

Add to `AppDelegate`:

```swift
private var recentConsoleActivities: [AirSendActivitySummary] = []
private let maxRecentConsoleActivities = 5
```

Add helper methods:

```swift
private func recordConsoleActivity(
    title: String,
    detail: String,
    symbolName: String,
    tone: AirSendConsoleHealthTone = .neutral
) {
    let item = AirSendActivitySummary(
        id: UUID().uuidString,
        title: title,
        detail: detail,
        timeLabel: "just now",
        symbolName: symbolName,
        tone: tone
    )
    recentConsoleActivities.insert(item, at: 0)
    if recentConsoleActivities.count > maxRecentConsoleActivities {
        recentConsoleActivities.removeLast(recentConsoleActivities.count - maxRecentConsoleActivities)
    }
    refreshSettingsWindowIfNeeded()
}

private func consoleHealth(for visibleCount: Int) -> (title: String, detail: String, tone: AirSendConsoleHealthTone) {
    if visibleCount > 0 {
        return ("Ready", "\(visibleCount) device visible", .good)
    }
    return ("Searching", "No visible LAN devices", .neutral)
}
```

Use the helper in `makeSettingsSnapshot()` and fill `preflightSummary` with `Last check: HTTPS preflight OK` or `Last check: HTTP compatibility ready` based on `preferredLocalProtocol`.

- [ ] **Step 3: 接线 Run Diagnostics 和菜单命名**

In `ensureSettingsWindowController()`, pass:

```swift
runDiagnostics: { [weak self] in
    self?.runDiagnosticsFromConsole()
}
```

Add:

```swift
private func runDiagnosticsFromConsole() {
    recordConsoleActivity(
        title: "Diagnostics started",
        detail: "Discovery scan requested",
        symbolName: "wave.3.right",
        tone: .neutral
    )
    performManualRescan(reopenMenu: false)
}
```

Rename the status menu item title from `Settings...` to `Open AirSend...`.

### Task 3: 更新控制台式 Devices 页面

**Files:**
- Modify: `AirSend-macOS/Sources/AirSend/UI/AirSendSettingsView.swift`

- [ ] **Step 1: 调整侧边栏类别**

Replace category cases with:

```swift
case devices
case transfers
case clipboard
case diagnostics
case settings
```

Use titles `Devices`, `Transfers`, `Clipboard`, `Diagnostics`, `Settings`. Change the sidebar header subtitle text from `Settings` to `Console`.

- [ ] **Step 2: 保留 Devices 页主体并加健康条**

On the Devices page, keep `Current Target` and `LAN Devices`. Add:

```swift
SettingsCard(title: "Status") {
    SettingsHealthStatusRow(snapshot: snapshot, action: store.actions.runDiagnostics)
}
```

before `Current Target`.

Create `SettingsHealthStatusRow` using existing `SettingsMetricChip`, a small colored dot, `snapshot.healthTitle`, `snapshot.healthDetail`, `snapshot.preflightSummary`, and a bordered `Run Diagnostics` button.

- [ ] **Step 3: 底部改为 Quick Actions + Recent Activity**

Replace the old Devices `Actions` card with:

```swift
ViewThatFits(in: .horizontal) {
    HStack(alignment: .top, spacing: 14) {
        quickActionsCard
        recentActivityCard
    }
    VStack(alignment: .leading, spacing: 14) {
        quickActionsCard
        recentActivityCard
    }
}
```

`quickActionsCard` contains the existing `Rescan` / `Add by IP` / `Broadcast` actions. `recentActivityCard` renders `snapshot.recentActivities`; if empty, show `SettingsEmptyStateRow(title: "No recent activity", message: "Transfers, discovery updates, and diagnostics will appear here.")`.

- [ ] **Step 4: 迁移旧 Sync / Advanced 内容**

Move old Sync page controls to `Clipboard`.

Move old Advanced controls to `Settings`.

Add lightweight placeholders:

```swift
SettingsCard(title: "Transfers") {
    SettingsEmptyStateRow(title: "No transfer history yet", message: "Recent file transfer state will move here after the console event layer grows.")
}
```

and:

```swift
SettingsCard(title: "Diagnostics") {
    SettingsHealthStatusRow(snapshot: snapshot, action: store.actions.runDiagnostics)
    SettingsButtonRow(primaryTitle: "Run Diagnostics", primaryAction: store.actions.runDiagnostics, secondaryTitle: "Rescan", secondaryAction: store.actions.rescan)
}
```

### Task 4: 记录首批最近活动

**Files:**
- Modify: `AirSend-macOS/Sources/AirSend/main.swift`

- [ ] **Step 1: 手动扫描和兼容模式记录活动**

In `performManualRescan(reopenMenu:)`, call:

```swift
recordConsoleActivity(title: "Discovery refreshed", detail: "Manual scan requested", symbolName: "arrow.triangle.2.circlepath")
```

In `setCompatibilityModeEnabled(_:)`, call:

```swift
recordConsoleActivity(
    title: enabled ? "Compatibility mode enabled" : "HTTPS mode enabled",
    detail: enabled ? "Local receiver prefers HTTP compatibility" : "Local receiver prefers HTTPS",
    symbolName: "network",
    tone: .neutral
)
```

- [ ] **Step 2: 发现设备和传输完成记录活动**

When discovery finds a new or changed endpoint, record:

```swift
recordConsoleActivity(title: "Device discovered", detail: "\(device.alias) · \(device.ip)", symbolName: "dot.radiowaves.left.and.right", tone: .good)
```

When incoming transfer completes, record success or failure:

```swift
recordConsoleActivity(
    title: success ? "Transfer received" : "Transfer failed",
    detail: success ? "Saved to Downloads" : (errorMsg ?? "Incoming transfer failed"),
    symbolName: success ? "tray.and.arrow.down.fill" : "exclamationmark.triangle.fill",
    tone: success ? .good : .warning
)
```

- [ ] **Step 3: 剪贴板发送记录活动但不保存正文**

After auto/manual clipboard text or image sends complete, record rows such as:

```swift
recordConsoleActivity(title: "Clipboard text sent", detail: group.primary.alias, symbolName: "doc.on.clipboard", tone: .good)
recordConsoleActivity(title: "Clipboard send failed", detail: group.primary.alias, symbolName: "exclamationmark.triangle.fill", tone: .warning)
```

Do not include clipboard text or image data in the activity detail.

### Task 5: 构建验证和截图检查

**Files:**
- Verify only

- [ ] **Step 1: 构建 AirSend**

Run:

```bash
swift build --package-path AirSend-macOS --product AirSend
```

Expected: build succeeds.

- [ ] **Step 2: 检查 git diff**

Run:

```bash
git diff -- AirSend-macOS/Sources/AirSend/UI/AirSendSettingsWindowController.swift AirSend-macOS/Sources/AirSend/UI/AirSendSettingsView.swift AirSend-macOS/Sources/AirSend/main.swift docs/superpowers/specs/2026-07-07-airsend-console-devices-design.md docs/superpowers/plans/2026-07-07-airsend-console-devices.md
```

Expected: diff only touches the console UI, activity snapshot wiring, Chinese spec, and this plan.

- [ ] **Step 3: 提交实现**

Run:

```bash
git add docs/superpowers/specs/2026-07-07-airsend-console-devices-design.md docs/superpowers/plans/2026-07-07-airsend-console-devices.md AirSend-macOS/Sources/AirSend/UI/AirSendSettingsWindowController.swift AirSend-macOS/Sources/AirSend/UI/AirSendSettingsView.swift AirSend-macOS/Sources/AirSend/main.swift
git commit -m "Add AirSend console devices view"
```

Expected: commit excludes unrelated untracked files.
