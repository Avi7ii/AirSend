// The Swift Programming Language
// https://docs.swift.org/swift-book

import Cocoa
import ServiceManagement
import IOKit.pwr_mgt

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, DropTargetViewDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    
    // Persistent Fingerprint
    // Persistent Fingerprint (Will be overwritten by real cert fingerprint)
    var fingerprint: String = UUID().uuidString
    
    lazy var discoveryService = UDPDiscoveryService(fingerprint: fingerprint, protocolType: .https)
    lazy var transferServer = HTTPTransferServer(fingerprint: fingerprint)
    lazy var clipboardSender = ClipboardSender(fingerprint: fingerprint)
    lazy var fileSender = FileSender(fingerprint: fingerprint)
    let clipboardService = ClipboardService()
    
    // UI Components
    var dropZoneWindow: DropZoneWindow!
    private var hasStartedTransfer = false
    private var isMinimizedToMenu = false
    private var isRequestingInBackground = false
    private var currentTransferProgress: Double = 0
    private var currentTransferTarget: String = ""
    private var transferProgressMenuItem: NSMenuItem?
    private var menuScanTimer: Timer?
    
    // 🔋 功耗优化：广播与清理定时器（连接设备后停止）
    private var broadcastTimer: Timer?
    private var cleanupTimer: Timer?
    private var isRestartingDiscovery = false
    private var lastDiscoveryRestartAt: Date = .distantPast
    private let discoveryRestartCooldown: TimeInterval = 2.0
    
    // Wakelock & Launch at Login
    private var wakelockAssertionID: IOPMAssertionID = 0
    private var isLaunchAtLoginEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService().status == SMAppService.Status.enabled
            }
            return false
        }
    }
    
    // Auto Update Preference
    private var isAutoUpdateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "auto_update_enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "auto_update_enabled")
            updateMenu()
        }
    }
    
    // Auto clipboard sync is disabled by default.
    private var isAutoClipboardSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "auto_clipboard_sync_enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "auto_clipboard_sync_enabled")
            updateMenu()
        }
    }
    
    private let broadcastSelectionKey = "broadcast"
    private let selectedGroupKeyStorage = "selected_device_group_key_v2"
    private let historyGroupKeysStorage = "history_device_group_keys_v2"
    private let preferredGroupCandidateStorage = "preferred_device_ids_by_group_v2"
    private let deviceConflictOnlineWindow: TimeInterval = 90.0
    private let androidAirSendRepository = "https://github.com/Avi7ii/AirSend"
    
    private struct DeviceGroupViewModel {
        let key: String
        let primary: Device
        let candidates: [Device]
        let isConflict: Bool
    }
    
    var devices: [String: Device] = [:] {
        didSet {
            saveDevices()
            dropStalePreferredDeviceIds()
        }
    }
    
    // Legacy keys kept for one compatibility cycle.
    private var legacyHistoryDeviceIds: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: "history_device_ids") ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "history_device_ids")
        }
    }
    
    var historyDeviceGroupKeys: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: historyGroupKeysStorage) ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: historyGroupKeysStorage)
        }
    }
    
    private var preferredDeviceIdsByGroup: [String: String] = {
        UserDefaults.standard.dictionary(forKey: "preferred_device_ids_by_group_v2") as? [String: String] ?? [:]
    }() {
        didSet {
            UserDefaults.standard.set(preferredDeviceIdsByGroup, forKey: preferredGroupCandidateStorage)
        }
    }
    
    // Selection state: "broadcast" or group key
    var selectedDeviceGroupKey: String = {
        UserDefaults.standard.string(forKey: "selected_device_group_key_v2") ?? "broadcast"
    }() {
        didSet {
            print("🚨 App: selectedDeviceGroupKey changed to [\(selectedDeviceGroupKey)]")
            UserDefaults.standard.set(selectedDeviceGroupKey, forKey: selectedGroupKeyStorage)
            if selectedDeviceGroupKey != broadcastSelectionKey {
                var current = historyDeviceGroupKeys
                current.insert(selectedDeviceGroupKey)
                historyDeviceGroupKeys = current
            }
            updateMenu()
            updateWindowStatus()
            updateDiscoveryTimers()
        }
    }
    
    // Track connection state
    var connectingSelectionKey: String? = nil {
        didSet {
            let idString = connectingSelectionKey ?? "nil"
            print("🚨 App: connectingSelectionKey changed to [\(idString)]")
            updateMenu()
        }
    }
    
    private func normalizeGroupComponent(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty {
            return "unknown"
        }
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed
    }
    
    private func deviceGroupKey(for device: Device) -> String {
        let alias = normalizeGroupComponent(device.alias)
        let model = normalizeGroupComponent(device.deviceModel)
        let type = normalizeGroupComponent(device.deviceType)
        return "\(alias)|\(model)|\(type)"
    }
    
    private func shortFingerprint(_ id: String) -> String {
        String(id.suffix(6))
    }
    
    private func isAndroidModuleDevice(_ device: Device) -> Bool {
        let alias = device.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = (device.deviceType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if alias.contains("airsend") && (alias.contains("module") || alias.contains("android mod")) {
            return true
        }
        return alias.contains("airsend") && type == "headless"
    }
    
    private func normalizedAndroidModuleModelName(_ rawModel: String?) -> String {
        let value = (rawModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return "Android Device"
        }
        
        let lower = value.lowercased()
        if lower == "ossi" || lower == "pkx110" || lower == "op60f5l1" {
            return "OnePlus 13T"
        }
        
        var normalized = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: "一加", with: "OnePlus")
        if normalized.hasPrefix("OnePlus"), normalized != "OnePlus" {
            let suffix = normalized.dropFirst("OnePlus".count).trimmingCharacters(in: .whitespaces)
            if !suffix.isEmpty {
                normalized = "OnePlus \(suffix)"
            }
        }
        
        return normalized
    }
    
    private func displayName(for device: Device) -> String {
        if isAndroidModuleDevice(device) {
            return normalizedAndroidModuleModelName(device.deviceModel)
        }
        return device.alias
    }
    
    private func displayTitle(for group: DeviceGroupViewModel) -> String {
        displayName(for: group.primary)
    }
    
    private func displaySubtitle(for group: DeviceGroupViewModel) -> String {
        if isAndroidModuleDevice(group.primary) {
            return "airsend module"
        }
        return group.primary.deviceModel ?? ""
    }
    
    private func displaySubtitle(for candidate: Device) -> String {
        "\(candidate.ip) • \(shortFingerprint(candidate.id))"
    }
    
    private func sortedCandidates(for groupKey: String, devices: [Device]) -> [Device] {
        let preferred = preferredDeviceIdsByGroup[groupKey]
        return devices.sorted { lhs, rhs in
            let lhsPreferred = (lhs.id == preferred)
            let rhsPreferred = (rhs.id == preferred)
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.lastSeen > rhs.lastSeen
        }
    }
    
    private func buildDeviceGroups() -> [DeviceGroupViewModel] {
        let now = Date()
        let grouped = Dictionary(grouping: devices.values, by: { deviceGroupKey(for: $0) })
        let groups: [DeviceGroupViewModel] = grouped.compactMap { groupKey, candidates in
            let sorted = sortedCandidates(for: groupKey, devices: candidates)
            guard let primary = sorted.first else { return nil }
            let onlineCount = sorted.filter { now.timeIntervalSince($0.lastSeen) <= deviceConflictOnlineWindow }.count
            return DeviceGroupViewModel(
                key: groupKey,
                primary: primary,
                candidates: sorted,
                isConflict: onlineCount > 1
            )
        }
        
        return groups.sorted {
            let lhsName = $0.primary.alias.lowercased()
            let rhsName = $1.primary.alias.lowercased()
            if lhsName == rhsName {
                return $0.primary.lastSeen > $1.primary.lastSeen
            }
            return lhsName < rhsName
        }
    }
    
    private func groupMap() -> [String: DeviceGroupViewModel] {
        Dictionary(uniqueKeysWithValues: buildDeviceGroups().map { ($0.key, $0) })
    }

    private func groupKeyComponents(_ key: String) -> (alias: String, model: String, type: String)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }

    private func recoverSelectedGroupIfPossible(from groups: [DeviceGroupViewModel], reason: String) {
        guard selectedDeviceGroupKey != broadcastSelectionKey else { return }
        if groups.contains(where: { $0.key == selectedDeviceGroupKey }) { return }
        guard let selectedParts = groupKeyComponents(selectedDeviceGroupKey) else { return }

        let aliasTypeMatches = groups
            .filter { group in
                guard let parts = groupKeyComponents(group.key) else { return false }
                return parts.alias == selectedParts.alias && parts.type == selectedParts.type
            }
            .sorted { $0.primary.lastSeen > $1.primary.lastSeen }

        if let remapped = aliasTypeMatches.first, remapped.key != selectedDeviceGroupKey {
            logTransfer("🔁 Selection recovered (\(reason)): \(selectedDeviceGroupKey) -> \(remapped.key)")
            selectedDeviceGroupKey = remapped.key
            return
        }

        if groups.count == 1, let only = groups.first, only.key != selectedDeviceGroupKey {
            logTransfer("🔁 Selection recovered (\(reason)) to sole online target: \(only.key)")
            selectedDeviceGroupKey = only.key
        }
    }
    
    private func selectedPrimaryDevice() -> Device? {
        guard selectedDeviceGroupKey != broadcastSelectionKey else { return nil }
        let groups = buildDeviceGroups()
        recoverSelectedGroupIfPossible(from: groups, reason: "selected-primary")
        return groups.first(where: { $0.key == selectedDeviceGroupKey })?.primary
    }
    
    private func targetGroupsForCurrentSelection() -> [DeviceGroupViewModel] {
        let groups = buildDeviceGroups()
        recoverSelectedGroupIfPossible(from: groups, reason: "send-targets")
        if selectedDeviceGroupKey == broadcastSelectionKey {
            return groups
        }
        return groups.filter { $0.key == selectedDeviceGroupKey }
    }
    
    private func rememberSuccessfulDevice(_ device: Device) {
        let key = deviceGroupKey(for: device)
        touchDeviceLastSeen(device.id)
        if preferredDeviceIdsByGroup[key] != device.id {
            preferredDeviceIdsByGroup[key] = device.id
            updateMenu()
        }
    }

    private func touchDeviceLastSeen(_ deviceId: String) {
        guard let existing = devices[deviceId] else { return }
        let refreshed = Device(
            id: existing.id,
            alias: existing.alias,
            ip: existing.ip,
            port: existing.port,
            deviceModel: existing.deviceModel,
            deviceType: existing.deviceType,
            version: existing.version,
            https: existing.https,
            download: existing.download,
            lastSeen: Date()
        )
        devices[deviceId] = refreshed
    }
    
    private func dropStalePreferredDeviceIds() {
        let validIds = Set(devices.keys)
        let pruned = preferredDeviceIdsByGroup.filter { validIds.contains($0.value) }
        if pruned.count != preferredDeviceIdsByGroup.count {
            preferredDeviceIdsByGroup = pruned
        }
    }
    
    private func migrateSelectionAndHistoryToV2IfNeeded() {
        let defaults = UserDefaults.standard
        let hasV2History = defaults.object(forKey: historyGroupKeysStorage) != nil
        let hasV2Selection = defaults.object(forKey: selectedGroupKeyStorage) != nil
        if hasV2History && hasV2Selection {
            return
        }
        
        let legacySelection = defaults.string(forKey: "selected_device_id") ?? broadcastSelectionKey
        let legacyHistory = legacyHistoryDeviceIds
        var migratedHistory = hasV2History ? historyDeviceGroupKeys : Set<String>()
        
        for legacyId in legacyHistory {
            if let device = devices[legacyId] {
                migratedHistory.insert(deviceGroupKey(for: device))
            }
        }
        
        let migratedSelection: String
        if hasV2Selection {
            migratedSelection = defaults.string(forKey: selectedGroupKeyStorage) ?? broadcastSelectionKey
        } else if legacySelection == broadcastSelectionKey {
            migratedSelection = broadcastSelectionKey
        } else if let selectedDevice = devices[legacySelection] {
            let groupKey = deviceGroupKey(for: selectedDevice)
            migratedSelection = groupKey
            migratedHistory.insert(groupKey)
        } else {
            migratedSelection = broadcastSelectionKey
        }
        
        historyDeviceGroupKeys = migratedHistory
        selectedDeviceGroupKey = migratedSelection
    }
    
    func updateWindowStatus() {
        // PROTECTION: Don't overwrite during active transfer, success, or error states
        if dropZoneWindow.isShowingSuccess || dropZoneWindow.isShowingError || dropZoneWindow.isPerformingDrop {
            return
        }

        let groups = buildDeviceGroups()
        recoverSelectedGroupIfPossible(from: groups, reason: "window-status")

        if selectedDeviceGroupKey == broadcastSelectionKey {
            dropZoneWindow.setStatusText("Broadcast to All")
        } else if let device = groups.first(where: { $0.key == selectedDeviceGroupKey })?.primary {
            dropZoneWindow.setStatusText("Send to \(displayName(for: device))")
        } else {
            // Selected device is offline/missing
            dropZoneWindow.setStatusText("Target Offline (Select another)")
        }
    }


    private func updateStatusItemIcon(showDot: Bool) {
        guard let button = statusItem.button else { return }
        let baseImage = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "LocalSend")
        
        if !showDot {
            button.image = baseImage
            return
        }
        
        // Create an image with a dot
        let dotSize: CGFloat = 8
        let imageSize: CGFloat = 18
        let newImage = NSImage(size: NSSize(width: imageSize, height: imageSize), flipped: false) { rect in
            baseImage?.draw(in: rect)
            
            // Draw a white dot in the bottom-right corner (standard indicator location)
            let dotRect = NSRect(x: rect.width - dotSize - 1, y: 1, width: dotSize, height: dotSize)
            NSColor.white.setFill()
            let path = NSBezierPath(ovalIn: dotRect)
            path.fill()
            
            return true
        }
        newImage.isTemplate = true // Allows it to follow system theme
        button.image = newImage
    }

    func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: "saved_devices")
        }
    }
    
    func loadDevices() {
        if let data = UserDefaults.standard.data(forKey: "saved_devices"),
           let saved = try? JSONDecoder().decode([String: Device].self, from: data) {
            
            // Sanitize IPs (remove ::ffff:)
            var cleanedDevices: [String: Device] = [:]
            for (id, device) in saved {
                var ip = device.ip
                if ip.hasPrefix("::ffff:") {
                    ip = String(ip.dropFirst(7))
                }
                
                let cleanedDevice = Device(
                    id: device.id,
                    alias: device.alias,
                    ip: ip,
                    port: device.port,
                    deviceModel: device.deviceModel,
                    deviceType: device.deviceType,
                    version: device.version,
                    https: device.https,
                    download: device.download,
                    lastSeen: device.lastSeen
                )
                cleanedDevices[id] = cleanedDevice
            }
            self.devices = cleanedDevices
        }
    }

    @objc func clearDeviceHistory() {
        print("🚨 App: Clearing device history...")
        self.devices.removeAll()
        self.historyDeviceGroupKeys.removeAll()
        self.legacyHistoryDeviceIds.removeAll()
        self.preferredDeviceIdsByGroup.removeAll()
        self.selectedDeviceGroupKey = broadcastSelectionKey
        
        UserDefaults.standard.removeObject(forKey: "saved_devices")
        UserDefaults.standard.removeObject(forKey: "history_device_ids")
        UserDefaults.standard.removeObject(forKey: "selected_device_id")
        UserDefaults.standard.removeObject(forKey: historyGroupKeysStorage)
        UserDefaults.standard.set(broadcastSelectionKey, forKey: selectedGroupKeyStorage)
        UserDefaults.standard.removeObject(forKey: preferredGroupCandidateStorage)
        
        updateMenu()
        updateWindowStatus()
    }

    // Drag Detection
    var lastDragCount: Int = 0
    var dragMonitorTimer: Timer?
    var isDragging: Bool = false
    var isDragInsideWindow: Bool = false // State Priority
    private var dropTimeoutWorkItem: DispatchWorkItem?
    private var hasFreshDragPayloadChange: Bool = false
    private let idleDragTimerInterval: TimeInterval = 1.0
    private let nearIconTriggerRadius: CGFloat = 140

    private func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    private func hasFilePayloadInDragPasteboard() -> Bool {
        guard NSEvent.pressedMouseButtons != 0 else { return false }
        let pboard = NSPasteboard(name: .drag)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return true
        }
        if let paths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !paths.isEmpty {
            return true
        }
        return false
    }

    private func filterValidLocalDropURLs(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Use a system symbol for the icon
            button.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "LocalSend")
            
            // Setup Drag & Drop
            let dropView = DropTargetView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.delegate = self
            button.addSubview(dropView)
        }
        
        // Initialize Drop Zone Window
        dropZoneWindow = DropZoneWindow()
        dropZoneWindow.onDrop = { [weak self] urls in
            self?.didPerformDrop(urls: urls)
        }
        dropZoneWindow.onDragEnter = { [weak self] in
            self?.isDragInsideWindow = true // Enter: Lock visibility
            self?.hideWorkItem?.cancel()
            self?.hideWorkItem = nil
        }
        dropZoneWindow.onDragExit = { [weak self] in
            self?.isDragInsideWindow = false // Exit: Unlock visibility
            // Rely on checkDragState to handle hiding based on Safe Zone
        }
        dropZoneWindow.onClickDuringTransfer = { [weak self] in
            guard let self = self else { return }
            logTransfer("📲 Minimizing transfer to menu bar")
            self.isMinimizedToMenu = true
            self.dropZoneWindow.hide()
            self.updateStatusItemIcon(showDot: true) // Show dot indicator
            self.updateMenu() // Refresh menu to include progress row
        }
        
        loadDevices()
        migrateSelectionAndHistoryToV2IfNeeded()
        setupMenu()
        updateWindowStatus()
        
        // Initialize Security & Start Services
        Task { @MainActor in
            do {
                // 1. Setup Certificate (Still needed for Fingerprint identity)
                let certManager = CertificateManager.shared
                try await certManager.setup()
                let realFingerprint = try await certManager.getFingerprint()
                
                logTransfer("🔐 Security Initialized. Fingerprint: \(realFingerprint)")
                
                // 2. Re-init all services with real fingerprint
                // Stop old ones if they were lazily initialized
                await self.transferServer.stop()
                self.discoveryService.stop()
                
                // Give OS more time to release ports (especially 53317 and Multicast)
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                
                self.fingerprint = realFingerprint
                
                // 3. Setup Services
                // Preference: HTTPS for official compatibility
                let targetProtocol = ProtocolType.https 
                logTransfer("🌐 Restoring HTTPS Mode for full protocol compatibility.")
                
                self.transferServer = HTTPTransferServer(fingerprint: realFingerprint)
                self.discoveryService = UDPDiscoveryService(fingerprint: realFingerprint, protocolType: targetProtocol)
                self.fileSender = FileSender(fingerprint: realFingerprint, localProtocol: targetProtocol)
                self.clipboardSender = ClipboardSender(fingerprint: realFingerprint, localProtocol: targetProtocol)
                
                // 4. Start Discovery FIRST
                startDiscovery()
                
                // Give UDP a moment to bind before TCP kicks in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                
                // 5. Start Transfer Server
                await startTransferServer()
                
                startClipboardService()
                startDragMonitoring()
            } catch {
                logTransfer("❌ Initialization Failed: \(error)")
                startDiscovery() 
                await startTransferServer()
                startClipboardService()
                startDragMonitoring()
            }
        }
    }
    
    func startDragMonitoring() {
        lastDragCount = NSPasteboard(name: .drag).changeCount
        
        // 空闲态 1.0s 慢检，检测到 drag 后切 0.1s 快检
        setDragTimerInterval(idleDragTimerInterval)
    }
    
    private func setDragTimerInterval(_ interval: TimeInterval) {
        dragMonitorTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDragState()
            }
        }
        timer.tolerance = interval * 0.5 // 🔋 允许 macOS 合并定时器唤醒
        dragMonitorTimer = timer
    }
    
    func checkDragState() {
        let currentCount = NSPasteboard(name: .drag).changeCount
        let hasPayload = hasFilePayloadInDragPasteboard()
        let detectedByChangeCount = (currentCount != lastDragCount)
        // Only activate by polling when this drag pasteboard has a fresh changeCount edge
        // and it contains local file payload.
        if detectedByChangeCount && hasPayload {
            // 检测到新的 drag，更新计数并标记状态
            lastDragCount = currentCount
            hasFreshDragPayloadChange = true
            isDragging = true
            dropZoneWindow.isDuringDrag = true  // 同步到 DropZoneWindow，让 show() 使用 orderFront
            // 🔋 升速到 0.1s（仅在空闲态时切换，避免重复 invalidate）
            if dragMonitorTimer?.timeInterval != 0.1 {
                setDragTimerInterval(0.1)
            }
            
            // ━━━ 关键：立刻预热窗口（不可见） ━━━
            // 必须在 drag 到达窗口区域之前就完成窗口操作（定位、orderFront），
            // 但保持 alpha=0，不提前打扰用户。
            // 后续仅在 near-icon/safe-zone 触发 show()，只做 alpha 淡入，
            // 避免 drag 飞行中执行 orderFront 导致 draggingExited 弹回。
            if !dropZoneWindow.isPerformingDrop && !dropZoneWindow.isShowingSuccess {
                updateWindowStatus()
                dropZoneWindow.prewarmForDrag(under: statusItem)
            }
        }

        // 兜底：若窗口可见但没有被标记为 dragging，且鼠标已释放，清理卡住状态。
        if !isDragging,
           NSEvent.pressedMouseButtons == 0,
           dropZoneWindow.alphaValue > 0.01,
           !dropZoneWindow.isAcceptingDragSession,
           !dropZoneWindow.isPerformingDrop,
           !dropZoneWindow.isShowingSuccess,
           !dropZoneWindow.isShowingError {
            dropZoneWindow.isDuringDrag = false
            dropZoneWindow.isIconExpanded = false
            dropZoneWindow.isBorderHighlighted = false
            dropZoneWindow.hide()
        }
        
        // 如果正在拖拽，检查鼠标是否松手
        if isDragging {
            let pressedButtons = NSEvent.pressedMouseButtons
            if pressedButtons == 0 {
                // 用户松手了
                let mouseLoc = NSEvent.mouseLocation
                let windowFrame = dropZoneWindow.frame
                let isMouseInWindow = NSMouseInRect(mouseLoc, windowFrame, false)
                
                isDragging = false
                dropZoneWindow.isDuringDrag = false  // 同步：drag 结束
                // 降速回空闲监测频率
                setDragTimerInterval(idleDragTimerInterval)
                
                // ━━━ 终极兜底：Drag Pasteboard 直读 ━━━
                // 问题根源：用户通过窗口时 enter/exit 抖动，松手时鼠标已在窗口外，
                // AppKit 不会调用 performDragOperation。
                // 方案：检测到松手时，若鼠标在窗口附近（60px 缓冲区）且曾进入过窗口，
                // 直接从 NSPasteboard(name: .drag) 读取文件，绕开 AppKit 边界判定。
                let hadDragNearWindow = isDragInsideWindow
                    || dropZoneWindow.isAcceptingDragSession
                    || isMouseInWindow
                let expandedFrame = windowFrame.insetBy(dx: -60, dy: -60)
                let isNearWindow = expandedFrame.contains(mouseLoc)
                
                if hadDragNearWindow && isNearWindow && !dropZoneWindow.isPerformingDrop {
                    if !hasFreshDragPayloadChange {
                        FileLogger.log("⚠️ [DragFallback] Skipped: no fresh drag payload change observed.")
                        dropZoneWindow.hide()
                        hasFreshDragPayloadChange = false
                        return
                    }
                    let pboard = NSPasteboard(name: .drag)
                    let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
                    if let urls = pboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
                       !urls.isEmpty {
                        let validURLs = filterValidLocalDropURLs(urls)
                        if validURLs.isEmpty {
                            FileLogger.log("⚠️ [DragFallback] Ignored non-local/non-existent payload.")
                            dropZoneWindow.hide()
                            return
                        }
                        FileLogger.log("🎣 [DragFallback] Pasteboard 兜底捕获：\(validURLs.count) 个文件。mouseLoc=\(mouseLoc), inWindow=\(isMouseInWindow)")
                        dropZoneWindow.isPerformingDrop = true
                        isDragInsideWindow = false
                        didPerformDrop(urls: validURLs)
                        return
                    } else {
                        FileLogger.log("⚠️ [DragFallback] Pasteboard 无文件（松手位置：\(mouseLoc)，窗口：\(windowFrame)）")
                    }
                }
                
                // 原有流程：若 drop 即将发生（AppKit 还未决定），等待 performDragOperation
                let isDropImminent = isMouseInWindow
                    || dropZoneWindow.isAcceptingDragSession
                    || isDragInsideWindow
                
                if isDropImminent {
                    dropTimeoutWorkItem?.cancel()
                    let item = DispatchWorkItem { [weak self] in
                        Task { @MainActor in
                            guard let self = self else { return }
                            if !self.dropZoneWindow.isShowingSuccess
                                && !self.dropZoneWindow.isPerformingDrop
                                && !self.dropZoneWindow.isAcceptingDragSession {
                                FileLogger.log("🚨 App: Drop timeout (1.5s)，force hiding.")
                                self.dropZoneWindow.hide()
                            }
                        }
                    }
                    self.dropTimeoutWorkItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
                    return
                }
                
                // 窗口外松手，正常隐藏
                hasFreshDragPayloadChange = false
                dropZoneWindow.hide()
                return
            }

            
            // 统一逻辑：鼠标按下期间的展示控制
            // 1. 状态优先：如果我们在窗口内（通过 DragEnter/Exit 事件），强制显示
            if isDragInsideWindow {
                if dropZoneWindow.alphaValue < 1 {
                    updateWindowStatus()
                    dropZoneWindow.show(under: statusItem)
                }
            }

            // 2. 近距离 & Safe Zone 逻辑
            if let buttonFrame = statusButtonScreenFrame() {
                let mouseLoc = NSEvent.mouseLocation
                let windowFrame = dropZoneWindow.frame
                
                let isMouseInWindow = NSMouseInRect(mouseLoc, windowFrame, false)
                
                let buttonCenter = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
                let distance = hypot(mouseLoc.x - buttonCenter.x, mouseLoc.y - buttonCenter.y)
                let isNearIcon = distance < nearIconTriggerRadius
                
                let isInSafeZone: Bool
                if dropZoneWindow.alphaValue > 0 {
                    let safeZone = windowFrame.insetBy(dx: -120, dy: -120)
                    isInSafeZone = safeZone.contains(mouseLoc)
                } else {
                    isInSafeZone = false
                }
                
                if !dropZoneWindow.isShowingSuccess {
                    dropZoneWindow.isIconExpanded = isMouseInWindow
                    dropZoneWindow.isBorderHighlighted = isMouseInWindow
                }
                
                let shouldStayVisible = !isMinimizedToMenu && (
                    isMouseInWindow || isNearIcon || isInSafeZone ||
                    dropZoneWindow.isShowingSuccess || dropZoneWindow.isShowingError ||
                    dropZoneWindow.isPerformingDrop || dropZoneWindow.isAcceptingDragSession
                )
                if shouldStayVisible {
                    if dropZoneWindow.alphaValue < 1 {
                        updateWindowStatus()
                        dropZoneWindow.show(under: statusItem)
                    }
                } else {
                    if dropZoneWindow.alphaValue > 0 {
                        dropZoneWindow.hide()
                    }
                }
            }
        }
    }
    
    // MARK: - DropTargetViewDelegate
    private var hideWorkItem: DispatchWorkItem?

    func didEnterDrag() {
        // Cancel any pending hide
        hideWorkItem?.cancel()
        hideWorkItem = nil

        // Some drag sources don't update NSPasteboard.changeCount in time.
        // Latch drag-active state as soon as AppKit tells us drag entered.
        isDragging = true
        dropZoneWindow.isDuringDrag = true
        lastDragCount = NSPasteboard(name: .drag).changeCount
        if dragMonitorTimer?.timeInterval != 0.1 {
            setDragTimerInterval(0.1)
        }
        
        if !dropZoneWindow.isPerformingDrop && !dropZoneWindow.isShowingSuccess {
            updateWindowStatus()
        }
        dropZoneWindow.show(under: statusItem)
    }
    
    func didExitDrag() {
        // Fail-safe: clean stale drag state if the button is already released.
        if NSEvent.pressedMouseButtons == 0,
           !dropZoneWindow.isAcceptingDragSession,
           !dropZoneWindow.isPerformingDrop,
           !dropZoneWindow.isShowingSuccess,
           !dropZoneWindow.isShowingError {
            isDragging = false
            hasFreshDragPayloadChange = false
            dropZoneWindow.isDuringDrag = false
            if dragMonitorTimer?.timeInterval != idleDragTimerInterval {
                setDragTimerInterval(idleDragTimerInterval)
            }
            dropZoneWindow.hide()
        }
    }
    
    private func scheduleHide(delay: TimeInterval = 0.2) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // Don't hide if showing success OR performing drop
            if self?.dropZoneWindow.isShowingSuccess == false && self?.dropZoneWindow.isPerformingDrop == false {
                self?.dropZoneWindow.hide()
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    private func sendTextWithFallback(_ text: String, to group: DeviceGroupViewModel) async throws {
        var lastError: Error?
        for candidate in group.candidates {
            do {
                try await clipboardSender.sendText(text, to: candidate)
                rememberSuccessfulDevice(candidate)
                return
            } catch {
                lastError = error
                logTransfer("⚠️ Text send failed for \(candidate.alias) [\(candidate.ip)] \(candidate.id): \(error)")
            }
        }
        
        if let error = lastError {
            throw error
        }
        throw NSError(domain: "AirSend", code: -1, userInfo: [NSLocalizedDescriptionKey: "No candidates available"])
    }
    
    private func sendImageWithFallback(_ imageData: Data, to group: DeviceGroupViewModel) async throws {
        var lastError: Error?
        for candidate in group.candidates {
            do {
                try await clipboardSender.sendImage(imageData, to: candidate)
                rememberSuccessfulDevice(candidate)
                return
            } catch {
                lastError = error
                logTransfer("⚠️ Image send failed for \(candidate.alias) [\(candidate.ip)] \(candidate.id): \(error)")
            }
        }
        
        if let error = lastError {
            throw error
        }
        throw NSError(domain: "AirSend", code: -1, userInfo: [NSLocalizedDescriptionKey: "No candidates available"])
    }
    
    private func sendFilesWithFallback(_ urls: [URL], to group: DeviceGroupViewModel) async throws {
        var lastError: Error?
        for candidate in group.candidates {
            do {
                logTransfer("App: Initiating send to \(candidate.alias) [\(candidate.ip)]")
                try await fileSender.sendFiles(urls, to: candidate)
                rememberSuccessfulDevice(candidate)
                return
            } catch {
                lastError = error
                logTransfer("⚠️ File send failed for \(candidate.alias) [\(candidate.ip)] \(candidate.id): \(error)")
            }
        }
        
        if let error = lastError {
            throw error
        }
        throw NSError(domain: "AirSend", code: -1, userInfo: [NSLocalizedDescriptionKey: "No candidates available"])
    }
    
    func didPerformDrop(urls: [URL]) {
        isDragInsideWindow = false
        isDragging = false
        hasFreshDragPayloadChange = false
        dropZoneWindow.isDuringDrag = false
        if dragMonitorTimer?.timeInterval != idleDragTimerInterval {
            setDragTimerInterval(idleDragTimerInterval)
        }
        let validURLs = filterValidLocalDropURLs(urls)
        guard !validURLs.isEmpty else {
            logTransfer("⚠️ Drop ignored: payload is not a valid local file list.")
            dropZoneWindow.resetFromSuccess()
            dropZoneWindow.showError(message: "Drop files only")
            dropZoneWindow.show(under: statusItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.dropZoneWindow.isShowingError {
                    self.dropZoneWindow.hide()
                }
            }
            return
        }
        
        let targets = targetGroupsForCurrentSelection()
        
        guard !targets.isEmpty else {
            logTransfer("⚠️ Drop aborted: no target groups available for current selection.")
            dropZoneWindow.resetFromSuccess()
            dropZoneWindow.showError(message: "Device Offline")
            dropZoneWindow.show(under: statusItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.dropZoneWindow.isShowingError {
                    self.dropZoneWindow.hide()
                }
            }
            return
        }

        // 1. Initial Phase: Requesting
        dropZoneWindow.setStatusText("Requesting...")
        enableWakelock()
        dropZoneWindow.isPerformingDrop = true
        self.hasStartedTransfer = false
        
        Task {
            let app = self
            
            // 8s Grace period timer: if no response in 8s, hide to background
            let autoHideTask = Task {
                try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        // If still requesting and haven't started actual sending
                        if !app.hasStartedTransfer && app.dropZoneWindow.isPerformingDrop {
                            logTransfer("⏱️ Grace period expired: Hiding to background...")
                            app.dropZoneWindow.hide()
                            app.isRequestingInBackground = true
                            app.updateStatusItemIcon(showDot: true) // Show dot when in background
                            app.updateMenu() // Refresh menu to show "Requesting" item
                        }
                    }
                }
            }

            // Safety net: Timeout for the entire handshake+transfer lifecycle
            // Will be cancelled once transfer actually starts (onAccepted)
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        if self.dropZoneWindow.isPerformingDrop && !self.dropZoneWindow.isShowingSuccess {
                            logTransfer("🚨 App: Transfer timeout (120s), closing.")
                            Task {
                                await self.fileSender.cancelCurrentTransfer()
                            }
                            self.isRequestingInBackground = false
                            self.dropZoneWindow.isPerformingDrop = false
                            self.dropZoneWindow.hide()
                            self.updateStatusItemIcon(showDot: false) // Clear dot on timeout
                            self.updateMenu()
                        }
                    }
                }
            }
            
            await fileSender.setOnCancelled {
                logTransfer("🛑 [App] fileSender.onCancelled callback triggered (Async).")
                DispatchQueue.main.async {
                    app.disableWakelock()
                    app.isRequestingInBackground = false
                    app.updateStatusItemIcon(showDot: false) // Clear dot on cancellation
                    app.updateMenu()
                    logTransfer("🛑 [App] fileSender.onCancelled handling on MainActor. PerformingDrop: \(app.dropZoneWindow.isPerformingDrop), ShowingSuccess: \(app.dropZoneWindow.isShowingSuccess)")
                    if app.dropZoneWindow.isPerformingDrop && !app.dropZoneWindow.isShowingSuccess {
                        logTransfer("🚨 [App] Showing Cancelled error on DropZoneWindow.")
                        app.dropZoneWindow.showError(message: "Cancelled")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            app.dropZoneWindow.hide()
                        }
                    } else {
                         logTransfer("⚠️ [App] Ignored cancellation because window state doesn't match dropping state.")
                    }
                }
            }

            // A. Prepare Phase callbacks
            await fileSender.setOnAccepted {
                autoHideTask.cancel() // Cancel the 5s timer immediately on acceptance
                timeoutTask.cancel()  // Cancel the 120s safety net — transfer is active now
                Task { @MainActor in
                    // Transition to Sending phase immediately when accepted
                    guard !app.dropZoneWindow.isShowingSuccess else { return }
                    
                    app.hasStartedTransfer = true
                    app.isRequestingInBackground = false
                    app.isMinimizedToMenu = false
                    app.currentTransferProgress = 0
                    app.updateMenu() // Remove requesting item
                    app.dropZoneWindow.resetFromSuccess() // Clear "Requesting" state
                    let targetName = targets.first.map { app.displayTitle(for: $0) } ?? "device"
                    app.currentTransferTarget = targetName
                    app.dropZoneWindow.setStatusText("Sending to \(targetName)...")
                    app.dropZoneWindow.isPerformingDrop = true 
                    
                    // Only show window if it was NOT hidden by the 3s timer 
                    // (User said "挂后台", so we respect the background state if it already went there)
                    if app.dropZoneWindow.alphaValue > 0.1 {
                        app.dropZoneWindow.show(under: app.statusItem)
                    } else {
                        logTransfer("📲 Transfer started in background mode.")
                        app.updateStatusItemIcon(showDot: true) // Ensure dot is visible during background transfer
                    }
                }
            }

            await fileSender.setOnProgress { (progress: Double) in
                Task { @MainActor in
                    app.currentTransferProgress = progress
                    if !app.dropZoneWindow.isShowingSuccess {
                        app.dropZoneWindow.setProgress(progress)
                    }
                    // Update menu progress view if minimized
                    if app.isMinimizedToMenu, let menuItem = app.transferProgressMenuItem,
                       let progressView = menuItem.view as? TransferProgressMenuView {
                        progressView.progress = progress
                    }
                }
            }

            var allSuccessful = true
            var lastErrorMsg = ""
            
            // B. Perform actual send
            for group in targets {
                do {
                    try await self.sendFilesWithFallback(validURLs, to: group)
                } catch {
                    logTransfer("App: Error sending to group \(group.key): \(error)")
                    lastErrorMsg = error.localizedDescription
                    allSuccessful = false
                }
            }
            
            timeoutTask.cancel()
            
            // C. Completion Phase
            DispatchQueue.main.async {
                app.disableWakelock()
            }
            await MainActor.run {
                if allSuccessful {
                    logTransfer("✅ Final Success: Showing popup.")
                    app.isMinimizedToMenu = false
                    app.isRequestingInBackground = false
                    app.updateStatusItemIcon(showDot: false) // Clear dot on success
                    app.updateMenu()
                    dropZoneWindow.setStatusText("Sent!")
                    dropZoneWindow.showSuccess()
                    
                    // CRITICAL: Always show success popup, even if it was "hung in background"
                    app.dropZoneWindow.show(under: app.statusItem)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.dropZoneWindow.hide()
                    }
                } else {
                    let msg: String
                    let errLower = lastErrorMsg.lowercased()
                    
                    // If transfer was already in progress and connection dropped,
                    // it means the peer cancelled — not "device offline"
                    if errLower.contains("cancel") || errLower.contains("closed") || errLower.contains("reset") {
                        msg = "Cancelled"
                    } else if (errLower.contains("connection") || errLower.contains("1005") || errLower.contains("1001")) && app.hasStartedTransfer {
                        msg = "Cancelled"  // Connection lost/timeout mid-transfer = peer cancelled
                    } else if errLower.contains("cancel") || errLower.contains("999") {
                        msg = "Cancelled"
                    } else if errLower.contains("connect") {
                        msg = "Device Offline"
                    } else if errLower.contains("timeout") {
                        msg = "Request Timeout"
                    } else if errLower.contains("declined") || errLower.contains("403") {
                        msg = "Declined by Peer"
                    } else {
                        msg = "Transfer Failed"
                    }
                    
                    app.isMinimizedToMenu = false
                    app.isRequestingInBackground = false
                    app.updateStatusItemIcon(showDot: false) // Clear dot on error
                    app.updateMenu()
                    dropZoneWindow.showError(message: msg)
                    
                    // Always show error popup, even if minimized to menu
                    app.dropZoneWindow.show(under: app.statusItem)
                    
                    // Keep error visible for 3 seconds
                    logTransfer("🚨 UI: Showing error status: \(msg)")
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        // Double check if we are still showing an error (not overwritten by a new drop)
                        if self.dropZoneWindow.isShowingError { 
                            self.dropZoneWindow.hide()
                        }
                    }
                }
                app.hasStartedTransfer = false // Reset after error mapping logic
            }
        }
    }
    
    func startClipboardService() {
        // 重新接上剪贴板变化的回调
        clipboardService.onNewContent = { [weak self] newText in
            guard let self = self else { return }
            guard self.isAutoClipboardSyncEnabled else { return }
            
            let targets = self.targetGroupsForCurrentSelection()
            
            guard !targets.isEmpty else {
                print("📋 剪贴板已更新，但没有可用的目标设备")
                return
            }
            
            print("📋 检测到剪贴板变化 (\(newText.count) 字符)，准备自动发送给 \(targets.count) 个设备组")
            
            for group in targets {
                Task {
                    do {
                        try await self.sendTextWithFallback(newText, to: group)
                        print("✅ 成功发送剪贴板到: \(group.primary.alias)")
                    } catch {
                        print("❌ 发送剪贴板到 \(group.primary.alias) 失败: \(error)")
                    }
                }
            }
        }
        
        // 🚀 新增图片剪贴板监听
        clipboardService.onNewImage = { [weak self] imageData in
            guard let self = self else { return }
            guard self.isAutoClipboardSyncEnabled else { return }
            
            let targets = self.targetGroupsForCurrentSelection()
            
            guard !targets.isEmpty else { return }
            print("🖼 检测到剪贴板图片 (\(imageData.count) bytes)，准备发送给 \(targets.count) 个设备组...")
            
            for group in targets {
                Task {
                    do {
                        try await self.sendImageWithFallback(imageData, to: group)
                        print("✅ 成功发送剪贴板图片到: \(group.primary.alias)")
                    } catch {
                        print("❌ 发送图片到 \(group.primary.alias) 失败: \(error)")
                    }
                }
            }
        }
        
        // 启动轮询
        clipboardService.start()
    }
    
    func startTransferServer() async {
        // Setup Reverse Discovery Callback
        await transferServer.setOnDeviceRegistered { [weak self] device in
            DispatchQueue.main.async {
                self?.devices[device.id] = device
                self?.updateMenu()
            }
        }

        await transferServer.setOnTextReceived { [weak self] text in
            DispatchQueue.main.async {
                print("Received text from remote, updating clipboard...")
                self?.clipboardService.setContent(text)
            }
        }
        
        await transferServer.setOnCancelReceived { [weak self] in
            guard let self = self else { return }
            logTransfer("🛑 [App] HTTPTransferServer.onCancelReceived triggered.")
            Task {
                await self.fileSender.cancelCurrentTransfer()
            }
        }
        
        await transferServer.setOnTransferRequest { [weak self] request in
            logTransfer("📥 [App] Incoming transfer request from \(request.senderAlias) (\(request.fileCount) files, \(request.totalSize) bytes)")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.enableWakelock()
                self.hasStartedTransfer = true
                self.dropZoneWindow.resetFromSuccess()
                self.dropZoneWindow.setStatusText("Receiving from \(request.senderAlias)...")
                self.dropZoneWindow.isPerformingDrop = true
                self.dropZoneWindow.setProgress(0)
                self.dropZoneWindow.show(under: self.statusItem)
            }
            return true // Auto-accept
        }
        
        await transferServer.setOnProgress { [weak self] progress in
            DispatchQueue.main.async {
                self?.dropZoneWindow.setProgress(progress)
            }
        }
        
        await transferServer.setOnTransferComplete { [weak self] (success, errorMsg) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.disableWakelock()
                logTransfer("🏁 [App] Incoming transfer complete. Success: \(success), Error: \(errorMsg ?? "nil")")
                
                if success {
                    self.dropZoneWindow.setStatusText("Saved!")
                    self.dropZoneWindow.showSuccess()
                    self.dropZoneWindow.show(under: self.statusItem)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.dropZoneWindow.hide()
                    }
                } else {
                    let msg: String
                    let errLower = (errorMsg ?? "").lowercased()
                    if errLower.contains("cancel") || errLower.contains("truncated") {
                        msg = "Cancelled"
                    } else {
                        msg = "Failed"
                    }
                    self.dropZoneWindow.showError(message: msg)
                    self.dropZoneWindow.show(under: self.statusItem)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                         if self.dropZoneWindow.isShowingError {
                             self.dropZoneWindow.hide()
                         }
                    }
                }
                self.hasStartedTransfer = false
            }
        }
        
        do {
            if discoveryService.protocolType == .https {
                logTransfer("🌐 Fetching certificate for HTTPS Server...")
                let p12Data = try await CertificateManager.shared.getP12Data()
                try await transferServer.start(p12Data: p12Data)
            } else {
                logTransfer("🌐 Starting Server in HTTP mode...")
                try await transferServer.start()
            }
        } catch {
            logTransfer("❌ CRITICAL: Failed to start Transfer Server: \(error)")
            logTransfer("❌ Current Mode: \(discoveryService.protocolType). NO FALLBACK allowed to prevent protocol mismatch.")
            // Do NOT try to start in plain mode here. If it fails, we want it to fail loudly.
        }
    }
    
    func startDiscovery() {
        discoveryService.onTransportFailure = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.restartDiscoveryService(reason: reason, triggerScan: true)
            }
        }
        
        discoveryService.onDeviceFound = { [weak self] device in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                // Track if this is a truly new device (id not in keys)
                let isNewDevice = self.devices[device.id] == nil
                
                // Update device state (important for heartbeat/lastSeen)
                self.devices[device.id] = device
                
                // Only trigger expensive UI rebuild if it's a new discovery
                if isNewDevice {
                    logTransfer("✅ Discovery: Found device [\(device.alias)] at \(device.ip):\(device.port)")
                    self.updateMenu()
                }
            }
        }
        
        discoveryService.start()
        
        // 🔋 发送一次初始广播，然后交由 updateDiscoveryTimers() 管理后续定时
        discoveryService.sendAnnouncement()
        updateDiscoveryTimers()
    }
    
    private func restartDiscoveryService(reason: String, triggerScan: Bool) {
        let now = Date()
        if isRestartingDiscovery {
            logTransfer("⏳ Discovery restart already in progress. Skip [\(reason)].")
            return
        }
        if now.timeIntervalSince(lastDiscoveryRestartAt) < discoveryRestartCooldown {
            logTransfer("⏱️ Discovery restart throttled. Skip [\(reason)].")
            return
        }
        
        isRestartingDiscovery = true
        lastDiscoveryRestartAt = now
        
        let currentProtocol = discoveryService.protocolType
        let currentFingerprint = fingerprint
        logTransfer("♻️ Restarting discovery service: \(reason)")
        
        discoveryService.stop()
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        
        discoveryService = UDPDiscoveryService(fingerprint: currentFingerprint, protocolType: currentProtocol)
        startDiscovery()
        if triggerScan {
            discoveryService.triggerScan()
        }
        
        isRestartingDiscovery = false
    }
    
    // 🔋 连接感知的定时器管理
    func updateDiscoveryTimers() {
        if selectedDeviceGroupKey != broadcastSelectionKey {
            // 已连接特定设备组：停止广播，但保留清理，避免陈旧设备累积。
            broadcastTimer?.invalidate(); broadcastTimer = nil
            logTransfer("🔋 Discovery: 已连接设备组，停止定时广播，保留清理")
        } else if broadcastTimer == nil {
            // Broadcast 模式：30s 广播
            broadcastTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.discoveryService.sendAnnouncement()
                }
            }
            broadcastTimer?.tolerance = 15.0 // 🔋
            logTransfer("🔋 Discovery: 广播模式，30s 广播")
        }
        
        if cleanupTimer == nil {
            cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.cleanupOfflineDevices()
                }
            }
            cleanupTimer?.tolerance = 30.0 // 🔋
            logTransfer("🔋 Discovery: 清理定时器已启用，60s 轮询")
        }
    }
    
    private func cleanupOfflineDevices() {
        let now = Date()
        var hasChanges = false
        let timeout: TimeInterval = 120.0 // Keep selected targets from flapping offline too aggressively.
        for (id, device) in self.devices {
            let groupKey = deviceGroupKey(for: device)
            if selectedDeviceGroupKey != broadcastSelectionKey && groupKey == selectedDeviceGroupKey {
                // Keep current selection candidates to avoid immediate "Target Offline" flapping.
                continue
            }
            if now.timeIntervalSince(device.lastSeen) > timeout {
                logTransfer("🧹 Cleanup: Device [\(device.alias)] timed out and removed.")
                self.devices.removeValue(forKey: id)
                hasChanges = true
            }
        }
        if hasChanges {
            self.updateMenu()
        }
    }
    
    private func groupSelectionActionKey(_ groupKey: String) -> String {
        "group|\(groupKey)"
    }
    
    private func deviceSelectionActionKey(_ deviceId: String) -> String {
        "device|\(deviceId)"
    }
    
    private func decodeSelectionActionKey(_ actionKey: String) -> (groupKey: String?, deviceId: String?) {
        if actionKey.hasPrefix("group|") {
            return (String(actionKey.dropFirst("group|".count)), nil)
        }
        if actionKey.hasPrefix("device|") {
            return (nil, String(actionKey.dropFirst("device|".count)))
        }
        return (nil, nil)
    }
    
    private func addGroupMenuEntries(to menu: NSMenu, group: DeviceGroupViewModel, canForget: Bool) {
        if group.isConflict {
            for candidate in group.candidates {
                addDeviceItem(
                    to: menu,
                    device: candidate,
                    actionKey: deviceSelectionActionKey(candidate.id),
                    groupKey: group.key,
                    activeDeviceIdInGroup: group.primary.id,
                    canForget: canForget,
                    forgetKey: group.key,
                    displayTitle: displayTitle(for: group),
                    displaySubtitle: displaySubtitle(for: candidate),
                    isExpandedCandidate: true
                )
            }
        } else {
            addDeviceItem(
                to: menu,
                device: group.primary,
                actionKey: groupSelectionActionKey(group.key),
                groupKey: group.key,
                activeDeviceIdInGroup: group.primary.id,
                canForget: canForget,
                forgetKey: group.key,
                displayTitle: displayTitle(for: group),
                displaySubtitle: displaySubtitle(for: group),
                isExpandedCandidate: false
            )
        }
    }
    
    func setupMenu() {
        let menu: NSMenu
        if let existing = statusItem.menu {
            menu = existing
            menu.removeAllItems()
        } else {
            menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            statusItem.menu = menu
        }
        
        if isRequestingInBackground {
            let infoItem = NSMenuItem()
            infoItem.view = RequestIndicatorView(message: "Waiting for phone...")
            infoItem.isEnabled = false
            menu.addItem(infoItem)
            menu.addItem(NSMenuItem.separator())
        }

        // 1. Core Action
        menu.addItem(NSMenuItem(title: "Send Clipboard", action: #selector(sendClipboard), keyEquivalent: "s"))
        let autoClipboardItem = NSMenuItem()
        autoClipboardItem.view = AutoClipboardToggleMenuItemView(
            title: "Auto Send Clipboard",
            isOn: isAutoClipboardSyncEnabled,
            onToggle: { [weak self] enabled in
                self?.setAutoClipboardSyncEnabled(enabled, showInfoIfEnabling: true)
            }
        )
        menu.addItem(autoClipboardItem)
        menu.addItem(NSMenuItem.separator())
        
        let groups = buildDeviceGroups()
        
        // 2. KNOWN DEVICES
        let knownGroups = groups.filter {
            historyDeviceGroupKeys.contains($0.key) || selectedDeviceGroupKey == $0.key
        }
            
        if !knownGroups.isEmpty {
            let headerItem = NSMenuItem()
            headerItem.view = MenuSectionHeaderView(title: "KNOWN DEVICES")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            
            for group in knownGroups {
                addGroupMenuEntries(to: menu, group: group, canForget: true)
            }
            menu.addItem(NSMenuItem.separator())
        }
        
        // 3. OTHER DEVICES
        let otherGroups = groups.filter {
            !historyDeviceGroupKeys.contains($0.key) && selectedDeviceGroupKey != $0.key
        }
            
        let otherHeaderItem = NSMenuItem()
        otherHeaderItem.view = MenuSectionHeaderView(title: "OTHER DEVICES")
        otherHeaderItem.isEnabled = false
        menu.addItem(otherHeaderItem)
        
        if otherGroups.isEmpty {
            let searchingItem = NSMenuItem(title: "  Searching nearby...", action: nil, keyEquivalent: "")
            searchingItem.isEnabled = false
            menu.addItem(searchingItem)
        } else {
            for group in otherGroups {
                addGroupMenuEntries(to: menu, group: group, canForget: false)
            }
        }
        
        // 4. BROADCAST
        let broadcastItem = NSMenuItem(title: "All Devices (Broadcast)", action: #selector(deviceSelected(_:)), keyEquivalent: "")
        broadcastItem.representedObject = broadcastSelectionKey
        broadcastItem.state = selectedDeviceGroupKey == broadcastSelectionKey ? .on : .off
        menu.addItem(broadcastItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 5. ADVANCED SUBMENU
        let advancedMenu = NSMenu(title: "Advanced")
        advancedMenu.autoenablesItems = false
        
        advancedMenu.addItem(NSMenuItem(title: "Add Device by IP...", action: #selector(addDeviceByIP), keyEquivalent: "a"))
        advancedMenu.addItem(NSMenuItem(title: "Clear Discovered Devices", action: #selector(clearDeviceHistory), keyEquivalent: ""))
        advancedMenu.addItem(NSMenuItem(title: "Reset Identity", action: #selector(resetIdentity(_:)), keyEquivalent: ""))
        
        advancedMenu.addItem(NSMenuItem.separator())
        let autoUpdateItem = NSMenuItem(title: "Auto-check for Updates", action: #selector(toggleAutoUpdate(_:)), keyEquivalent: "")
        autoUpdateItem.state = isAutoUpdateEnabled ? .on : .off
        advancedMenu.addItem(autoUpdateItem)
        
        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.submenu = advancedMenu
        menu.addItem(advancedItem)
        
        // 6. SYSTEM STATUS
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 7. VERSION & UPDATE
        let updateItem = NSMenuItem()
        updateItem.view = UpdateMenuItemView()
        menu.addItem(updateItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Rescan and Refresh", action: #selector(scanForDevices(_:)), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit AirSend", action: #selector(quit), keyEquivalent: "q"))
    }
    
    private func addDeviceItem(
        to menu: NSMenu,
        device: Device,
        actionKey: String,
        groupKey: String,
        activeDeviceIdInGroup: String,
        canForget: Bool,
        forgetKey: String,
        displayTitle: String,
        displaySubtitle: String,
        isExpandedCandidate: Bool
    ) {
        // IMPORTANT: No action here to prevent menu from auto-closing on click
        let deviceItem = NSMenuItem(title: device.alias, action: nil, keyEquivalent: "")
        deviceItem.representedObject = actionKey
        deviceItem.isEnabled = true 
        
        let connectionState: DeviceMenuItemView.ConnectionState
        if connectingSelectionKey == actionKey {
            connectionState = .connecting
        } else if selectedDeviceGroupKey == groupKey {
            if isExpandedCandidate {
                connectionState = (device.id == activeDeviceIdInGroup) ? .connected : .idle
            } else {
                connectionState = .connected
            }
        } else {
            connectionState = .idle
        }
        
        deviceItem.view = DeviceMenuItemView(
            device: device,
            actionKey: actionKey,
            state: connectionState,
            canForget: canForget,
            forgetKey: forgetKey,
            displayTitle: displayTitle,
            displaySubtitle: displaySubtitle
        )
        menu.addItem(deviceItem)
    }
    
    func updateMenu() {
        setupMenu()
        updateWindowStatus()
    }
    
    @objc func sendClipboard() {
        print("Send Clipboard clicked")
        if let str = NSPasteboard.general.string(forType: .string) {
            let targets = targetGroupsForCurrentSelection()
            
            print("Clipboard content found: \(str.count) chars")
            print("Sending to \(targets.count) device groups")
            
            for group in targets {
                print("Targeting group: \(group.primary.alias) with \(group.candidates.count) candidates")
                Task {
                    do {
                        try await self.sendTextWithFallback(str, to: group)
                    } catch {
                        print("Error sending to \(group.primary.alias): \(error)")
                    }
                }
            }
        } else {
            print("No text in clipboard")
        }
    }
    
    @objc func scanForDevices(_ sender: NSMenuItem) {
        print("Manual scan triggered - cleaning up offline other devices")
        
        // Cleanup logic: Keep only history groups or the currently selected group
        let historyGroups = self.historyDeviceGroupKeys
        let selectedGroup = self.selectedDeviceGroupKey
        
        var nextDevices: [String: Device] = [:]
        for (id, device) in devices {
            let groupKey = deviceGroupKey(for: device)
            if historyGroups.contains(groupKey) || selectedGroup == groupKey {
                nextDevices[id] = device
            }
        }
        
        self.devices = nextDevices
        
        restartDiscoveryService(reason: "manual refresh", triggerScan: true)
        
        // Prevent menu from closing and show immediate feedback
        // The menu normally closes on action. We can pop it back up immediately
        // or just let the user re-open it. To really simulate Wi-Fi behavior
        // where you stay IN the menu, we'd need a more complex view-based menu.
        // For now, let's just make it fast and responsive.
        
        // Trick: Reset the menu to show "Scanning" status without closing 
        // if it was triggered via a key equivalent. 
        // If clicked, it WILL close. To stay open, we re-pop it.
        DispatchQueue.main.async {
            self.statusItem.button?.performClick(nil)
        }
    }
    
    @objc func resetIdentity(_ sender: AnyObject?) {
        logTransfer("🧨 Starting Identity Reset...")
        
        Task { @MainActor in
            // 1. Stop services
            // Silent operation - no UI feedback
            
            await transferServer.stop()
            discoveryService.stop()
            
            // 2. Regenerate Certificate
            do {
                try await CertificateManager.shared.forceRegenerate()
                let newFingerprint = try await CertificateManager.shared.getFingerprint()
                self.fingerprint = newFingerprint
                logTransfer("✅ New Identity Fingerprint: \(newFingerprint)")
                
                // 3. Restart Services
                // Preference: HTTPS
                let targetProtocol = ProtocolType.https
                
                self.transferServer = HTTPTransferServer(fingerprint: newFingerprint)
                self.discoveryService = UDPDiscoveryService(fingerprint: newFingerprint, protocolType: targetProtocol)
                self.fileSender = FileSender(fingerprint: newFingerprint, localProtocol: targetProtocol)
                self.clipboardSender = ClipboardSender(fingerprint: newFingerprint, localProtocol: targetProtocol)
                
                // Clear discovered devices to force fresh discovery
                let keptDevices = devices.filter {
                    let groupKey = self.deviceGroupKey(for: $0.value)
                    return self.historyDeviceGroupKeys.contains(groupKey) || self.selectedDeviceGroupKey == groupKey
                }
                self.devices = keptDevices
                
                startDiscovery()
                await startTransferServer()
                startClipboardService()
                startDragMonitoring()
                
                logTransfer("✨ Identity Reset Complete. Services restarted.")
                
                // Silent completion
                DispatchQueue.main.async {
                    self.updateMenu()
                }
                
            } catch {
                logTransfer("❌ Reset Identity Failed: \(error)")
            }
        }
    }

    @objc func addDeviceByIP() {
        let alert = NSAlert()
        alert.messageText = "Add Device by IP"
        alert.informativeText = "Enter the IP address of the target LocalSend instance:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let inputTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputTextField.placeholderString = "192.168.1.100"
        alert.accessoryView = inputTextField
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let ip = inputTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty {
                // For manual IP, we create a pseudo-device or just try to send
                // Let's create a temporary device object
                let manualDevice = Device(
                    id: "manual-\(ip)",
                    alias: "Manual IP (\(ip))",
                    ip: ip,
                    port: 53317,
                    deviceModel: "Remote Device",
                    deviceType: "desktop",
                    version: "2.4",
                    https: false,
                    download: true,
                    lastSeen: Date()
                )
                self.devices[manualDevice.id] = manualDevice
                self.selectedDeviceGroupKey = self.deviceGroupKey(for: manualDevice)
                self.preferredDeviceIdsByGroup[self.selectedDeviceGroupKey] = manualDevice.id
            }
        }
    }
    
    private func setAutoClipboardSyncEnabled(_ enabled: Bool, showInfoIfEnabling: Bool) {
        if isAutoClipboardSyncEnabled != enabled {
            isAutoClipboardSyncEnabled = enabled
        }
        
        guard enabled, showInfoIfEnabling else {
            return
        }
        
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Auto Clipboard Sync Requires AirSend on Android"
        alert.informativeText = """
        The official LocalSend app can receive clipboard content manually, but background auto-send is only supported with the AirSend Android build.
        
        This setup requires root-level integration (Magisk + LSPosed). It is intended for users with Android modding experience.
        
        Repository: \(androidAirSendRepository)
        """
        alert.addButton(withTitle: "Open Repository")
        alert.addButton(withTitle: "Continue")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let url = URL(string: androidAirSendRepository) {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        print("📡 Menu: Opening... starting high-frequency scan.")
        // Perform an initial scan immediately
        discoveryService.triggerScan()
        
        // Auto Update Check (if enabled)
        if isAutoUpdateEnabled {
            UpdateService.shared.checkUpdate(explicit: false)
        }
        
        // Start a 1-second timer for continuous scanning while menu is open
        menuScanTimer?.invalidate()
        menuScanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Stop scanning if a specific device is selected or being connected
                if self?.selectedDeviceGroupKey != self?.broadcastSelectionKey || self?.connectingSelectionKey != nil {
                    print("📡 Menu: Active selection/connection detected, stopping aggressive scan.")
                    self?.menuScanTimer?.invalidate()
                    self?.menuScanTimer = nil
                    return
                }
                
                print("📡 Menu: Periodic scan while open...")
                self?.discoveryService.triggerScan()
            }
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        print("📡 Menu: Closed. Stopping high-frequency scan.")
        menuScanTimer?.invalidate()
        menuScanTimer = nil
    }
    
    @objc func deviceSelected(_ sender: NSMenuItem) {
        guard let selectionKey = sender.representedObject as? String else {
            print("🚨 Selector ERROR: Missing ID in representedObject")
            return 
        }
        
        print("🚨 Selector: User clicked selection [\(selectionKey)]")
        
        if selectionKey == broadcastSelectionKey {
            self.selectedDeviceGroupKey = broadcastSelectionKey
            return
        }
        
        // For physical devices, we handle it via handleDeviceClick now
        handleDeviceClick(id: selectionKey, closeMenu: true)
    }

    func handleDeviceClick(id: String, closeMenu: Bool) {
        print("🚨 App: Handling device click for [\(id)], closeMenu: \(closeMenu)")
        
        if connectingSelectionKey == id { return }
        
        self.connectingSelectionKey = id
        
        // If it's a manual selection that SHOULD close the menu (like from broadcast), 
        // we let it. But for Wi-Fi style, we stay open.
        
        // Simulate connection delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            print("🚨 App: Connection successful for [\(id)]")
            self.connectingSelectionKey = nil
            
            if id == self.broadcastSelectionKey {
                self.selectedDeviceGroupKey = self.broadcastSelectionKey
                return
            }
            
            let decoded = self.decodeSelectionActionKey(id)
            if let groupKey = decoded.groupKey {
                self.selectedDeviceGroupKey = groupKey
            } else if let deviceId = decoded.deviceId, let device = self.devices[deviceId] {
                let groupKey = self.deviceGroupKey(for: device)
                self.preferredDeviceIdsByGroup[groupKey] = deviceId
                self.selectedDeviceGroupKey = groupKey
            } else if let legacyDevice = self.devices[id] {
                let groupKey = self.deviceGroupKey(for: legacyDevice)
                self.preferredDeviceIdsByGroup[groupKey] = legacyDevice.id
                self.selectedDeviceGroupKey = groupKey
            } else {
                self.selectedDeviceGroupKey = self.broadcastSelectionKey
            }
            
            if closeMenu {
                // If it was a deep action, maybe close now. 
                // But for the Wi-Fi experience, we might want to stay open 
                // until user clicks away or it's finished.
            }
        }
    }

    func forgetDevice(id: String) {
        print("🚨 App: Forgetting device [\(id)]")
        
        let decoded = decodeSelectionActionKey(id)
        let groupKey: String
        if let directGroupKey = decoded.groupKey {
            groupKey = directGroupKey
        } else if let deviceId = decoded.deviceId, let device = devices[deviceId] {
            groupKey = deviceGroupKey(for: device)
        } else if let legacyDevice = devices[id] {
            groupKey = deviceGroupKey(for: legacyDevice)
        } else {
            groupKey = id
        }
        
        // 1. Remove from history ONLY
        // We do NOT remove from 'devices' dictionary so it remains visible in "Other Devices"
        var currentHistory = historyDeviceGroupKeys
        currentHistory.remove(groupKey)
        historyDeviceGroupKeys = currentHistory
        preferredDeviceIdsByGroup.removeValue(forKey: groupKey)
        
        // 2. If it was selected, fallback to broadcast
        if selectedDeviceGroupKey == groupKey {
            selectedDeviceGroupKey = broadcastSelectionKey
        }
        
        // 3. Update UI
        updateMenu()
        saveDevices()
    }
    
    @MainActor
    @objc func quit() {
        discoveryService.stop()
        NSApplication.shared.terminate(self)
    }
    
    // MARK: - System Integration
    
    private func enableWakelock() {
        guard wakelockAssertionID == 0 else { return }
        let reason = "LocalSend is transferring files" as CFString
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                reason,
                                                &wakelockAssertionID)
        if result == kIOReturnSuccess {
            logTransfer("🔋 Wakelock enabled: Prevent system sleep during transfer.")
        } else {
            logTransfer("⚠️ Failed to enable Wakelock: \(result)")
        }
    }
    
    private func disableWakelock() {
        guard wakelockAssertionID != 0 else { return }
        let result = IOPMAssertionRelease(wakelockAssertionID)
        if result == kIOReturnSuccess {
            logTransfer("🔋 Wakelock disabled: System can now sleep.")
            wakelockAssertionID = 0
        } else {
            logTransfer("⚠️ Failed to disable Wakelock: \(result)")
        }
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            let service = SMAppService()
            do {
                if service.status == SMAppService.Status.enabled {
                    try service.unregister()
                    logTransfer("🚀 Launch at Login disabled.")
                } else {
                    try service.register()
                    logTransfer("🚀 Launch at Login enabled.")
                }
                updateMenu() // Refresh checkmark
            } catch {
                logTransfer("❌ Failed to toggle Launch at Login: \(error)")
            }
        }
    }
    
    // MARK: - Update Logic
    
    @objc func manualCheckUpdate() {
        print("🚨 App: Manual update check triggered.")
        UpdateService.shared.checkUpdate(explicit: true)
    }
    
    @objc func toggleAutoUpdate(_ sender: NSMenuItem) {
        isAutoUpdateEnabled.toggle()
        print("🚨 App: Auto-update toggled to [\(isAutoUpdateEnabled)]")
    }
}

// MARK: - UI Helpers

class RequestIndicatorView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    
    init(message: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        setupUI(message: message)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(message: String) {
        titleLabel.stringValue = message
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: 4, width: 240, height: 18)
        addSubview(titleLabel)
    }
}

// Execution Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
