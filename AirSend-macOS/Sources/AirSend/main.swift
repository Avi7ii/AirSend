// The Swift Programming Language
// https://docs.swift.org/swift-book

import Cocoa
import AirSendDragHandoff
import AirSendConsoleSupport
import AirSendDiscoverySupport
import AirSendRuntimeCore
import ServiceManagement
import IOKit.pwr_mgt
import Network
import UniformTypeIdentifiers

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, DropTargetViewDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    private let appStartedAt = Date()
    
    // Persistent Fingerprint
    // Persistent Fingerprint (Will be overwritten by real cert fingerprint)
    var fingerprint: String = UUID().uuidString
    
    lazy var discoveryService = UDPDiscoveryService(fingerprint: fingerprint, protocolType: preferredLocalProtocol)
    let runtimeEvents = RuntimeEventHub()
    lazy var transferCoordinator = TransferCoordinator(events: runtimeEvents)
    lazy var campusFallback = CampusFallbackCoordinator(
        fingerprint: fingerprint,
        transferCoordinator: transferCoordinator
    )
    let runtimeConfigurationStore = RuntimeConfigurationStore(
        fileURL: RuntimeConfigurationStore.defaultFileURL()
    )
    lazy var transferHistoryStore: TransferHistoryStore? = try? TransferHistoryStore(
        fileURL: TransferHistoryStore.defaultFileURL()
    )
    private var runtimeConfiguration = AirSendRuntimeConfiguration()
    private var hasBootstrappedRuntimePersistence = false
    private var runtimeEventTask: Task<Void, Never>?
    private var runtimeConfigurationSaveTask: Task<Void, Never>?
    private var runtimeTransfersByID: [UUID: TransferRecord] = [:]
    private var runtimeHistory: [TransferRecord] = []
    private var runtimeLogTail: [String] = []
    private var transferServerHealth = TransferServerHealthSnapshot(
        isListening: false,
        isHTTPS: false,
        activeSessionCount: 0,
        listenerState: "stopped"
    )
    private var isNetworkPathSatisfied = true
    private var lastDiagnosticsAt: Date?
    private var diagnosticsError: String?
    private var activePowerAssertionReasons: Set<String> = []
    lazy var transferServer = HTTPTransferServer(
        fingerprint: fingerprint,
        transferCoordinator: transferCoordinator
    )
    lazy var fileSender = FileSender(
        fingerprint: fingerprint,
        localProtocol: preferredLocalProtocol,
        campusFallback: campusFallback,
        transferCoordinator: transferCoordinator
    )
    lazy var clipboardSender = ClipboardSender(fileSender: fileSender)
    let clipboardService = ClipboardService()
    let screenshotWatcher = ScreenshotWatcher()
    
    // UI Components
    var dropZoneWindow: DropZoneWindow!
    private var hasStartedTransfer = false
    private var isMinimizedToMenu = false
    private var isRequestingInBackground = false
    private var currentTransferProgress: Double = 0
    private var currentTransferTarget: String = ""
    private var transferProgressMenuItem: NSMenuItem?
    private var runtimeTransferMenuViews: [UUID: RuntimeTransferMenuItemView] = [:]
    private var isStatusMenuOpen = false
    private var pendingStatusMenuRefresh = false
    private var settingsWindowController: AirSendSettingsWindowController?
    private var sharingServicePicker: NSSharingServicePicker?
    private var settingsWindowRelativeTimeTimer: Timer?
    private var recentConsoleActivities: [AirSendActivitySummary] = []
    private let maxRecentConsoleActivities = 5
    private let connectivityConsoleActivityTitles: Set<String> = [
        "Device reachable",
        "Device registered",
        "Device discovered",
        "Device updated",
    ]
    private var isQuitting = false
    
    // 🔋 功耗优化：广播与清理定时器（连接设备后停止）
    private var broadcastTimer: Timer?
    private var cleanupTimer: Timer?
    private var selectedTargetFreshnessTimer: Timer?
    private var selectedTargetRecoveryTimer: Timer?
    private var discoveryRefreshCompletionWorkItem: DispatchWorkItem?
    private var isDiscoveryRefreshing = false
    private var discoveryRefreshSummary = "Ready to refresh devices"
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathMonitorQueue = DispatchQueue(label: "com.airsend.network-path", qos: .utility)
    private var lastNetworkPathSignature: String?
    private var wakeObserver: NSObjectProtocol?
    private var hasStartedNetworkingStack = false
    private var isPublishingPreferredDiscoveryHosts = false
    private var isRestartingDiscovery = false
    private var manualPeerProbeTask: Task<Void, Never>?
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
        get { UpdateService.savedAutoUpdatePreference }
        set {
            UserDefaults.standard.set(newValue, forKey: UpdateService.autoUpdateDefaultsKey)
            UpdateService.shared.configureAutoUpdate(enabled: newValue)
            updateMenu()
        }
    }
    
    // Auto clipboard sync is disabled by default.
    private var isAutoClipboardSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "auto_clipboard_sync_enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "auto_clipboard_sync_enabled")
            if hasBootstrappedRuntimePersistence {
                runtimeConfiguration.clipboardSyncEnabled = newValue
                persistRuntimeConfiguration()
            }
            updateMenu()
        }
    }

    private let autoScreenshotSyncStorage = "auto_screenshot_sync_enabled_v1"
    private var isAutoScreenshotSyncEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: autoScreenshotSyncStorage) == nil {
                return isAutoClipboardSyncEnabled
            }
            return defaults.bool(forKey: autoScreenshotSyncStorage)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoScreenshotSyncStorage)
            if hasBootstrappedRuntimePersistence {
                runtimeConfiguration.clipboardImageSyncEnabled = newValue
                persistRuntimeConfiguration()
            }
            updateMenu()
        }
    }

    private var isScreenshotFileSyncEnabled: Bool {
        runtimeConfiguration.screenshotSyncEnabled
    }

    private var preferredLocalProtocol: ProtocolType {
        get {
            if let override = ProcessInfo.processInfo.environment["AIRSEND_LOCAL_PROTOCOL"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               let protocolType = ProtocolType(rawValue: override) {
                return protocolType
            }
            guard let rawValue = UserDefaults.standard.string(forKey: localProtocolPreferenceStorage),
                  let protocolType = ProtocolType(rawValue: rawValue) else {
                return .https
            }
            return protocolType
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: localProtocolPreferenceStorage)
            if hasBootstrappedRuntimePersistence {
                runtimeConfiguration.transportPreference = newValue == .http ? .httpCompatibility : .https
                persistRuntimeConfiguration()
            }
            updateMenu()
        }
    }
    
    private let broadcastSelectionKey = "broadcast"
    private let selectedGroupKeyStorage = "selected_device_group_key_v2"
    private let historyGroupKeysStorage = "history_device_group_keys_v2"
    private let preferredGroupCandidateStorage = "preferred_device_ids_by_group_v2"
    private let localProtocolPreferenceStorage = "local_protocol_preference_v2"
    private let knownDiscoveryHostsStorage = "known_discovery_hosts_v1"
    private let deviceConflictOnlineWindow: TimeInterval = 90.0
    private let deviceOnlineTimeout: TimeInterval = 75.0
    private let offlineDeviceTimeout: TimeInterval = 120.0
    private let selectedTargetRecoveryInterval: TimeInterval = 30.0
    private let maximumPreferredDiscoveryHosts = 12
    private let knownHostRetentionInterval: TimeInterval = 900.0
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
            publishPreferredDiscoveryHostsIfActive()
            updateDiscoveryTimers()
            refreshSettingsWindowIfNeeded()
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

    private var knownDiscoveryHosts: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: knownDiscoveryHostsStorage) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: knownDiscoveryHostsStorage)
            publishPreferredDiscoveryHostsIfActive()
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
            if hasBootstrappedRuntimePersistence {
                runtimeConfiguration.preferredTargetID = selectedDeviceGroupKey
                persistRuntimeConfiguration()
            }
            updateMenu()
            updateWindowStatus()
            updateDiscoveryTimers()
            refreshSettingsWindowIfNeeded()
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

    private func mergeKnownDiscoveryHosts(_ hosts: [String]) {
        var merged: [String] = []
        var seen = Set<String>()

        for host in hosts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !host.isEmpty {
            if seen.insert(host).inserted {
                merged.append(host)
            }
        }

        for host in knownDiscoveryHosts where seen.insert(host).inserted {
            merged.append(host)
        }

        if merged.count > 32 {
            merged = Array(merged.prefix(32))
        }

        knownDiscoveryHosts = merged
    }

    private func recordKnownDiscoveryHost(_ host: String) {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        mergeKnownDiscoveryHosts([normalized])
    }

    private func prioritizedDiscoveryHosts() -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        let selectedHosts = devices.values
            .filter { deviceGroupKey(for: $0) == selectedDeviceGroupKey }
            .sorted { $0.lastSeen > $1.lastSeen }
            .map(\.ip)
        let liveHosts = devices.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .map(\.ip)
        let gatewayHosts = LocalNetworkIdentity.defaultIPv4Gateway().map { [$0] } ?? []

        for host in selectedHosts + gatewayHosts + liveHosts + knownDiscoveryHosts {
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
            if ordered.count == maximumPreferredDiscoveryHosts {
                break
            }
        }

        return ordered
    }

    private func publishPreferredDiscoveryHostsIfActive() {
        guard isPublishingPreferredDiscoveryHosts else { return }
        discoveryService.updatePreferredProbeHosts(prioritizedDiscoveryHosts())
    }

    private func probePreferredDiscoveryHosts(
        trigger: PreferredHostProbeTrigger,
        reason: String
    ) {
        guard PreferredHostProbePolicy.shouldProbe(for: trigger) else { return }
        discoveryService.probePreferredHosts(reason: reason)
    }

    private func retentionInterval(for device: Device) -> TimeInterval {
        if isConfiguredManualDevice(device) {
            return .infinity
        }
        if preferredLocalProtocol == .http && knownDiscoveryHosts.contains(device.ip) {
            return knownHostRetentionInterval
        }
        return offlineDeviceTimeout
    }

    private func isConfiguredManualDevice(_ device: Device) -> Bool {
        runtimeConfiguration.manualPeers.contains { peer in
            let configured = manualDevice(for: peer)
            return configured.id == device.id || (configured.ip == device.ip && configured.port == device.port)
        }
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

    private func settingsDeviceTypeLabel(for device: Device) -> String {
        switch (device.deviceType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mobile":
            return "Phone"
        case "desktop":
            return "Computer"
        case "tablet":
            return "Tablet"
        case "server":
            return "Server"
        case "web":
            return "Web"
        case "headless":
            return "Headless"
        default:
            return "Device"
        }
    }

    private func settingsLastSeenLabel(for device: Device) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(device.lastSeen)))
        switch seconds {
        case ..<6:
            return "Live"
        case ..<60:
            return "\(seconds)s ago"
        default:
            return "\(seconds / 60)m ago"
        }
    }

    private func makeSettingsDeviceSummaries(from groups: [DeviceGroupViewModel]) -> [AirSendSettingsDeviceSummary] {
        groups.map { group in
            let primary = group.primary
            let model = isAndroidModuleDevice(primary)
                ? normalizedAndroidModuleModelName(primary.deviceModel)
                : ((primary.deviceModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            let version = primary.version.trimmingCharacters(in: .whitespacesAndNewlines)

            return AirSendSettingsDeviceSummary(
                id: group.key,
                title: displayTitle(for: group),
                model: model.isEmpty ? settingsDeviceTypeLabel(for: primary) : model,
                deviceType: settingsDeviceTypeLabel(for: primary),
                ipAddress: primary.ip,
                port: primary.port,
                protocolLabel: primary.https ? "HTTPS" : "HTTP",
                versionLabel: version,
                fingerprintSuffix: shortFingerprint(primary.id),
                statusLabel: settingsLastSeenLabel(for: primary),
                peerCount: group.candidates.count,
                isSelected: selectedDeviceGroupKey == group.key,
                isManual: group.candidates.contains(where: isConfiguredManualDevice),
                isOnline: isDeviceOnline(primary)
            )
        }
    }

    private func makeTrustedPeerSummaries(from groups: [DeviceGroupViewModel]) -> [AirSendTrustedPeerSummary] {
        runtimeConfiguration.trustedPeerFingerprints.map { trustedFingerprint in
            let matchedGroup = groups.first { group in
                group.candidates.contains {
                    DiscoveryIdentity.fingerprintsMatch($0.id, trustedFingerprint)
                }
            }
            let matchedDevice = matchedGroup?.candidates.first {
                DiscoveryIdentity.fingerprintsMatch($0.id, trustedFingerprint)
            }
            return AirSendTrustedPeerSummary(
                id: trustedFingerprint,
                title: matchedGroup.map { displayTitle(for: $0) } ?? "Unknown device",
                fingerprintSuffix: shortFingerprint(trustedFingerprint),
                isOnline: matchedDevice.map { isDeviceOnline($0) } ?? false
            )
        }
        .sorted {
            if $0.isOnline != $1.isOnline {
                return $0.isOnline && !$1.isOnline
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func transferSummary(_ record: TransferRecord) -> AirSendTransferSummary {
        let fileTitle: String
        if record.files.count == 1 {
            fileTitle = record.files[0].name
        } else {
            fileTitle = "\(record.files.count) items"
        }
        let transferred = ByteCountFormatter.string(fromByteCount: record.transferredBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file)
        return AirSendTransferSummary(
            id: record.id.uuidString,
            direction: record.direction.rawValue,
            source: record.source.rawValue,
            peerTitle: record.peer.alias,
            fileTitle: fileTitle,
            detail: record.files.prefix(3).map(\.name).joined(separator: ", "),
            status: record.status.rawValue,
            progress: record.progress,
            byteProgress: "\(transferred) of \(total)",
            startedAt: record.startedAt,
            savedPaths: record.files.compactMap(\.savedPath),
            previewPath: record.files.compactMap(\.previewPath).first,
            previewText: record.previewText,
            failureMessage: record.failure?.message,
            canCancel: !record.status.isTerminal,
            canRetry: record.isRetryable,
            hasAvailableFiles: record.files.contains {
                [$0.savedPath, $0.sourcePath].compactMap { $0 }.contains {
                    FileManager.default.fileExists(atPath: $0)
                }
            }
        )
    }

    private func makeDiagnosticSummaries() -> [AirSendDiagnosticSummary] {
        let downloadReady = FileManager.default.isWritableFile(atPath: configuredDownloadDirectory.path)
        let mediaReady = FileManager.default.isWritableFile(atPath: configuredMediaDirectory.path)
        let automationRunning = clipboardService.isRunning || isScreenshotFileSyncEnabled
        let screenshotStatus: (String, AirSendConsoleHealthTone)
        switch screenshotWatcher.state {
        case .stopped:
            screenshotStatus = (isScreenshotFileSyncEnabled ? "Unavailable" : "Off", isScreenshotFileSyncEnabled ? .warning : .neutral)
        case .watching:
            screenshotStatus = ("Watching", .good)
        case .failed:
            screenshotStatus = ("Unavailable", .warning)
        }

        return [
            AirSendDiagnosticSummary(
                id: "network",
                title: "Network path",
                value: isNetworkPathSatisfied ? "Available" : "Unavailable",
                detail: lastNetworkPathSignature,
                symbolName: isNetworkPathSatisfied ? "network" : "wifi.exclamationmark",
                tone: isNetworkPathSatisfied ? .good : .warning
            ),
            AirSendDiagnosticSummary(
                id: "receiver",
                title: "Receiver",
                value: transferServerHealth.isListening ? "Listening" : "Stopped",
                detail: "\(transferServerHealth.isHTTPS ? "HTTPS" : "HTTP") · \(transferServerHealth.listenerState)",
                symbolName: "antenna.radiowaves.left.and.right",
                tone: transferServerHealth.isListening ? .good : .warning
            ),
            AirSendDiagnosticSummary(
                id: "tls",
                title: "TLS identity",
                value: transferServerHealth.isHTTPS && !fingerprint.isEmpty ? "Ready" : (preferredLocalProtocol == .http ? "Compatibility mode" : "Unavailable"),
                detail: shortFingerprint(fingerprint),
                symbolName: "checkmark.shield",
                tone: transferServerHealth.isHTTPS && !fingerprint.isEmpty ? .good : (preferredLocalProtocol == .http ? .neutral : .warning)
            ),
            AirSendDiagnosticSummary(
                id: "storage",
                title: "Storage",
                value: downloadReady && mediaReady ? "Writable" : "Needs attention",
                detail: "Downloads and media destinations",
                symbolName: "externaldrive",
                tone: downloadReady && mediaReady ? .good : .warning
            ),
            AirSendDiagnosticSummary(
                id: "automation",
                title: "Automation",
                value: automationRunning ? "Active" : "Idle",
                detail: "Clipboard \(clipboardService.isRunning ? "on" : "off") · Screenshots \(screenshotStatus.0.lowercased())",
                symbolName: "bolt.horizontal.circle",
                tone: screenshotStatus.1
            ),
            AirSendDiagnosticSummary(
                id: "runtime",
                title: "Runtime",
                value: "Protocol v\(AirSendRuntimeCapabilities.protocolVersion) · Config v\(airSendConfigurationVersion) · History v\(TransferHistoryStore.schemaVersion)",
                detail: "Ports \(NetworkPorts.discoveryPort) / \(NetworkPorts.transferPort) · up \(AirSendRelativeTimeFormatter.label(since: appStartedAt))",
                symbolName: "memorychip",
                tone: .good
            ),
            AirSendDiagnosticSummary(
                id: "capabilities",
                title: "Capabilities",
                value: "\(AirSendRuntimeCapabilities.current.count) available",
                detail: AirSendRuntimeCapabilities.current.sorted().joined(separator: ", "),
                symbolName: "checklist.checked",
                tone: .good
            ),
        ]
    }

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
            createdAt: Date(),
            symbolName: symbolName,
            tone: tone
        )
        if connectivityConsoleActivityTitles.contains(title),
           let existingIndex = recentConsoleActivities.firstIndex(where: {
               connectivityConsoleActivityTitles.contains($0.title) && $0.detail == detail
           }) {
            recentConsoleActivities.remove(at: existingIndex)
        }
        recentConsoleActivities.insert(item, at: 0)
        if recentConsoleActivities.count > maxRecentConsoleActivities {
            recentConsoleActivities.removeLast(recentConsoleActivities.count - maxRecentConsoleActivities)
        }
        refreshSettingsWindowIfNeeded()
        scheduleNextSettingsWindowRelativeTimeRefresh()
    }

    private func consoleHealth(for visibleCount: Int) -> (title: String, detail: String, tone: AirSendConsoleHealthTone) {
        let state = AirSendLiveConnectionHealthPolicy.evaluate(
            networkAvailable: isNetworkPathSatisfied,
            receiverReady: transferServerHealth.isListening,
            activeTransferCount: runtimeTransfersByID.values.filter { !$0.status.isTerminal }.count,
            visibleDeviceCount: visibleCount
        )

        switch state {
        case .networkUnavailable:
            return ("Network unavailable", "Waiting for a usable network path", .warning)
        case .receiverStopped:
            return ("Receiver stopped", transferServerHealth.listenerState, .warning)
        case let .transferring(activeCount):
            return ("Transferring", "\(activeCount) active transfer\(activeCount == 1 ? "" : "s")", .good)
        case let .ready(visibleDeviceCount):
            if visibleDeviceCount > 0 {
                return ("Ready", "\(visibleDeviceCount) device\(visibleDeviceCount == 1 ? "" : "s") visible", .good)
            }
            return ("Ready", "Waiting for devices", .good)
        }
    }

    private var consolePreflightSummary: String {
        let mode = transferServerHealth.isHTTPS ? "HTTPS" : "HTTP compatibility"
        guard let lastDiagnosticsAt else { return "\(mode) · live state pending" }
        return "\(mode) · checked \(AirSendRelativeTimeFormatter.label(since: lastDiagnosticsAt))"
    }

    private func makeSettingsSnapshot() -> AirSendSettingsSnapshot {
        let groups = buildDeviceGroups()
        let visibleGroupCount = groups.filter { group in
            group.candidates.contains { isDeviceOnline($0) }
        }.count
        let selectedGroup = groups.first(where: { $0.key == selectedDeviceGroupKey })
        let selectedTitle: String
        let selectedSubtitle: String

        if selectedDeviceGroupKey == broadcastSelectionKey {
            selectedTitle = "All Devices"
            selectedSubtitle = "Broadcast to every online device"
        } else if let selectedGroup {
            selectedTitle = displayTitle(for: selectedGroup)
            selectedSubtitle = displaySubtitle(for: selectedGroup)
        } else {
            selectedTitle = "Target Offline"
            selectedSubtitle = "Choose another device or rescan"
        }
        let health = consoleHealth(for: visibleGroupCount)
        let activeRecords = runtimeTransfersByID.values
            .filter { !$0.status.isTerminal }
            .sorted { $0.startedAt > $1.startedAt }
            .map(transferSummary)
        let sentHistory = runtimeHistory.filter { $0.direction == .outgoing }.map(transferSummary)
        let receivedHistory = runtimeHistory.filter { $0.direction == .incoming }.map(transferSummary)
        let screenshotStatus: String
        switch screenshotWatcher.state {
        case .stopped: screenshotStatus = "Off"
        case .watching: screenshotStatus = "Watching"
        case let .failed(message): screenshotStatus = message
        }

        return AirSendSettingsSnapshot(
            autoClipboardSyncEnabled: isAutoClipboardSyncEnabled,
            autoClipboardImageSyncEnabled: isAutoScreenshotSyncEnabled,
            autoScreenshotFileSyncEnabled: isScreenshotFileSyncEnabled,
            autoUpdateEnabled: isAutoUpdateEnabled,
            launchAtLoginEnabled: isLaunchAtLoginEnabled,
            compatibilityModeEnabled: preferredLocalProtocol == .http,
            discoveredDeviceCount: visibleGroupCount,
            rememberedDeviceCount: historyDeviceGroupKeys.count,
            isDiscoveryRefreshing: isDiscoveryRefreshing,
            discoveryRefreshSummary: discoveryRefreshSummary,
            selectedTargetTitle: selectedTitle,
            selectedTargetSubtitle: selectedSubtitle,
            selectedTargetIsBroadcast: selectedDeviceGroupKey == broadcastSelectionKey,
            protocolLabel: preferredLocalProtocol == .http ? "HTTP Compatibility" : "HTTPS Default",
            fingerprintSuffix: shortFingerprint(fingerprint),
            currentVersion: UpdateService.shared.currentVersion,
            nearbyDevices: makeSettingsDeviceSummaries(from: groups),
            healthTitle: health.title,
            healthDetail: health.detail,
            healthTone: health.tone,
            preflightSummary: consolePreflightSummary,
            recentActivities: recentConsoleActivities,
            activeTransfers: activeRecords,
            sentHistory: sentHistory,
            receivedHistory: receivedHistory,
            receivePolicy: runtimeConfiguration.receivePolicy.rawValue,
            downloadDestination: configuredDownloadDirectory.path,
            mediaDestination: configuredMediaDirectory.path,
            screenshotWatchFolder: ScreenshotWatcher.defaultCaptureDirectory().path,
            screenshotWatcherStatus: screenshotStatus,
            historyLimitPerDirection: runtimeConfiguration.historyLimitPerDirection,
            manualPeers: runtimeConfiguration.manualPeers.map {
                AirSendManualPeerSummary(
                    id: $0.id,
                    alias: $0.alias,
                    endpoint: "\($0.address):\($0.port)",
                    fingerprintSuffix: $0.fingerprint.map(shortFingerprint)
                )
            },
            trustedPeers: makeTrustedPeerSummaries(from: groups),
            diagnostics: makeDiagnosticSummaries(),
            diagnosticsUpdatedAt: lastDiagnosticsAt,
            logTail: runtimeLogTail
        )
    }

    private func ensureSettingsWindowController() -> AirSendSettingsWindowController {
        if let settingsWindowController {
            settingsWindowController.store.update(snapshot: makeSettingsSnapshot())
            return settingsWindowController
        }

        let store = AirSendSettingsStore(
            snapshot: makeSettingsSnapshot(),
            actions: .init(
                setAutoClipboardSyncEnabled: { [weak self] enabled in
                    self?.setAutoClipboardSyncEnabled(enabled, showInfoIfEnabling: true)
                },
                setAutoClipboardImageSyncEnabled: { [weak self] enabled in
                    self?.setAutoScreenshotSyncEnabled(enabled, showInfoIfEnabling: true)
                },
                setAutoScreenshotFileSyncEnabled: { [weak self] enabled in
                    self?.setScreenshotFileSyncEnabled(enabled)
                },
                setAutoUpdateEnabled: { [weak self] enabled in
                    self?.setAutoUpdateEnabled(enabled)
                },
                setLaunchAtLoginEnabled: { [weak self] enabled in
                    self?.setLaunchAtLoginEnabled(enabled)
                },
                setCompatibilityModeEnabled: { [weak self] enabled in
                    self?.setCompatibilityModeEnabled(enabled)
                },
                sendClipboardNow: { [weak self] in
                    self?.sendClipboard()
                },
                chooseFilesToSend: { [weak self] in
                    self?.chooseFilesToSend()
                },
                rescan: { [weak self] in
                    self?.performManualRescan(reopenMenu: false)
                },
                addDeviceByIP: { [weak self] in
                    self?.addDeviceByIP()
                },
                clearDiscoveredDevices: { [weak self] in
                    self?.clearDeviceHistory()
                },
                resetIdentity: { [weak self] in
                    self?.resetIdentity(nil)
                },
                checkForUpdates: { [weak self] in
                    self?.manualCheckUpdate()
                },
                selectBroadcastTarget: { [weak self] in
                    self?.selectedDeviceGroupKey = self?.broadcastSelectionKey ?? "broadcast"
                },
                selectDeviceTarget: { [weak self] groupKey in
                    self?.selectedDeviceGroupKey = groupKey
                },
                openAndroidRepository: { [weak self] in
                    self?.openAndroidRepository()
                },
                runDiagnostics: { [weak self] in
                    self?.runDiagnosticsFromConsole()
                },
                setReceivePolicy: { [weak self] policy in
                    self?.setReceivePolicy(policy)
                },
                setHistoryLimitPerDirection: { [weak self] limit in
                    self?.setHistoryLimitPerDirection(limit)
                },
                trustKnownDevice: { [weak self] in
                    self?.showTrustDeviceDialog()
                },
                revokeTrustedPeer: { [weak self] fingerprint in
                    self?.revokeTrustedFingerprint(fingerprint)
                },
                removeManualPeer: { [weak self] id in
                    self?.removeManualPeer(id: id)
                },
                selectDownloadDestination: { [weak self] in
                    self?.selectDestination(kind: .downloads)
                },
                selectMediaDestination: { [weak self] in
                    self?.selectDestination(kind: .media)
                },
                cancelTransfer: { [weak self] id in
                    self?.cancelTransfer(id: id)
                },
                retryTransfer: { [weak self] id in
                    self?.retryTransfer(id: id)
                },
                deleteHistory: { [weak self] id in
                    self?.deleteHistory(id: id)
                },
                clearHistory: { [weak self] direction in
                    self?.clearHistory(direction: direction)
                },
                revealTransfer: { [weak self] id in
                    self?.revealTransfer(id: id)
                },
                shareTransfer: { [weak self] id in
                    self?.shareTransfer(id: id)
                },
                exportLogs: { [weak self] in
                    self?.exportLogs()
                },
                clearLogs: { [weak self] in
                    self?.clearLogs()
                },
                restartRuntime: { [weak self] in
                    self?.restartRuntimeFromConsole()
                }
            )
        )
        let controller = AirSendSettingsWindowController(store: store)
        controller.onWindowVisibilityChanged = { [weak self] isVisible in
            self?.setDockIconVisibleForSettingsWindow(isVisible)
            self?.updateSettingsWindowRelativeTimeTimer(isVisible: isVisible)
        }
        settingsWindowController = controller
        return controller
    }

    private func setDockIconVisibleForSettingsWindow(_ isVisible: Bool) {
        NSApp.setActivationPolicy(isVisible ? .regular : .accessory)
    }

    private func updateSettingsWindowRelativeTimeTimer(isVisible: Bool) {
        settingsWindowRelativeTimeTimer?.invalidate()
        settingsWindowRelativeTimeTimer = nil

        guard isVisible else { return }

        refreshSettingsWindowIfNeeded()
        scheduleNextSettingsWindowRelativeTimeRefresh()
    }

    private func scheduleNextSettingsWindowRelativeTimeRefresh(now: Date = Date()) {
        settingsWindowRelativeTimeTimer?.invalidate()
        settingsWindowRelativeTimeTimer = nil

        guard settingsWindowController?.window?.isVisible == true,
              let nextRefreshDate = AirSendRelativeTimeFormatter.nextLabelChangeDate(
                for: recentConsoleActivities.map(\.createdAt)
                    + runtimeTransfersByID.values.map(\.startedAt)
                    + runtimeHistory.map(\.startedAt),
                now: now
              ) else {
            return
        }

        let interval = max(1, nextRefreshDate.timeIntervalSince(now))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSettingsWindowIfNeeded()
                self?.scheduleNextSettingsWindowRelativeTimeRefresh()
            }
        }
        timer.tolerance = min(3, interval * 0.2)
        settingsWindowRelativeTimeTimer = timer
    }

    private func refreshSettingsWindowIfNeeded() {
        settingsWindowController?.store.update(snapshot: makeSettingsSnapshot())
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
        let remoteDevices = devices.values.filter {
            !DiscoveryIdentity.fingerprintsMatch($0.id, fingerprint)
        }
        let grouped = Dictionary(grouping: remoteDevices, by: { deviceGroupKey(for: $0) })
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

    private func isDeviceOnline(_ device: Device, now: Date = Date()) -> Bool {
        now.timeIntervalSince(device.lastSeen) <= deviceOnlineTimeout
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
        let groups = buildDeviceGroups().filter { group in
            group.candidates.contains { isDeviceOnline($0) }
        }
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

    private func refreshStatusItemActivityIndicator() {
        let hasActiveTransfer = runtimeTransfersByID.values.contains { !$0.status.isTerminal }
        updateStatusItemIcon(showDot: isRequestingInBackground || hasActiveTransfer)
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
            mergeKnownDiscoveryHosts(cleanedDevices.values.map(\.ip))
        }
    }

    private func removeLocalDeviceFromDiscoveryState(matching localFingerprint: String) {
        let matchingEntries = devices.filter { key, device in
            DiscoveryIdentity.fingerprintsMatch(key, localFingerprint)
                || DiscoveryIdentity.fingerprintsMatch(device.id, localFingerprint)
        }
        guard !matchingEntries.isEmpty else { return }

        let removedIds = Set(matchingEntries.keys)
        let removedGroupKeys = Set(matchingEntries.values.map(deviceGroupKey(for:)))
        for id in removedIds {
            devices.removeValue(forKey: id)
        }

        let remainingGroupKeys = Set(devices.values.map(deviceGroupKey(for:)))
        let orphanedGroupKeys = removedGroupKeys.subtracting(remainingGroupKeys)
        if !orphanedGroupKeys.isEmpty {
            historyDeviceGroupKeys.subtract(orphanedGroupKeys)
            for groupKey in orphanedGroupKeys {
                preferredDeviceIdsByGroup.removeValue(forKey: groupKey)
            }
            if orphanedGroupKeys.contains(selectedDeviceGroupKey) {
                selectedDeviceGroupKey = broadcastSelectionKey
            }
        }

        dropStalePreferredDeviceIds()
        saveDevices()
        updateMenu()
        updateWindowStatus()
        logTransfer("🧹 Discovery: Removed cached local device identity")
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
        UserDefaults.standard.removeObject(forKey: knownDiscoveryHostsStorage)

        materializeManualPeers()
        
        updateMenu()
        updateWindowStatus()
    }

    // Drag Handoff
    private var globalDragEventMonitor: Any?
    private var localDragEventMonitor: Any?
    private var dragEvaluationWorkItem: DispatchWorkItem?
    private var lastDragEvaluationUptime: TimeInterval = 0
    private var dragReleaseMonitorTimer: Timer?
    private var dragReleaseRecoveryWorkItem: DispatchWorkItem?
    private var dragPreviewExitWorkItem: DispatchWorkItem?
    private var pendingDragPayloadURLs: [URL] = []
    private var activeDragSessionID: UUID?
    private var resolvedDragSessionID: UUID?
    private var dragGestureRejected = false
    private var dragActivationPolicy = DragActivationPolicy()
    private var currentDragAllowsFallbackRecovery = false
    private var dragPreviewActivationPoint: NSPoint?
    private var hasEnteredCompactDropTarget = false
    private var dragStartQuartzLocation: CGPoint?
    private var initialDragWindowFrames: [CGWindowID: CGRect] = [:]
    private var hasCapturedInitialDragWindowFrames = false
    private let dragEvaluationInterval: TimeInterval = 0.05
    private let dragActivationBandHeight: CGFloat = 132
    private let dragActivationLeftReach: CGFloat = 250
    private let dragActivationFallbackWidth: CGFloat = 320
    private let dragCompactKeepaliveInset: CGFloat = 14
    private let dragTransitionCorridorRadius: CGFloat = 42
    private let dragPreviewExitDelay: TimeInterval = 0.22
    private let dragReleasePollInterval: TimeInterval = 0.05
    private let dragReleaseGraceDelay: TimeInterval = 0.18
    private let dragReleaseFallbackInset: CGFloat = 14

    private func filterValidLocalDropURLs(_ urls: [URL]) -> [URL] {
        LocalFileDrag.filterExistingLocalFileURLs(urls)
    }

    private func startDragProximityMonitoring() {
        guard globalDragEventMonitor == nil, localDragEventMonitor == nil else { return }

        globalDragEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleObservedDragEvent(event, isLocal: false)
            }
        }

        localDragEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleObservedDragEvent(event, isLocal: true)
            }
            return event
        }
    }

    private func stopDragProximityMonitoring() {
        dragEvaluationWorkItem?.cancel()
        dragEvaluationWorkItem = nil
        dragPreviewExitWorkItem?.cancel()
        dragPreviewExitWorkItem = nil
        if let globalDragEventMonitor {
            NSEvent.removeMonitor(globalDragEventMonitor)
            self.globalDragEventMonitor = nil
        }
        if let localDragEventMonitor {
            NSEvent.removeMonitor(localDragEventMonitor)
            self.localDragEventMonitor = nil
        }
    }

    private func handleObservedDragEvent(_ event: NSEvent, isLocal: Bool) {
        switch event.type {
        case .leftMouseDown:
            guard activeDragSessionID == nil else { return }
            resetObservedDragGesture(startingAt: NSEvent.mouseLocation)
            dragGestureRejected = isLocal && isAirSendOwnedWindow(event.window)
        case .leftMouseDragged:
            beginObservedDragGestureIfNeeded(at: NSEvent.mouseLocation)
            if activeDragSessionID == nil, isLocal, isAirSendOwnedWindow(event.window) {
                dragGestureRejected = true
            }
            requestDragEvaluation()
        case .leftMouseUp:
            dragEvaluationWorkItem?.cancel()
            dragEvaluationWorkItem = nil
            handleDragReleaseIfNeeded(trigger: isLocal ? "local-mouse-up" : "global-mouse-up")
            resetObservedDragGesture()
        default:
            break
        }
    }

    private func isAirSendOwnedWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return NSApp.windows.contains { $0 === window }
    }

    private func beginObservedDragGestureIfNeeded(at point: NSPoint) {
        guard dragStartQuartzLocation == nil else { return }
        dragStartQuartzLocation = currentQuartzPointerLocation(fallback: point)
        dragActivationPolicy.reset()
    }

    private func resetObservedDragGesture(startingAt point: NSPoint? = nil) {
        dragGestureRejected = false
        dragActivationPolicy.reset()
        dragStartQuartzLocation = point.map { currentQuartzPointerLocation(fallback: $0) }
        initialDragWindowFrames = [:]
        hasCapturedInitialDragWindowFrames = false
    }

    private func currentQuartzPointerLocation(fallback point: NSPoint) -> CGPoint {
        if let location = CGEvent(source: nil)?.location {
            return location
        }
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: primaryScreenTop - point.y)
    }

    private func captureInitialDragWindowFramesIfNeeded() {
        guard !hasCapturedInitialDragWindowFrames else { return }
        initialDragWindowFrames = visibleTopLevelWindowFrames()
        hasCapturedInitialDragWindowFrames = true
    }

    private func visibleTopLevelWindowFrames() -> [CGWindowID: CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var frames: [CGWindowID: CGRect] = [:]
        for entry in windowInfo {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let windowNumber = entry[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 120,
                  bounds.height >= 80 else {
                continue
            }
            frames[CGWindowID(windowNumber.uint32Value)] = bounds
        }
        return frames
    }

    private func currentGestureMovedWindow() -> Bool {
        guard hasCapturedInitialDragWindowFrames,
              let dragStartQuartzLocation,
              !initialDragWindowFrames.isEmpty else {
            return false
        }
        return WindowDragEvidence.hasMovedWindowFromDragStart(
            initialFrames: initialDragWindowFrames,
            currentFrames: visibleTopLevelWindowFrames(),
            dragStartPointerLocation: dragStartQuartzLocation,
            minimumOriginTravel: 4
        )
    }

    private func requestDragEvaluation() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastDragEvaluationUptime
        if elapsed >= dragEvaluationInterval {
            dragEvaluationWorkItem?.cancel()
            dragEvaluationWorkItem = nil
            lastDragEvaluationUptime = now
            checkForNearbyFileDragTrigger()
            return
        }
        guard dragEvaluationWorkItem == nil else { return }
        let delay = dragEvaluationInterval - elapsed
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dragEvaluationWorkItem = nil
                self.lastDragEvaluationUptime = ProcessInfo.processInfo.systemUptime
                self.checkForNearbyFileDragTrigger()
            }
        }
        dragEvaluationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func isReasonableStatusAnchorFrame(_ frame: NSRect, within screenFrame: NSRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        guard frame.intersects(screenFrame.insetBy(dx: -80, dy: -80)) else { return false }
        let topBandHeight = max(96.0, NSStatusBar.system.thickness * 3)
        return frame.maxY >= screenFrame.maxY - topBandHeight
    }

    private func fallbackStatusActivationBaseFrame(screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        let statusHeight = max(NSStatusBar.system.thickness + 6, 28)
        let width = min(dragActivationFallbackWidth, max(22, visibleFrame.width))
        let centeredX = visibleFrame.midX - (width / 2)
        let minX = max(screenFrame.minX, min(centeredX, screenFrame.maxX - width))
        return NSRect(
            x: minX,
            y: screenFrame.maxY - statusHeight,
            width: width,
            height: statusHeight
        )
    }

    private func statusBarActivationFrame() -> NSRect? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screenFrame = screen?.frame ?? .zero
        let visibleFrame = screen?.visibleFrame ?? screenFrame

        let baseFrame: NSRect
        if let button = statusItem.button, let window = button.window {
            let frameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrame = window.convertToScreen(frameInWindow)
            let statusWindowFrame = window.frame

            if isReasonableStatusAnchorFrame(buttonFrame, within: screenFrame) {
                baseFrame = buttonFrame
            } else if isReasonableStatusAnchorFrame(statusWindowFrame, within: screenFrame) {
                baseFrame = statusWindowFrame
            } else {
                baseFrame = fallbackStatusActivationBaseFrame(screenFrame: screenFrame, visibleFrame: visibleFrame)
            }
        } else {
            baseFrame = fallbackStatusActivationBaseFrame(screenFrame: screenFrame, visibleFrame: visibleFrame)
        }

        let activationMinX = max(screenFrame.minX, baseFrame.minX - dragActivationLeftReach)
        return NSRect(
            x: activationMinX,
            y: screenFrame.maxY - dragActivationBandHeight,
            width: screenFrame.maxX - activationMinX,
            height: dragActivationBandHeight
        )
    }

    private func checkForNearbyFileDragTrigger() {
        let dragPasteboard = NSPasteboard(name: .drag)
        guard (NSEvent.pressedMouseButtons & 0x1) != 0 else {
            resetObservedDragGesture()
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        beginObservedDragGestureIfNeeded(at: mouseLocation)

        if dropZoneWindow.isPreviewActive || activeDragSessionID != nil || !pendingDragPayloadURLs.isEmpty {
            guard !dropZoneWindow.isPerformingDrop,
                  !dropZoneWindow.isShowingSuccess,
                  !dropZoneWindow.isShowingError else { return }

            if pendingDragPayloadURLs.isEmpty,
               LocalFileDrag.metadataEvidence(from: dragPasteboard).canBeLocalFileDrag {
                let urls = LocalFileDrag.stageValidLocalFileURLs(from: dragPasteboard)
                if !urls.isEmpty {
                    pendingDragPayloadURLs = urls
                    currentDragAllowsFallbackRecovery = true
                }
            }

            if shouldKeepDragPreviewVisible(at: mouseLocation) {
                cancelScheduledDragPreviewExit()
            } else {
                scheduleDragPreviewExit()
            }
            return
        }

        guard !dragGestureRejected else { return }
        let metadata = LocalFileDrag.metadataEvidence(from: dragPasteboard)
        guard metadata.canBeLocalFileDrag else { return }
        captureInitialDragWindowFramesIfNeeded()

        guard let triggerFrame = statusBarActivationFrame() else { return }
        let isWithinActivationBand = triggerFrame.contains(mouseLocation)
        guard isWithinActivationBand else { return }

        let inspection = LocalFileDrag.inspectLocalFileDrag(from: dragPasteboard)
        let urls = inspection.looksLikeStrictLocalFileDrag ? inspection.urls : []
        guard !urls.isEmpty else { return }

        if currentGestureMovedWindow() {
            dragGestureRejected = true
            FileLogger.log("🪟 [DragProximity] Rejected moving-window gesture with stale file pasteboard evidence.")
            return
        }

        let activationDecision = dragActivationPolicy.decision(
            changeCount: dragPasteboard.changeCount,
            location: CGPoint(x: mouseLocation.x, y: mouseLocation.y),
            hasRecognizedPayload: true,
            isWithinActivationBand: isWithinActivationBand
        )

        guard activationDecision.shouldActivate else { return }

        FileLogger.log("🧲 [DragProximity] Status-bar activation band triggered with \(urls.count) verified file(s). triggerFrame=\(triggerFrame.debugDescription)")
        beginDropZonePreview(with: urls, allowFallbackRecovery: activationDecision.allowsFallbackRecovery)
    }

    private func shouldKeepDragPreviewVisible(at point: NSPoint) -> Bool {
        let compactFrame = dropZoneWindow.dragVisibleContentFrame(inset: dragCompactKeepaliveInset)
        let isWithinCompactKeepalive = compactFrame.contains(point)
        if isWithinCompactKeepalive {
            hasEnteredCompactDropTarget = true
        }

        let isWithinTransitionCorridor: Bool
        if !hasEnteredCompactDropTarget, let dragPreviewActivationPoint {
            isWithinTransitionCorridor = DragTransitionCorridor.contains(
                CGPoint(x: point.x, y: point.y),
                from: CGPoint(x: dragPreviewActivationPoint.x, y: dragPreviewActivationPoint.y),
                to: compactFrame,
                corridorRadius: dragTransitionCorridorRadius,
                targetInset: 0
            )
        } else {
            isWithinTransitionCorridor = false
        }

        return DragPreviewVisibilityPolicy.shouldKeepPreviewVisible(
            isWithinTransitionCorridor: isWithinTransitionCorridor,
            isWithinCompactKeepalive: isWithinCompactKeepalive,
            hasEnteredCompactDropTarget: hasEnteredCompactDropTarget,
            isAcceptingDragSession: dropZoneWindow.isAcceptingDragSession,
            isHoveringDropTarget: dropZoneWindow.isHoveringDropTarget
        )
    }

    private func cancelScheduledDragPreviewExit() {
        dragPreviewExitWorkItem?.cancel()
        dragPreviewExitWorkItem = nil
    }

    private func scheduleDragPreviewExit() {
        guard dragPreviewExitWorkItem == nil else { return }
        let sessionID = activeDragSessionID
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.dragPreviewExitWorkItem = nil
                guard self.activeDragSessionID == sessionID,
                      !self.dropZoneWindow.isPerformingDrop,
                      !self.dropZoneWindow.isShowingSuccess,
                      !self.dropZoneWindow.isShowingError,
                      !self.shouldKeepDragPreviewVisible(at: NSEvent.mouseLocation) else {
                    return
                }

                FileLogger.log("🧭 [DragProximity] Drag left the compact handoff corridor; dismissing preview after \(Int(self.dragPreviewExitDelay * 1_000))ms.")
                self.clearTransientDragState()
                self.dropZoneWindow.hide()
            }
        }
        dragPreviewExitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + dragPreviewExitDelay, execute: workItem)
    }

    private func startDragReleaseMonitoring() {
        guard dragReleaseMonitorTimer == nil else { return }
        let timer = Timer(timeInterval: dragReleasePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleDragReleaseIfNeeded(trigger: "poll")
            }
        }
        timer.tolerance = dragReleasePollInterval * 0.5
        RunLoop.main.add(timer, forMode: .common)
        dragReleaseMonitorTimer = timer
    }

    private func stopDragReleaseMonitoring() {
        dragReleaseMonitorTimer?.invalidate()
        dragReleaseMonitorTimer = nil
    }

    private func beginDragSession(with urls: [URL]) {
        activeDragSessionID = UUID()
        resolvedDragSessionID = nil
        pendingDragPayloadURLs = urls
        currentDragAllowsFallbackRecovery = false
        hasEnteredCompactDropTarget = false
        cancelScheduledDragPreviewExit()
        dragReleaseRecoveryWorkItem?.cancel()
        dragReleaseRecoveryWorkItem = nil
    }

    private func markCurrentDragSessionResolved(trigger: String) -> Bool {
        guard let activeDragSessionID else {
            FileLogger.log("ℹ️ [DragSession] Resolving drop via \(trigger) without an active session ID.")
            dragReleaseRecoveryWorkItem?.cancel()
            dragReleaseRecoveryWorkItem = nil
            return true
        }

        guard resolvedDragSessionID != activeDragSessionID else {
            FileLogger.log("🛑 [DragSession] Ignoring duplicate drop resolution via \(trigger).")
            return false
        }

        resolvedDragSessionID = activeDragSessionID
        dragReleaseRecoveryWorkItem?.cancel()
        dragReleaseRecoveryWorkItem = nil
        return true
    }

    private func handleDragReleaseIfNeeded(trigger: String) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let hasDragWork = activeDragSessionID != nil
            || !pendingDragPayloadURLs.isEmpty
            || dragReleaseMonitorTimer != nil
            || dropZoneWindow.isPreviewActive
            || dropZoneWindow.isAcceptingDragSession
            || dropZoneWindow.isHoveringDropTarget
        guard hasDragWork else { return }
        stopDragReleaseMonitoring()

        if let activeDragSessionID, resolvedDragSessionID == activeDragSessionID {
            return
        }

        guard !dropZoneWindow.isPerformingDrop,
              !dropZoneWindow.isShowingSuccess,
              !dropZoneWindow.isShowingError else {
            return
        }

        let releasePoint = NSEvent.mouseLocation
        let fallbackFrame = dropZoneWindow.dragVisibleContentFrame(inset: dragReleaseFallbackInset)
        let wasHoveringDropTarget = dropZoneWindow.isAcceptingDragSession || dropZoneWindow.isHoveringDropTarget
        guard !pendingDragPayloadURLs.isEmpty,
              currentDragAllowsFallbackRecovery,
              fallbackFrame.contains(releasePoint) || wasHoveringDropTarget else {
            FileLogger.log("🧭 [DragRelease] Mouse up outside drop fallback zone via \(trigger). Dismissing preview.")
            clearTransientDragState()
            dropZoneWindow.hide()
            return
        }

        let sessionID = activeDragSessionID
        FileLogger.log("⌛️ [DragRelease] Mouse up near drop zone via \(trigger). Waiting \(Int(dragReleaseGraceDelay * 1000))ms for AppKit drop.")
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let sessionID, self.activeDragSessionID != sessionID {
                    return
                }
                if let sessionID, self.resolvedDragSessionID == sessionID {
                    return
                }
                guard !self.dropZoneWindow.isPerformingDrop,
                      !self.dropZoneWindow.isShowingSuccess,
                      !self.dropZoneWindow.isShowingError,
                      !self.pendingDragPayloadURLs.isEmpty else {
                    return
                }

                let stillNearFallback = self.dropZoneWindow.dragVisibleContentFrame(inset: self.dragReleaseFallbackInset).contains(releasePoint)
                guard (stillNearFallback && self.currentDragAllowsFallbackRecovery) || wasHoveringDropTarget else {
                    FileLogger.log("🧭 [DragRelease] Grace period ended outside fallback zone. Dismissing preview.")
                    self.clearTransientDragState()
                    self.dropZoneWindow.hide()
                    return
                }

                FileLogger.log("🎣 [DragRelease] Recovering drop after grace period via \(trigger) with \(self.pendingDragPayloadURLs.count) file(s)")
                self.didPerformDrop(urls: self.pendingDragPayloadURLs)
            }
        }
        dragReleaseRecoveryWorkItem?.cancel()
        dragReleaseRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + dragReleaseGraceDelay, execute: workItem)
    }

    private func clearTransientDragState(preserveResolutionState: Bool = false) {
        stopDragReleaseMonitoring()
        cancelScheduledDragPreviewExit()
        dragReleaseRecoveryWorkItem?.cancel()
        dragReleaseRecoveryWorkItem = nil
        pendingDragPayloadURLs = []
        currentDragAllowsFallbackRecovery = false
        dragPreviewActivationPoint = nil
        hasEnteredCompactDropTarget = false
        dropZoneWindow.setPreviewDragActive(false)
        dropZoneWindow.setPreviewHoverActive(false)
        LocalFileDrag.clearCachedDragPayload()
        if !preserveResolutionState {
            activeDragSessionID = nil
            resolvedDragSessionID = nil
        }
    }

    private func beginDropZonePreview(with urls: [URL], verifiedByAppKit: Bool = false, allowFallbackRecovery: Bool = false) {
        guard !urls.isEmpty else { return }
        if let activeDragSessionID,
           resolvedDragSessionID != activeDragSessionID,
           (dropZoneWindow.isPreviewActive || dropZoneWindow.isAcceptingDragSession || !pendingDragPayloadURLs.isEmpty) {
            pendingDragPayloadURLs = urls
            if verifiedByAppKit || allowFallbackRecovery {
                currentDragAllowsFallbackRecovery = true
            }
            FileLogger.log("🔁 [DragHandoff] Preview already active; refreshing payload without resetting window.")
            return
        }
        let activationPoint = NSEvent.mouseLocation
        dragPreviewActivationPoint = activationPoint
        dropZoneWindow.setPreferredAnchorPoint(activationPoint)
        dropZoneWindow.prepareForDragPreview()
        beginDragSession(with: urls)
        currentDragAllowsFallbackRecovery = verifiedByAppKit || allowFallbackRecovery
        startDragReleaseMonitoring()
        dropZoneWindow.prewarmForDrag(under: statusItem)
        dropZoneWindow.setPreviewDragActive(true)
        dropZoneWindow.setPreviewHoverActive(false)
        updateWindowStatus()
        FileLogger.log("🚀 [DragHandoff] Showing drop zone preview for \(urls.count) file(s)")
        dropZoneWindow.show(under: statusItem)
    }

    private func handleDropZoneDragEnter() {
        cancelScheduledDragPreviewExit()
        currentDragAllowsFallbackRecovery = true
        dropZoneWindow.setPreviewDragActive(true)
        dropZoneWindow.setPreviewHoverActive(true)
        FileLogger.log("🎯 [DragHandoff] Drag entered drop zone window")
    }

    private func handleDropZoneDragExit() {
        dropZoneWindow.setPreviewHoverActive(false)
        requestDragEvaluation()
        FileLogger.log("🚪 [DragHandoff] Drag exited drop zone window; proximity monitor will decide whether preview stays visible")
    }

    private func migratedRuntimeConfiguration() -> AirSendRuntimeConfiguration {
        AirSendRuntimeConfiguration(
            preferredTargetID: selectedDeviceGroupKey,
            clipboardSyncEnabled: isAutoClipboardSyncEnabled,
            clipboardImageSyncEnabled: isAutoScreenshotSyncEnabled,
            screenshotSyncEnabled: false,
            launchAtLoginEnabled: isLaunchAtLoginEnabled,
            downloadDestination: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path,
            mediaDestination: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!.path,
            transportPreference: preferredLocalProtocol == .http ? .httpCompatibility : .https
        )
    }

    private func bootstrapRuntimePersistence() async {
        defer { hasBootstrappedRuntimePersistence = true }
        do {
            let outcome = try await runtimeConfigurationStore.load(defaults: migratedRuntimeConfiguration())
            runtimeConfiguration = outcome.configuration
            selectedDeviceGroupKey = outcome.configuration.preferredTargetID ?? broadcastSelectionKey
            UserDefaults.standard.set(
                outcome.configuration.clipboardSyncEnabled,
                forKey: "auto_clipboard_sync_enabled"
            )
            UserDefaults.standard.set(
                outcome.configuration.clipboardImageSyncEnabled,
                forKey: autoScreenshotSyncStorage
            )
            UserDefaults.standard.set(
                outcome.configuration.transportPreference == .httpCompatibility
                    ? ProtocolType.http.rawValue
                    : ProtocolType.https.rawValue,
                forKey: localProtocolPreferenceStorage
            )
            if runtimeConfiguration.launchAtLoginEnabled != isLaunchAtLoginEnabled {
                runtimeConfiguration.launchAtLoginEnabled = isLaunchAtLoginEnabled
                try await runtimeConfigurationStore.save(runtimeConfiguration)
            }
            try await transferHistoryStore?.setRetentionLimitPerDirection(
                runtimeConfiguration.historyLimitPerDirection
            )
            if let warning = outcome.warning {
                recordConsoleActivity(
                    title: "Configuration recovered",
                    detail: warning,
                    symbolName: "wrench.and.screwdriver.fill",
                    tone: .warning
                )
            }
        } catch {
            recordConsoleActivity(
                title: "Configuration unavailable",
                detail: error.localizedDescription,
                symbolName: "exclamationmark.triangle.fill",
                tone: .warning
            )
        }
        startRuntimeEventBridge()
        materializeManualPeers()
        updateAutomationServices()
        await reloadRuntimeHistory()
        await refreshDiagnosticsState(includeLogs: true)
        updateMenu()
    }

    private func persistRuntimeConfiguration() {
        let configuration = runtimeConfiguration
        let previousSave = runtimeConfigurationSaveTask
        runtimeConfigurationSaveTask = Task { [weak self] in
            _ = await previousSave?.value
            guard let self else { return }
            do {
                try await runtimeConfigurationStore.save(configuration)
                await runtimeEvents.publish(kind: .configurationChanged)
            } catch {
                self.recordConsoleActivity(
                    title: "Settings not saved",
                    detail: error.localizedDescription,
                    symbolName: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
        }
    }

    private func startRuntimeEventBridge() {
        runtimeEventTask?.cancel()
        runtimeEventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.runtimeEvents.stream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                self.handleRuntimeEvent(event)
            }
        }
    }

    private func handleRuntimeEvent(_ event: RuntimeEvent) {
        guard let transfer = event.transfer else {
            refreshSettingsWindowIfNeeded()
            return
        }

        runtimeTransfersByID[transfer.id] = transfer
        runtimeTransferMenuViews[transfer.id]?.update(record: transfer)
        refreshStatusItemActivityIndicator()

        if transfer.direction == .incoming, dropZoneWindow.isPerformingDrop {
            dropZoneWindow.setProgress(transfer.progress)
        }

        let powerReason = "transfer:\(transfer.id.uuidString)"
        switch transfer.status {
        case .preparing, .transferring, .paused:
            enableWakelock(reasonID: powerReason)
        default:
            disableWakelock(reasonID: powerReason)
        }

        if transfer.status.isTerminal, let transferHistoryStore {
            Task {
                do {
                    try await transferHistoryStore.persist(transfer)
                    await self.reloadRuntimeHistory()
                } catch {
                    logTransfer("⚠️ Failed to persist transfer history: \(error.localizedDescription)")
                }
            }
        }
        refreshSettingsWindowIfNeeded()
        updateMenu()
    }

    private func reloadRuntimeHistory() async {
        guard let transferHistoryStore else {
            runtimeHistory = []
            return
        }
        do {
            runtimeHistory = try await transferHistoryStore.list(
                limit: runtimeConfiguration.historyLimitPerDirection * 2
            )
        } catch {
            diagnosticsError = error.localizedDescription
            logTransfer("⚠️ Failed to load transfer history: \(error.localizedDescription)")
        }
        refreshSettingsWindowIfNeeded()
    }

    private func refreshDiagnosticsState(includeLogs: Bool) async {
        transferServerHealth = await transferServer.healthSnapshot()
        if includeLogs {
            runtimeLogTail = await FileLogger.tail(maxLines: 120)
        }
        lastDiagnosticsAt = Date()
        refreshSettingsWindowIfNeeded()
    }

    private var configuredDownloadDirectory: URL {
        URL(
            fileURLWithPath: (runtimeConfiguration.downloadDestination as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    private var configuredMediaDirectory: URL {
        URL(
            fileURLWithPath: (runtimeConfiguration.mediaDestination as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    private func isTrustedFingerprint(_ value: String) -> Bool {
        runtimeConfiguration.trustedPeerFingerprints.contains {
            DiscoveryIdentity.fingerprintsMatch($0, value)
        }
    }

    private func manualDevice(for peer: ManualPeer, lastSeen: Date = .distantPast) -> Device {
        let normalizedFingerprint = peer.fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = normalizedFingerprint?.isEmpty == false
            ? normalizedFingerprint!
            : "manual:\(peer.id)"
        return Device(
            id: identifier,
            alias: peer.alias,
            ip: peer.address,
            port: peer.port,
            deviceModel: "Manual Peer",
            deviceType: DeviceType.desktop.rawValue,
            version: "",
            https: preferredLocalProtocol == .https && normalizedFingerprint?.isEmpty == false,
            download: true,
            lastSeen: lastSeen
        )
    }

    private func materializeManualPeers() {
        let configuredIDs = Set(runtimeConfiguration.manualPeers.map { manualDevice(for: $0).id })
        devices = devices.filter { key, device in
            !key.hasPrefix("manual:") || configuredIDs.contains(device.id)
        }
        for peer in runtimeConfiguration.manualPeers {
            let identifier = manualDevice(for: peer).id
            let device = manualDevice(for: peer, lastSeen: devices[identifier]?.lastSeen ?? .distantPast)
            guard !DiscoveryIdentity.fingerprintsMatch(device.id, fingerprint) else { continue }
            devices[device.id] = device
        }
        knownDiscoveryHosts = Array(Set(knownDiscoveryHosts + runtimeConfiguration.manualPeers.map(\.address))).sorted()
    }

    private func probeConfiguredManualPeers(reason: String) {
        manualPeerProbeTask?.cancel()
        let peers = runtimeConfiguration.manualPeers
        guard !peers.isEmpty else { return }
        let service = discoveryService
        manualPeerProbeTask = Task { [weak self] in
            guard let self else { return }
            var configurationChanged = false
            for peer in peers {
                guard !Task.isCancelled else { break }
                do {
                    let device = try await service.resolveManualPeer(
                        alias: peer.alias,
                        address: peer.address,
                        port: peer.port,
                        expectedFingerprint: peer.fingerprint,
                        timeout: 3
                    )
                    devices[device.id] = device
                    if peer.id != device.id || peer.fingerprint == nil {
                        runtimeConfiguration.manualPeers.removeAll {
                            $0.id == peer.id
                                || ($0.address.caseInsensitiveCompare(peer.address) == .orderedSame && $0.port == peer.port)
                        }
                        runtimeConfiguration.manualPeers.append(
                            ManualPeer(
                                id: device.id,
                                alias: device.alias,
                                address: device.ip,
                                port: device.port,
                                fingerprint: device.id
                            )
                        )
                        configurationChanged = true
                    }
                    logTransfer("✅ Manual peer probe [\(reason)]: \(device.alias) at \(device.ip):\(device.port)")
                } catch {
                    let fallback = manualDevice(for: peer, lastSeen: .distantPast)
                    devices[fallback.id] = fallback
                    logTransfer("⚠️ Manual peer probe [\(reason)] failed for \(peer.address):\(peer.port): \(error.localizedDescription)")
                }
            }
            if configurationChanged {
                persistRuntimeConfiguration()
            }
            updateMenu()
            refreshSettingsWindowIfNeeded()
        }
    }

    private func shouldAcceptIncomingTransfer(_ request: TransferRequest) -> Bool {
        switch runtimeConfiguration.receivePolicy {
        case .off:
            return false
        case .trustedOnly:
            guard !request.senderFingerprint.isEmpty else { return false }
            return isTrustedFingerprint(request.senderFingerprint)
        case .ask:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Receive from \(request.senderAlias)?"
            let names = request.fileNames.prefix(3).joined(separator: "\n")
            let remaining = max(0, request.fileCount - 3)
            let more = remaining > 0 ? "\n…and \(remaining) more" : ""
            let size = ByteCountFormatter.string(fromByteCount: request.totalSize, countStyle: .file)
            alert.informativeText = "\(request.fileCount) item\(request.fileCount == 1 ? "" : "s") · \(size)\n\n\(names)\(more)"
            alert.addButton(withTitle: "Accept")
            alert.addButton(withTitle: "Decline")
            alert.buttons.first?.keyEquivalent = "\r"
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func showIncomingTransferStarted(_ request: TransferRequest) {
        hasStartedTransfer = true
        dropZoneWindow.resetFromSuccess()
        dropZoneWindow.setStatusText("Receiving from \(request.senderAlias)...")
        dropZoneWindow.isPerformingDrop = true
        dropZoneWindow.setProgress(0)
        dropZoneWindow.show(under: statusItem)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        FileLogger.bootstrap()

        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Item-0"
        statusItem.behavior = .removalAllowed
        
        if let button = statusItem.button {
            // Use a system symbol for the icon
            button.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "LocalSend")
            button.imagePosition = .imageOnly

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
            self?.handleDropZoneDragEnter()
        }
        dropZoneWindow.onDragExit = { [weak self] in
            self?.handleDropZoneDragExit()
        }
        dropZoneWindow.onClickDuringTransfer = { [weak self] in
            guard let self = self else { return }
            logTransfer("📲 Minimizing transfer to menu bar")
            self.isMinimizedToMenu = true
            self.dropZoneWindow.hide()
            self.refreshStatusItemActivityIndicator()
            self.updateMenu() // Refresh menu to include progress row
        }

        dropZoneWindow.parkHidden(under: statusItem)
        startDragProximityMonitoring()
        UpdateService.shared.onStatusChange = { [weak self] in
            self?.updateMenu()
        }
        UpdateService.shared.configureAutoUpdate(enabled: isAutoUpdateEnabled)
        
        loadDevices()
        migrateSelectionAndHistoryToV2IfNeeded()
        setupMenu()
        setupNetworkLifecycleMonitoring()
        updateWindowStatus()
        
        // Initialize Security & Start Services
        Task { @MainActor in
            await self.bootstrapRuntimePersistence()
            do {
                // 1. Setup Certificate (Still needed for Fingerprint identity)
                let certManager = CertificateManager.shared
                try await certManager.setup()
                let realFingerprint = try await certManager.getFingerprint()
                
                logTransfer("🔐 Security Initialized. Fingerprint: \(realFingerprint)")
                
                self.fingerprint = realFingerprint
                self.removeLocalDeviceFromDiscoveryState(matching: realFingerprint)
                await self.restartNetworkingStack()
            } catch {
                logTransfer("❌ Initialization Failed: \(error)")
                await self.restartNetworkingStack()
            }
        }
    }
    
    // MARK: - DropTargetViewDelegate

    func didEnterDrag(urls: [URL]) {
        beginDropZonePreview(with: urls, verifiedByAppKit: true)
    }

    func didExitDrag() {
        guard !dropZoneWindow.isAcceptingDragSession,
              !dropZoneWindow.isPerformingDrop,
              !dropZoneWindow.isShowingSuccess,
              !dropZoneWindow.isShowingError else { return }

        FileLogger.log("↘️ [DragHandoff] Drag left status item; compact handoff corridor is now active")
    }

    private func sendTextWithFallback(_ text: String, to group: DeviceGroupViewModel) async throws {
        var lastError: Error?
        for candidate in group.candidates {
            do {
                try await clipboardSender.sendText(text, to: candidate)
                rememberSuccessfulDevice(candidate)
                recordConsoleActivity(
                    title: "Clipboard text sent",
                    detail: displayTitle(for: group),
                    symbolName: "doc.on.clipboard",
                    tone: .good
                )
                return
            } catch {
                lastError = error
                logTransfer("⚠️ Text send failed for \(candidate.alias) [\(candidate.ip)] \(candidate.id): \(error)")
            }
        }
        
        if let error = lastError {
            recordConsoleActivity(
                title: "Clipboard send failed",
                detail: displayTitle(for: group),
                symbolName: "exclamationmark.triangle.fill",
                tone: .warning
            )
            throw error
        }
        recordConsoleActivity(
            title: "Clipboard send failed",
            detail: "No candidates available",
            symbolName: "exclamationmark.triangle.fill",
            tone: .warning
        )
        throw NSError(domain: "AirSend", code: -1, userInfo: [NSLocalizedDescriptionKey: "No candidates available"])
    }
    
    private func sendImageWithFallback(_ imageData: Data, to group: DeviceGroupViewModel) async throws {
        var lastError: Error?
        for candidate in group.candidates {
            do {
                try await clipboardSender.sendImage(imageData, to: candidate)
                rememberSuccessfulDevice(candidate)
                recordConsoleActivity(
                    title: "Clipboard image sent",
                    detail: displayTitle(for: group),
                    symbolName: "photo",
                    tone: .good
                )
                return
            } catch {
                lastError = error
                logTransfer("⚠️ Image send failed for \(candidate.alias) [\(candidate.ip)] \(candidate.id): \(error)")
            }
        }
        
        if let error = lastError {
            recordConsoleActivity(
                title: "Image send failed",
                detail: displayTitle(for: group),
                symbolName: "exclamationmark.triangle.fill",
                tone: .warning
            )
            throw error
        }
        recordConsoleActivity(
            title: "Image send failed",
            detail: "No candidates available",
            symbolName: "exclamationmark.triangle.fill",
            tone: .warning
        )
        throw NSError(domain: "AirSend", code: -1, userInfo: [NSLocalizedDescriptionKey: "No candidates available"])
    }
    
    private func sendFilesWithFallback(
        _ urls: [URL],
        to group: DeviceGroupViewModel,
        source: TransferSource = .filePicker
    ) async throws {
        var lastError: Error?
        for candidate in group.candidates {
            do {
                logTransfer("App: Initiating send to \(candidate.alias) [\(candidate.ip)]")
                try await fileSender.sendFiles(urls, to: candidate, source: source)
                rememberSuccessfulDevice(candidate)
                recordConsoleActivity(
                    title: "Files sent",
                    detail: "\(urls.count) item(s) · \(displayTitle(for: group))",
                    symbolName: "paperplane.fill",
                    tone: .good
                )
                return
            } catch {
                lastError = error
                logTransfer("⚠️ File send failed for \(candidate.alias) [\(candidate.ip)] \(candidate.id): \(error)")
            }
        }
        
        if let error = lastError {
            recordConsoleActivity(
                title: "File send failed",
                detail: displayTitle(for: group),
                symbolName: "exclamationmark.triangle.fill",
                tone: .warning
            )
            throw error
        }
        recordConsoleActivity(
            title: "File send failed",
            detail: "No candidates available",
            symbolName: "exclamationmark.triangle.fill",
            tone: .warning
        )
        throw NSError(domain: "AirSend", code: -1, userInfo: [NSLocalizedDescriptionKey: "No candidates available"])
    }
    
    func didPerformDrop(urls: [URL]) {
        FileLogger.log("📦 [Drop] didPerformDrop invoked with \(urls.count) file(s)")
        guard markCurrentDragSessionResolved(trigger: "didPerformDrop") else { return }
        clearTransientDragState(preserveResolutionState: true)
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
                            app.refreshStatusItemActivityIndicator()
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
                            self.refreshStatusItemActivityIndicator()
                            self.updateMenu()
                        }
                    }
                }
            }
            
            await fileSender.setOnCancelled {
                logTransfer("🛑 [App] fileSender.onCancelled callback triggered (Async).")
                DispatchQueue.main.async {
                    app.isRequestingInBackground = false
                    app.refreshStatusItemActivityIndicator()
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
                        app.refreshStatusItemActivityIndicator()
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
                    try await self.sendFilesWithFallback(validURLs, to: group, source: .dropZone)
                } catch {
                    logTransfer("App: Error sending to group \(group.key): \(error)")
                    lastErrorMsg = error.localizedDescription
                    allSuccessful = false
                }
            }
            
            timeoutTask.cancel()
            
            // C. Completion Phase
            await MainActor.run {
                if allSuccessful {
                    logTransfer("✅ Final Success: Showing popup.")
                    app.isMinimizedToMenu = false
                    app.isRequestingInBackground = false
                    app.refreshStatusItemActivityIndicator()
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
                    app.refreshStatusItemActivityIndicator()
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
        clipboardService.stop()
        // 重新接上剪贴板变化的回调
        clipboardService.onNewContent = { [weak self] newText in
            guard let self = self else { return }
            guard self.isAutoClipboardSyncEnabled else { return }
            guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            
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
            guard self.isAutoScreenshotSyncEnabled else { return }
            
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
        
        clipboardService.start(
            listenForText: isAutoClipboardSyncEnabled,
            listenForImages: isAutoScreenshotSyncEnabled
        )
    }

    private func updateAutomationServices() {
        startClipboardService()

        guard isScreenshotFileSyncEnabled else {
            screenshotWatcher.stop()
            refreshSettingsWindowIfNeeded()
            return
        }

        let captureDirectory = ScreenshotWatcher.defaultCaptureDirectory()
        screenshotWatcher.start(directory: captureDirectory) { [weak self] url in
            self?.handleNewScreenshot(url)
        }
        refreshSettingsWindowIfNeeded()
    }

    private func handleNewScreenshot(_ url: URL) {
        guard selectedDeviceGroupKey != broadcastSelectionKey,
              let group = buildDeviceGroups().first(where: { $0.key == selectedDeviceGroupKey }),
              group.candidates.contains(where: { isTrustedFingerprint($0.id) }) else {
            recordConsoleActivity(
                title: "Screenshot not sent",
                detail: "Choose one trusted device for automatic screenshots",
                symbolName: "lock.trianglebadge.exclamationmark",
                tone: .warning
            )
            return
        }

        Task {
            do {
                try await sendFilesWithFallback([url], to: group, source: .screenshot)
                recordConsoleActivity(
                    title: "Screenshot sent",
                    detail: url.lastPathComponent,
                    symbolName: "camera.viewfinder",
                    tone: .good
                )
            } catch {
                recordConsoleActivity(
                    title: "Screenshot send failed",
                    detail: error.localizedDescription,
                    symbolName: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
        }
    }

    private func updateTransferSaveDirectories() async {
        let saveDirectory = configuredDownloadDirectory
        let mediaDirectory = configuredMediaDirectory
        await transferServer.setGetSaveDirectory { file in
            let mimeType = file.fileType.lowercased()
            return mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/")
                ? mediaDirectory
                : saveDirectory
        }
    }

    func startTransferServer() async {
        await updateTransferSaveDirectories()

        await transferServer.setOnHealthChanged { [weak self] health in
            DispatchQueue.main.async {
                guard let self else { return }
                self.transferServerHealth = health
                self.refreshSettingsWindowIfNeeded()
                self.updateMenu()
            }
        }

        // Setup Reverse Discovery Callback
        await transferServer.setOnDeviceRegistered { [weak self] device in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !DiscoveryIdentity.fingerprintsMatch(device.id, self.fingerprint) else {
                    self.removeLocalDeviceFromDiscoveryState(matching: self.fingerprint)
                    return
                }
                self.devices[device.id] = device
                self.recordConsoleActivity(
                    title: "Device reachable",
                    detail: "\(device.alias) · \(device.ip)",
                    symbolName: "dot.radiowaves.left.and.right",
                    tone: .good
                )
                self.updateMenu()
            }
        }

        await transferServer.setOnTextReceived { [weak self] text in
            DispatchQueue.main.async {
                print("Received text from remote, updating clipboard...")
                self?.clipboardService.setContent(text)
            }
        }

        await campusFallback.setOnTextReceived { [weak self] text in
            DispatchQueue.main.async {
                print("Received campus fallback text from remote, updating clipboard...")
                self?.clipboardService.setContent(text)
            }
        }
        
        await transferServer.setOnCancelReceived { sessionID in
            logTransfer("🛑 [App] Incoming receiver session cancelled: \(sessionID)")
        }
        
        await transferServer.setOnTransferRequest { [weak self] request in
            logTransfer("📥 [App] Incoming transfer request from \(request.senderAlias) (\(request.fileCount) files, \(request.totalSize) bytes)")
            guard let self else { return false }
            let accepted = await self.shouldAcceptIncomingTransfer(request)
            if accepted {
                await self.showIncomingTransferStarted(request)
            }
            return accepted
        }

        await campusFallback.setOnTransferRequest { [weak self] request in
            logTransfer("📥 [App] Incoming campus transfer request from \(request.senderAlias) (\(request.fileCount) files, \(request.totalSize) bytes)")
            guard let self else { return false }
            let accepted = await self.shouldAcceptIncomingTransfer(request)
            if accepted {
                await self.showIncomingTransferStarted(request)
            }
            return accepted
        }
        
        await transferServer.setOnProgress { [weak self] _, progress in
            DispatchQueue.main.async {
                self?.dropZoneWindow.setProgress(progress)
            }
        }

        await transferServer.setOnTransferComplete { [weak self] (_, success, errorMsg) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                logTransfer("🏁 [App] Incoming transfer complete. Success: \(success), Error: \(errorMsg ?? "nil")")
                
                if success {
                    self.recordConsoleActivity(
                        title: "Transfer received",
                        detail: "Saved to Downloads",
                        symbolName: "tray.and.arrow.down.fill",
                        tone: .good
                    )
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
                    self.recordConsoleActivity(
                        title: "Transfer failed",
                        detail: errorMsg ?? "Incoming transfer failed",
                        symbolName: "exclamationmark.triangle.fill",
                        tone: .warning
                    )
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

        let campusDownloadDirectory = configuredDownloadDirectory
        let campusMediaDirectory = configuredMediaDirectory
        await campusFallback.setGetSaveDirectory { _, fileType in
            let mimeType = fileType.lowercased()
            return mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/")
                ? campusMediaDirectory
                : campusDownloadDirectory
        }

        await campusFallback.setOnTransferComplete { [weak self] (success, errorMsg) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                logTransfer("🏁 [App] Campus fallback transfer complete. Success: \(success), Error: \(errorMsg ?? "nil")")

                if success {
                    self.recordConsoleActivity(
                        title: "Transfer received",
                        detail: "Saved to Downloads",
                        symbolName: "tray.and.arrow.down.fill",
                        tone: .good
                    )
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
                    self.recordConsoleActivity(
                        title: "Transfer failed",
                        detail: errorMsg ?? "Incoming transfer failed",
                        symbolName: "exclamationmark.triangle.fill",
                        tone: .warning
                    )
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
            diagnosticsError = error.localizedDescription
            // Do NOT try to start in plain mode here. If it fails, we want it to fail loudly.
        }
        transferServerHealth = await transferServer.healthSnapshot()
        refreshSettingsWindowIfNeeded()
    }

    private func restartNetworkingStack(clearTransientDevices: Bool = false) async {
        isPublishingPreferredDiscoveryHosts = false
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        selectedTargetFreshnessTimer?.invalidate()
        selectedTargetFreshnessTimer = nil
        selectedTargetRecoveryTimer?.invalidate()
        selectedTargetRecoveryTimer = nil
        if hasStartedNetworkingStack {
            await transferServer.stop()
            discoveryService.stop()
            clipboardService.stop()
        }

        if clearTransientDevices {
            let keptDevices = devices.filter {
                let groupKey = self.deviceGroupKey(for: $0.value)
                return self.historyDeviceGroupKeys.contains(groupKey) || self.selectedDeviceGroupKey == groupKey
            }
            self.devices = keptDevices
        }

        let targetProtocol = preferredLocalProtocol
        if targetProtocol == .http {
            logTransfer("🌐 LAN compatibility mode enabled. Using plain HTTP for local receiver/discovery.")
        } else {
            logTransfer("🔐 Secure LAN mode enabled. Using HTTPS for local receiver/discovery.")
        }

        self.transferServer = HTTPTransferServer(
            fingerprint: fingerprint,
            transferCoordinator: transferCoordinator
        )
        self.discoveryService = UDPDiscoveryService(fingerprint: fingerprint, protocolType: targetProtocol)
        self.campusFallback = CampusFallbackCoordinator(
            fingerprint: fingerprint,
            transferCoordinator: transferCoordinator
        )
        self.fileSender = FileSender(
            fingerprint: fingerprint,
            localProtocol: targetProtocol,
            campusFallback: campusFallback,
            transferCoordinator: transferCoordinator
        )
        self.clipboardSender = ClipboardSender(fileSender: fileSender)

        startDiscovery()

        // Give UDP discovery a moment to bind before TCP starts on the same service port.
        try? await Task.sleep(nanoseconds: 500_000_000)

        await startTransferServer()
        updateAutomationServices()
        hasStartedNetworkingStack = true
        updateDiscoveryTimers()
        updateMenu()
    }

    private func setupNetworkLifecycleMonitoring() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.networkPathSignature(path)
            DispatchQueue.main.async {
                self?.handleNetworkPathChange(signature: signature, isSatisfied: path.status == .satisfied)
            }
        }
        networkPathMonitor.start(queue: networkPathMonitorQueue)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hasStartedNetworkingStack else { return }
                self.restartDiscoveryService(reason: "workspace-wake", triggerScan: false)
                self.discoveryService.triggerScan(allowSubnetSweep: false)
            }
        }
    }

    nonisolated private static func networkPathSignature(_ path: NWPath) -> String {
        let interfaces = [
            path.usesInterfaceType(.wiredEthernet) ? "ethernet" : nil,
            path.usesInterfaceType(.wifi) ? "wifi" : nil,
            path.usesInterfaceType(.other) ? "other" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        return "\(path.status)-\(interfaces)-expensive:\(path.isExpensive)-constrained:\(path.isConstrained)"
    }

    private func handleNetworkPathChange(signature: String, isSatisfied: Bool) {
        isNetworkPathSatisfied = isSatisfied
        refreshSettingsWindowIfNeeded()
        defer { lastNetworkPathSignature = signature }
        guard let previous = lastNetworkPathSignature, previous != signature else { return }
        guard hasStartedNetworkingStack, isSatisfied else {
            if hasStartedNetworkingStack, !isSatisfied {
                recordConsoleActivity(
                    title: "Network unavailable",
                    detail: "AirSend will recover when the LAN returns",
                    symbolName: "wifi.exclamationmark",
                    tone: .warning
                )
            }
            return
        }
        logTransfer("🌐 Network path changed; rebinding passive discovery")
        restartDiscoveryService(reason: "network-path-change", triggerScan: false)
        discoveryService.triggerScan(allowSubnetSweep: false)
    }
    
    func startDiscovery() {
        isPublishingPreferredDiscoveryHosts = true
        publishPreferredDiscoveryHostsIfActive()

        discoveryService.onTransportFailure = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.restartDiscoveryService(reason: reason, triggerScan: true)
            }
        }

        discoveryService.onCampusFallbackPacket = { [weak self] data, sourceIP in
            guard let self = self else { return }
            Task {
                await self.campusFallback.handlePacket(data, sourceIP: sourceIP)
            }
        }

        let discoveryService = self.discoveryService
        Task {
            await campusFallback.setPacketSender { data in
                discoveryService.sendCampusPacket(data)
            }
        }
        
        discoveryService.onDeviceFound = { [weak self] device in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !DiscoveryIdentity.fingerprintsMatch(device.id, self.fingerprint) else {
                    self.removeLocalDeviceFromDiscoveryState(matching: self.fingerprint)
                    return
                }
                
                let previousDevice = self.devices[device.id]
                let isNewDevice = previousDevice == nil
                let endpointChanged = previousDevice?.ip != device.ip
                    || previousDevice?.port != device.port
                    || previousDevice?.https != device.https
                let metadataChanged = previousDevice?.alias != device.alias
                    || previousDevice?.deviceModel != device.deviceModel
                    || previousDevice?.deviceType != device.deviceType
                    || previousDevice?.version != device.version
                    || previousDevice?.download != device.download
                
                // Update device state (important for heartbeat/lastSeen)
                self.devices[device.id] = device
                self.recordKnownDiscoveryHost(device.ip)
                
                // Only rebuild UI when the device is new or its reachable endpoint changed.
                if isNewDevice {
                    logTransfer("✅ Discovery: Found device [\(device.alias)] at \(device.ip):\(device.port)")
                    self.recordConsoleActivity(
                        title: "Device reachable",
                        detail: "\(device.alias) · \(device.ip)",
                        symbolName: "dot.radiowaves.left.and.right",
                        tone: .good
                    )
                    self.updateMenu()
                    self.refreshOpenMenuAfterDiscoveryIfNeeded(reason: "new-device")
                } else if endpointChanged || metadataChanged {
                    logTransfer("🔁 Discovery: Updated device [\(device.alias)] -> \(device.ip):\(device.port)")
                    self.recordConsoleActivity(
                        title: "Device updated",
                        detail: "\(device.alias) · \(device.ip)",
                        symbolName: "arrow.triangle.2.circlepath",
                        tone: .neutral
                    )
                    self.updateMenu()
                    self.refreshOpenMenuAfterDiscoveryIfNeeded(reason: "endpoint-update")
                }
            }
        }
        
        discoveryService.start()
        probePreferredDiscoveryHosts(trigger: .startup, reason: "startup-preferred")
        
        // 🔋 发送一次初始广播，然后交由 updateDiscoveryTimers() 管理后续定时
        discoveryService.sendAnnouncement()
        probeConfiguredManualPeers(reason: "discovery-start")
        updateDiscoveryTimers()
    }
    
    @discardableResult
    private func restartDiscoveryService(reason: String, triggerScan: Bool) -> Bool {
        let now = Date()
        if isRestartingDiscovery {
            logTransfer("⏳ Discovery restart already in progress. Skip [\(reason)].")
            return false
        }
        if now.timeIntervalSince(lastDiscoveryRestartAt) < discoveryRestartCooldown {
            logTransfer("⏱️ Discovery restart throttled. Skip [\(reason)].")
            return false
        }
        
        isRestartingDiscovery = true
        lastDiscoveryRestartAt = now
        
        let currentProtocol = discoveryService.protocolType
        let currentFingerprint = fingerprint
        logTransfer("♻️ Restarting discovery service: \(reason)")

        isPublishingPreferredDiscoveryHosts = false
        discoveryService.stop()
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        selectedTargetFreshnessTimer?.invalidate()
        selectedTargetFreshnessTimer = nil
        selectedTargetRecoveryTimer?.invalidate()
        selectedTargetRecoveryTimer = nil
        
        discoveryService = UDPDiscoveryService(fingerprint: currentFingerprint, protocolType: currentProtocol)
        startDiscovery()
        if triggerScan {
            discoveryService.triggerScan()
        }
        
        isRestartingDiscovery = false
        return true
    }
    
    // 🔋 连接感知的定时器管理
    func updateDiscoveryTimers() {
        if selectedDeviceGroupKey == broadcastSelectionKey {
            selectedTargetFreshnessTimer?.invalidate()
            selectedTargetFreshnessTimer = nil
            selectedTargetRecoveryTimer?.invalidate()
            selectedTargetRecoveryTimer = nil

            guard broadcastTimer == nil else {
                scheduleNextDeviceExpiry()
                return
            }
            // Broadcast 模式：30s 广播
            broadcastTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.discoveryService.sendAnnouncement()
                }
            }
            broadcastTimer?.tolerance = 15.0 // 🔋
            logTransfer("🔋 Discovery: 广播模式，30s 广播")
        } else {
            broadcastTimer?.invalidate()
            broadcastTimer = nil

            let candidates = devices.values.filter {
                deviceGroupKey(for: $0) == selectedDeviceGroupKey
            }
            if candidates.contains(where: { isDeviceOnline($0) }) {
                selectedTargetRecoveryTimer?.invalidate()
                selectedTargetRecoveryTimer = nil
                scheduleSelectedTargetFreshnessCheck(for: candidates)
            } else {
                selectedTargetFreshnessTimer?.invalidate()
                selectedTargetFreshnessTimer = nil
                startSelectedTargetRecoveryIfNeeded()
            }
        }
        
        scheduleNextDeviceExpiry()
    }

    private func scheduleSelectedTargetFreshnessCheck(for candidates: [Device]) {
        selectedTargetFreshnessTimer?.invalidate()
        selectedTargetFreshnessTimer = nil

        guard let freshestSeenAt = candidates.map(\.lastSeen).max() else { return }
        let interval = max(1, freshestSeenAt.addingTimeInterval(deviceOnlineTimeout).timeIntervalSinceNow)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateMenu()
                self.refreshSettingsWindowIfNeeded()
                self.updateDiscoveryTimers()
            }
        }
        timer.tolerance = min(5, interval * 0.1)
        selectedTargetFreshnessTimer = timer
    }

    private func startSelectedTargetRecoveryIfNeeded() {
        guard selectedTargetRecoveryTimer == nil else { return }

        recoverSelectedTarget(reason: "selected-target-offline")
        let timer = Timer.scheduledTimer(withTimeInterval: selectedTargetRecoveryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverSelectedTarget(reason: "selected-target-offline-periodic")
            }
        }
        timer.tolerance = 10
        selectedTargetRecoveryTimer = timer
        logTransfer("🔋 Discovery: selected target offline; enabled bounded 30s recovery")
    }

    private func recoverSelectedTarget(reason: String) {
        guard isNetworkPathSatisfied, isPublishingPreferredDiscoveryHosts else { return }
        publishPreferredDiscoveryHostsIfActive()
        discoveryService.sendAnnouncement()
        probePreferredDiscoveryHosts(trigger: .offlineRecovery, reason: reason)
        probeConfiguredManualPeers(reason: reason)
    }

    private func scheduleNextDeviceExpiry(now: Date = Date()) {
        cleanupTimer?.invalidate()
        cleanupTimer = nil

        let expiryDates = devices.values.compactMap { device -> Date? in
            guard !isConfiguredManualDevice(device) else { return nil }
            let groupKey = deviceGroupKey(for: device)
            if selectedDeviceGroupKey != broadcastSelectionKey && groupKey == selectedDeviceGroupKey {
                return nil
            }
            return device.lastSeen.addingTimeInterval(retentionInterval(for: device))
        }
        guard let nextExpiry = expiryDates.min() else { return }
        let interval = max(1, nextExpiry.timeIntervalSince(now))
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupOfflineDevices()
            }
        }
        cleanupTimer?.tolerance = min(10, interval * 0.15)
    }
    
    private func cleanupOfflineDevices() {
        let now = Date()
        var hasChanges = false
        for (id, device) in self.devices {
            if isConfiguredManualDevice(device) {
                continue
            }
            let groupKey = deviceGroupKey(for: device)
            if selectedDeviceGroupKey != broadcastSelectionKey && groupKey == selectedDeviceGroupKey {
                // Keep current selection candidates to avoid immediate "Target Offline" flapping.
                continue
            }
            if now.timeIntervalSince(device.lastSeen) > retentionInterval(for: device) {
                logTransfer("🧹 Cleanup: Device [\(device.alias)] timed out and removed.")
                self.devices.removeValue(forKey: id)
                hasChanges = true
            }
        }
        if hasChanges {
            self.updateMenu()
        }
        scheduleNextDeviceExpiry(now: now)
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
        runtimeTransferMenuViews.removeAll(keepingCapacity: true)
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
        menu.addItem(NSMenuItem(title: "Send Files…", action: #selector(chooseFilesToSend), keyEquivalent: "o"))
        let autoClipboardItem = NSMenuItem()
        autoClipboardItem.view = AutoClipboardToggleMenuItemView(
            title: "Auto Sync Clipboard Text",
            isOn: isAutoClipboardSyncEnabled,
            onToggle: { [weak self] enabled in
                self?.setAutoClipboardSyncEnabled(enabled, showInfoIfEnabling: true)
            }
        )
        menu.addItem(autoClipboardItem)
        let autoScreenshotItem = NSMenuItem()
        autoScreenshotItem.view = AutoClipboardToggleMenuItemView(
            title: "Auto Sync Clipboard Images",
            isOn: isAutoScreenshotSyncEnabled,
            onToggle: { [weak self] enabled in
                self?.setAutoScreenshotSyncEnabled(enabled, showInfoIfEnabling: true)
            }
        )
        menu.addItem(autoScreenshotItem)
        let screenshotFilesItem = NSMenuItem()
        screenshotFilesItem.view = AutoClipboardToggleMenuItemView(
            title: "Auto Sync Screenshot Files",
            isOn: isScreenshotFileSyncEnabled,
            onToggle: { [weak self] enabled in
                self?.setScreenshotFileSyncEnabled(enabled)
            }
        )
        menu.addItem(screenshotFilesItem)
        menu.addItem(NSMenuItem.separator())

        let activeTransfers = runtimeTransfersByID.values
            .filter { !$0.status.isTerminal }
            .sorted { $0.startedAt > $1.startedAt }
        if !activeTransfers.isEmpty {
            let headerItem = NSMenuItem()
            headerItem.view = MenuSectionHeaderView(title: "ACTIVE TRANSFERS")
            headerItem.isEnabled = false
            menu.addItem(headerItem)

            for transfer in activeTransfers.prefix(4) {
                let item = NSMenuItem()
                let view = RuntimeTransferMenuItemView(record: transfer) { [weak self] id in
                    self?.cancelTransfer(id: id.uuidString)
                }
                item.view = view
                menu.addItem(item)
                runtimeTransferMenuViews[transfer.id] = view
            }
            menu.addItem(NSMenuItem.separator())
        }
        
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
        let compatibilityItem = NSMenuItem(title: "Compatibility Mode (HTTP)", action: #selector(toggleLanCompatibilityMode(_:)), keyEquivalent: "")
        compatibilityItem.state = preferredLocalProtocol == .http ? .on : .off
        advancedMenu.addItem(compatibilityItem)

        let receivePolicyMenu = NSMenu(title: "Receive Requests")
        for option in [("Ask Every Time", ReceivePolicy.ask), ("Trusted Devices Only", ReceivePolicy.trustedOnly), ("Off", ReceivePolicy.off)] {
            let item = NSMenuItem(title: option.0, action: #selector(receivePolicySelected(_:)), keyEquivalent: "")
            item.representedObject = option.1.rawValue
            item.state = runtimeConfiguration.receivePolicy == option.1 ? .on : .off
            receivePolicyMenu.addItem(item)
        }
        let receivePolicyItem = NSMenuItem(title: "Receive Requests", action: nil, keyEquivalent: "")
        receivePolicyItem.submenu = receivePolicyMenu
        advancedMenu.addItem(receivePolicyItem)
        
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
        let settingsItem = NSMenuItem(title: "Open AirSend…", action: #selector(openSettingsWindow(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        if UpdateService.shared.isUpdateReady {
            let installUpdateItem = NSMenuItem(title: "Update ready, restart now?", action: #selector(installUpdate), keyEquivalent: "")
            menu.addItem(installUpdateItem)
        }
        
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
        if !isDeviceOnline(device) {
            connectionState = .offline
        } else if connectingSelectionKey == actionKey {
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
        guard !isStatusMenuOpen else {
            pendingStatusMenuRefresh = true
            updateWindowStatus()
            refreshSettingsWindowIfNeeded()
            return
        }

        setupMenu()
        updateWindowStatus()
        refreshSettingsWindowIfNeeded()
    }

    private func refreshOpenMenuAfterDiscoveryIfNeeded(reason: String) {
        guard isStatusMenuOpen else { return }
        pendingStatusMenuRefresh = true
        logTransfer("🧭 Discovery UI refresh deferred while menu is open (\(reason))")
    }
    
    @objc func sendClipboard() {
        print("Send Clipboard clicked")
        if let str = NSPasteboard.general.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    @objc private func chooseFilesToSend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Send"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let targets = targetGroupsForCurrentSelection()
        guard !targets.isEmpty else {
            recordConsoleActivity(
                title: "Files not sent",
                detail: "Choose an online target first",
                symbolName: "wifi.exclamationmark",
                tone: .warning
            )
            return
        }

        for group in targets {
            Task {
                do {
                    try await sendFilesWithFallback(panel.urls, to: group, source: .filePicker)
                } catch {
                    recordConsoleActivity(
                        title: "File send failed",
                        detail: error.localizedDescription,
                        symbolName: "exclamationmark.triangle.fill",
                        tone: .warning
                    )
                }
            }
        }
    }

    private func performManualRescan(reopenMenu: Bool, recordActivity: Bool = true) {
        guard !isDiscoveryRefreshing else { return }

        print("Manual refresh triggered - rebinding discovery and probing the current LAN")
        isDiscoveryRefreshing = true
        discoveryRefreshSummary = "Refreshing devices on the current LAN"
        discoveryRefreshCompletionWorkItem?.cancel()
        refreshSettingsWindowIfNeeded()

        if recordActivity {
            recordConsoleActivity(
                title: "Refreshing devices",
                detail: "Rebinding discovery on the current network",
                symbolName: "arrow.triangle.2.circlepath"
            )
        }

        let restarted = restartDiscoveryService(reason: "manual-refresh", triggerScan: true)
        if !restarted {
            publishPreferredDiscoveryHostsIfActive()
            probePreferredDiscoveryHosts(trigger: .manualRefresh, reason: "manual-refresh-preferred")
            discoveryService.triggerScan()
            probeConfiguredManualPeers(reason: "manual-refresh")
        }

        let completion = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let visibleCount = self.buildDeviceGroups().filter { group in
                    group.candidates.contains { self.isDeviceOnline($0) }
                }.count
                self.isDiscoveryRefreshing = false
                self.discoveryRefreshSummary = visibleCount == 0
                    ? "No online devices found"
                    : "Found \(visibleCount) online device\(visibleCount == 1 ? "" : "s")"
                if recordActivity {
                    self.recordConsoleActivity(
                        title: "Devices refreshed",
                        detail: self.discoveryRefreshSummary,
                        symbolName: visibleCount == 0 ? "wifi.exclamationmark" : "checkmark.circle.fill",
                        tone: visibleCount == 0 ? .neutral : .good
                    )
                }
                self.updateMenu()
                self.refreshSettingsWindowIfNeeded()
            }
        }
        discoveryRefreshCompletionWorkItem = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: completion)

        guard reopenMenu else { return }
        DispatchQueue.main.async {
            self.statusItem.button?.performClick(nil)
        }
    }

    private func runDiagnosticsFromConsole() {
        recordConsoleActivity(
            title: "Diagnostics started",
            detail: "Reading live runtime state",
            symbolName: "wave.3.right",
            tone: .neutral
        )
        Task {
            await refreshDiagnosticsState(includeLogs: true)
            recordConsoleActivity(
                title: "Diagnostics complete",
                detail: diagnosticsError ?? "Runtime state refreshed",
                symbolName: diagnosticsError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tone: diagnosticsError == nil ? .good : .warning
            )
        }
    }

    private func setReceivePolicy(_ rawValue: String) {
        guard let policy = ReceivePolicy(rawValue: rawValue) else { return }
        runtimeConfiguration.receivePolicy = policy
        persistRuntimeConfiguration()
        refreshSettingsWindowIfNeeded()
    }

    private func setHistoryLimitPerDirection(_ limit: Int) {
        guard (1...500).contains(limit) else { return }
        runtimeConfiguration.historyLimitPerDirection = limit
        persistRuntimeConfiguration()
        Task {
            do {
                try await transferHistoryStore?.setRetentionLimitPerDirection(limit)
                await reloadRuntimeHistory()
            } catch {
                diagnosticsError = error.localizedDescription
                refreshSettingsWindowIfNeeded()
            }
        }
    }

    private func setPeerTrusted(groupID: String, trusted: Bool) {
        guard let group = groupMap()[groupID] else { return }
        let fingerprints = group.candidates.map(\.id).filter { !$0.hasPrefix("manual:") }
        guard !fingerprints.isEmpty else {
            recordConsoleActivity(
                title: "Trust unavailable",
                detail: "Add the device fingerprint to this manual peer first",
                symbolName: "lock.slash",
                tone: .warning
            )
            return
        }
        var values = runtimeConfiguration.trustedPeerFingerprints
        if trusted {
            for value in fingerprints where !values.contains(where: { DiscoveryIdentity.fingerprintsMatch($0, value) }) {
                values.append(value)
            }
        } else {
            values.removeAll { existing in
                fingerprints.contains { DiscoveryIdentity.fingerprintsMatch(existing, $0) }
            }
        }
        runtimeConfiguration.trustedPeerFingerprints = values
        persistRuntimeConfiguration()
        refreshSettingsWindowIfNeeded()
    }

    private func showTrustDeviceDialog() {
        let candidates = buildDeviceGroups().filter { group in
            group.candidates.contains { device in
                !device.id.hasPrefix("manual:") && !isTrustedFingerprint(device.id)
            }
        }

        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Devices Available to Trust"
            alert.informativeText = "Discover an untrusted device on the current LAN, then try again."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28), pullsDown: false)
        popup.addItems(withTitles: candidates.map { group in
            "\(displayTitle(for: group)) · ID \(shortFingerprint(group.primary.id))"
        })

        let alert = NSAlert()
        alert.messageText = "Trust a Device"
        alert.informativeText = "Trusted devices may send files without a prompt when receiving is limited to trusted devices. Only trust devices you control."
        alert.alertStyle = .informational
        alert.accessoryView = popup
        alert.addButton(withTitle: "Trust Device")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn,
              candidates.indices.contains(popup.indexOfSelectedItem) else {
            return
        }

        let group = candidates[popup.indexOfSelectedItem]
        setPeerTrusted(groupID: group.key, trusted: true)
        recordConsoleActivity(
            title: "Device trusted",
            detail: displayTitle(for: group),
            symbolName: "checkmark.shield.fill",
            tone: .good
        )
    }

    private func revokeTrustedFingerprint(_ fingerprint: String) {
        let before = runtimeConfiguration.trustedPeerFingerprints.count
        runtimeConfiguration.trustedPeerFingerprints.removeAll {
            DiscoveryIdentity.fingerprintsMatch($0, fingerprint)
        }
        guard runtimeConfiguration.trustedPeerFingerprints.count != before else { return }
        persistRuntimeConfiguration()
        refreshSettingsWindowIfNeeded()
        recordConsoleActivity(
            title: "Device trust revoked",
            detail: "ID \(shortFingerprint(fingerprint))",
            symbolName: "shield.slash",
            tone: .neutral
        )
    }

    private func removeManualPeer(id: String) {
        guard let peer = runtimeConfiguration.manualPeers.first(where: { $0.id == id }) else { return }
        let device = manualDevice(for: peer)
        runtimeConfiguration.manualPeers.removeAll { $0.id == id }
        persistRuntimeConfiguration()
        devices.removeValue(forKey: device.id)
        materializeManualPeers()
        refreshSettingsWindowIfNeeded()
    }

    private enum DestinationKind {
        case downloads
        case media
    }

    private func selectDestination(kind: DestinationKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = kind == .downloads ? "Choose where received files are saved." : "Choose where received images and videos are saved."
        panel.directoryURL = kind == .downloads ? configuredDownloadDirectory : configuredMediaDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch kind {
        case .downloads:
            runtimeConfiguration.downloadDestination = url.path
        case .media:
            runtimeConfiguration.mediaDestination = url.path
        }
        persistRuntimeConfiguration()
        Task { await updateTransferSaveDirectories() }
        refreshSettingsWindowIfNeeded()
    }

    private func runtimeRecord(id: String) -> TransferRecord? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return runtimeTransfersByID[uuid] ?? runtimeHistory.first(where: { $0.id == uuid })
    }

    private func cancelTransfer(id: String) {
        guard let record = runtimeRecord(id: id), !record.status.isTerminal else { return }
        Task {
            if record.direction == .outgoing {
                await fileSender.cancelTransfer(record.id)
            } else {
                let cancelledHTTP = await transferServer.cancelTransfer(id: record.id)
                if !cancelledHTTP {
                    _ = await campusFallback.cancelIncomingTransfer(record.id)
                }
            }
        }
    }

    private func retryTransfer(id: String) {
        guard let record = runtimeRecord(id: id), record.isRetryable else { return }
        let targetID = record.retrySpec?.targetID ?? record.peer.id
        guard let device = devices[targetID] ?? devices.values.first(where: {
            DiscoveryIdentity.fingerprintsMatch($0.id, targetID)
        }) else {
            recordConsoleActivity(
                title: "Retry unavailable",
                detail: "The original target is offline",
                symbolName: "arrow.clockwise.circle",
                tone: .warning
            )
            return
        }
        Task {
            do {
                _ = try await fileSender.retry(record, to: device)
            } catch {
                recordConsoleActivity(
                    title: "Retry failed",
                    detail: error.localizedDescription,
                    symbolName: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
        }
    }

    private func deleteHistory(id: String) {
        guard let uuid = UUID(uuidString: id), let transferHistoryStore else { return }
        Task {
            try? await transferHistoryStore.delete(id: uuid)
            runtimeTransfersByID.removeValue(forKey: uuid)
            await reloadRuntimeHistory()
        }
    }

    private func clearHistory(direction rawValue: String) {
        guard let direction = TransferDirection(rawValue: rawValue), let transferHistoryStore else { return }
        Task {
            try? await transferHistoryStore.clear(direction: direction)
            runtimeTransfersByID = runtimeTransfersByID.filter { !$0.value.status.isTerminal || $0.value.direction != direction }
            await reloadRuntimeHistory()
        }
    }

    private func transferURLs(for record: TransferRecord) -> [URL] {
        record.files.compactMap { file in
            let path = record.direction == .incoming ? file.savedPath : file.sourcePath
            guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private func revealTransfer(id: String) {
        guard let record = runtimeRecord(id: id) else { return }
        let urls = transferURLs(for: record)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func shareTransfer(id: String) {
        guard let record = runtimeRecord(id: id),
              !transferURLs(for: record).isEmpty,
              let view = settingsWindowController?.window?.contentView else { return }
        let picker = NSSharingServicePicker(items: transferURLs(for: record))
        sharingServicePicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "AirSend-Diagnostics-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await FileLogger.export(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                diagnosticsError = error.localizedDescription
                refreshSettingsWindowIfNeeded()
            }
        }
    }

    private func clearLogs() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear AirSend logs?"
        alert.informativeText = "This removes the local diagnostic log history."
        alert.addButton(withTitle: "Clear Logs")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            try? await FileLogger.clear()
            runtimeLogTail = []
            refreshSettingsWindowIfNeeded()
        }
    }

    private func restartRuntimeFromConsole() {
        Task {
            await restartNetworkingStack(clearTransientDevices: false)
            await refreshDiagnosticsState(includeLogs: true)
        }
    }

    @objc func scanForDevices(_ sender: NSMenuItem) {
        performManualRescan(reopenMenu: true)
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
                await self.restartNetworkingStack(clearTransientDevices: true)
                
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
        alert.messageText = "Add Manual Device"
        alert.informativeText = "AirSend will remember this endpoint and probe it directly. Add its fingerprint to use verified HTTPS."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let aliasField = NSTextField(string: "")
        aliasField.placeholderString = "Living Room Phone"
        let addressField = NSTextField(string: "")
        addressField.placeholderString = "192.168.1.100"
        let portField = NSTextField(string: String(NetworkPorts.transferPort))
        let fingerprintField = NSTextField(string: "")
        fingerprintField.placeholderString = "Optional SHA-256 fingerprint"
        for field in [aliasField, addressField, portField, fingerprintField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), aliasField],
            [NSTextField(labelWithString: "Address"), addressField],
            [NSTextField(labelWithString: "Port"), portField],
            [NSTextField(labelWithString: "Fingerprint"), fingerprintField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        alert.accessoryView = grid

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = fingerprintField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let port = Int(portField.stringValue), (1...65_535).contains(port) else {
            recordConsoleActivity(
                title: "Manual device not added",
                detail: "Enter a valid address and port",
                symbolName: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }
        recordConsoleActivity(
            title: "Connecting to manual device",
            detail: "\(address):\(port)",
            symbolName: "point.3.connected.trianglepath.dotted"
        )
        Task {
            do {
                let device = try await discoveryService.resolveManualPeer(
                    alias: alias,
                    address: address,
                    port: port,
                    expectedFingerprint: fingerprint.isEmpty ? nil : fingerprint
                )
                let peer = ManualPeer(
                    id: device.id,
                    alias: device.alias,
                    address: device.ip,
                    port: device.port,
                    fingerprint: device.id
                )
                runtimeConfiguration.manualPeers.removeAll {
                    DiscoveryIdentity.fingerprintsMatch($0.id, peer.id)
                        || ($0.address.caseInsensitiveCompare(peer.address) == .orderedSame && $0.port == peer.port)
                }
                runtimeConfiguration.manualPeers.append(peer)
                persistRuntimeConfiguration()
                devices[device.id] = device
                selectedDeviceGroupKey = deviceGroupKey(for: device)
                preferredDeviceIdsByGroup[selectedDeviceGroupKey] = device.id
                discoveryService.updatePreferredProbeHosts(prioritizedDiscoveryHosts())
                recordConsoleActivity(
                    title: "Manual device added",
                    detail: "\(device.alias) · \(device.ip):\(device.port)",
                    symbolName: "checkmark.circle.fill",
                    tone: .good
                )
                updateMenu()
                refreshSettingsWindowIfNeeded()
            } catch {
                recordConsoleActivity(
                    title: "Manual device not added",
                    detail: error.localizedDescription,
                    symbolName: "exclamationmark.triangle.fill",
                    tone: .warning
                )
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "Device Could Not Be Added"
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: "OK")
                failure.runModal()
            }
        }
    }

    private func openAndroidRepository() {
        guard let url = URL(string: androidAirSendRepository) else { return }
        NSWorkspace.shared.open(url)
    }

    private func showAndroidIntegrationAlert(featureName: String, description: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(featureName) Requires AirSend on Android"
        alert.informativeText = """
        \(description)

        The official LocalSend app can receive clipboard content manually, but silent background sync is only supported with the AirSend Android build.

        This setup requires root-level integration (Magisk + LSPosed) and is intended for users with Android modding experience.

        Repository: \(androidAirSendRepository)
        """
        alert.addButton(withTitle: "Open Repository")
        alert.addButton(withTitle: "Continue")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAndroidRepository()
        }
    }

    private func setAutoClipboardSyncEnabled(_ enabled: Bool, showInfoIfEnabling: Bool) {
        if isAutoClipboardSyncEnabled != enabled {
            isAutoClipboardSyncEnabled = enabled
        }
        updateAutomationServices()

        guard enabled, showInfoIfEnabling else {
            return
        }

        showAndroidIntegrationAlert(
            featureName: "Auto Clipboard Sync",
            description: "New plain text copied on your Mac clipboard will be pushed to the selected Android target."
        )
    }

    private func setAutoScreenshotSyncEnabled(_ enabled: Bool, showInfoIfEnabling: Bool) {
        if isAutoScreenshotSyncEnabled != enabled {
            isAutoScreenshotSyncEnabled = enabled
        }
        updateAutomationServices()

        guard enabled, showInfoIfEnabling else {
            return
        }

        showAndroidIntegrationAlert(
            featureName: "Auto Clipboard Image Sync",
            description: "Copied images on your Mac are converted to PNG and pushed to the selected Android target."
        )
    }

    private func setScreenshotFileSyncEnabled(_ enabled: Bool) {
        guard runtimeConfiguration.screenshotSyncEnabled != enabled else { return }
        runtimeConfiguration.screenshotSyncEnabled = enabled
        persistRuntimeConfiguration()
        updateAutomationServices()
        recordConsoleActivity(
            title: enabled ? "Screenshot sync enabled" : "Screenshot sync disabled",
            detail: enabled ? "Watching \(ScreenshotWatcher.defaultCaptureDirectory().path)" : "Screenshot folder watcher stopped",
            symbolName: "camera.viewfinder",
            tone: .neutral
        )
    }

    private func setAutoUpdateEnabled(_ enabled: Bool) {
        guard isAutoUpdateEnabled != enabled else { return }
        isAutoUpdateEnabled = enabled
        print("🚨 App: Auto-update toggled to [\(isAutoUpdateEnabled)]")
    }

    private func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService()
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    logTransfer("🚀 Launch at Login enabled.")
                }
            } else if service.status == .enabled {
                try service.unregister()
                logTransfer("🚀 Launch at Login disabled.")
            }
            runtimeConfiguration.launchAtLoginEnabled = enabled
            persistRuntimeConfiguration()
            updateMenu()
        } catch {
            logTransfer("❌ Failed to toggle Launch at Login: \(error)")
            refreshSettingsWindowIfNeeded()
        }
    }

    private func setCompatibilityModeEnabled(_ enabled: Bool) {
        let targetProtocol: ProtocolType = enabled ? .http : .https
        guard preferredLocalProtocol != targetProtocol else { return }

        preferredLocalProtocol = targetProtocol
        logTransfer(
            enabled
                ? "🌐 Compatibility mode toggled on. Future inbound LAN transfers will prefer plain HTTP."
                : "🔐 Compatibility mode toggled off. Future inbound LAN transfers will prefer HTTPS."
        )
        recordConsoleActivity(
            title: enabled ? "Compatibility mode enabled" : "HTTPS mode enabled",
            detail: enabled ? "Local receiver prefers HTTP compatibility" : "Local receiver prefers HTTPS",
            symbolName: "network",
            tone: .neutral
        )

        Task { @MainActor in
            await restartNetworkingStack()
        }
    }

    @objc private func openSettingsWindow(_ sender: AnyObject?) {
        DispatchQueue.main.async {
            let controller = self.ensureSettingsWindowController()
            controller.showSettingsWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let controller = ensureSettingsWindowController()
        controller.showSettingsWindow()
        return false
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        isStatusMenuOpen = true
        discoveryService.sendAnnouncement()
    }
    
    func menuDidClose(_ menu: NSMenu) {
        isStatusMenuOpen = false
        if pendingStatusMenuRefresh {
            pendingStatusMenuRefresh = false
            DispatchQueue.main.async { [weak self] in
                self?.updateMenu()
            }
        }
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
        guard !isQuitting else { return }
        isQuitting = true
        stopDragProximityMonitoring()
        stopDragReleaseMonitoring()
        dragReleaseRecoveryWorkItem?.cancel()
        discoveryRefreshCompletionWorkItem?.cancel()
        settingsWindowRelativeTimeTimer?.invalidate()
        broadcastTimer?.invalidate()
        cleanupTimer?.invalidate()
        selectedTargetFreshnessTimer?.invalidate()
        selectedTargetRecoveryTimer?.invalidate()
        clipboardService.stop()
        screenshotWatcher.stop()
        manualPeerProbeTask?.cancel()
        isPublishingPreferredDiscoveryHosts = false
        discoveryService.stop()
        networkPathMonitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        runtimeEventTask?.cancel()
        let pendingConfigurationSave = runtimeConfigurationSaveTask
        Task {
            _ = await pendingConfigurationSave?.value
            NSApplication.shared.terminate(self)
        }
    }
    
    // MARK: - System Integration
    
    private func enableWakelock(reasonID: String = "legacy-transfer") {
        activePowerAssertionReasons.insert(reasonID)
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
    
    private func disableWakelock(reasonID: String = "legacy-transfer") {
        activePowerAssertionReasons.remove(reasonID)
        guard activePowerAssertionReasons.isEmpty else { return }
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
        setLaunchAtLoginEnabled(!isLaunchAtLoginEnabled)
    }
    
    // MARK: - Update Logic
    
    @objc func manualCheckUpdate() {
        print("🚨 App: Manual update check triggered.")
        UpdateService.shared.checkUpdate(explicit: true)
    }

    @objc func installUpdate() {
        UpdateService.shared.installUpdate()
    }
    
    @objc func toggleAutoUpdate(_ sender: NSMenuItem) {
        setAutoUpdateEnabled(!isAutoUpdateEnabled)
    }

    @objc private func toggleLanCompatibilityMode(_ sender: NSMenuItem) {
        setCompatibilityModeEnabled(preferredLocalProtocol != .http)
    }

    @objc private func receivePolicySelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        setReceivePolicy(rawValue)
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

private struct SelfTestCaseResult {
    let label: String
    let success: Bool
    let elapsed: TimeInterval
    let errorDescription: String?
}

private final class SelfTestExitState: @unchecked Sendable {
    var code: Int32 = 0
}

private final class SelfTestTextCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func store(_ text: String) {
        lock.withLock { value = text }
    }

    func load() -> String? {
        lock.withLock { value }
    }
}

private enum SelfTestRunner {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["AIRSEND_SELFTEST"] == "1" else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let exitState = SelfTestExitState()

        Task.detached {
            defer { semaphore.signal() }
            do {
                try await run()
            } catch {
                print("SELFTEST_FATAL \(error.localizedDescription)")
                exitState.code = 1
            }
        }

        semaphore.wait()
        fflush(stdout)
        exit(exitState.code)
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        if env["AIRSEND_SELFTEST_LOOPBACK"] == "1" {
            try await runLoopback()
            print("SELFTEST_OK")
            return
        }
        let ip = try requiredEnv("AIRSEND_SELFTEST_DEVICE_IP", env: env)
        let fingerprint = try requiredEnv("AIRSEND_SELFTEST_DEVICE_FINGERPRINT", env: env)
        let alias = env["AIRSEND_SELFTEST_DEVICE_ALIAS"] ?? "AirSend Android Module"
        let model = env["AIRSEND_SELFTEST_DEVICE_MODEL"] ?? "Android Device"
        let deviceType = env["AIRSEND_SELFTEST_DEVICE_TYPE"] ?? "headless"
        let goodPort = Int(env["AIRSEND_SELFTEST_DEVICE_PORT"] ?? "\(NetworkPorts.transferPort)") ?? Int(NetworkPorts.transferPort)
        let badPort = Int(env["AIRSEND_SELFTEST_BAD_PORT"] ?? "\(goodPort + 1)") ?? (goodPort + 1)
        let deviceUsesHTTPS = (env["AIRSEND_SELFTEST_DEVICE_HTTPS"] ?? "false").lowercased() == "true"
        let localProtocol = ProtocolType(rawValue: env["AIRSEND_SELFTEST_LOCAL_PROTOCOL"] ?? "http") ?? .http
        let localFingerprint = env["AIRSEND_SELFTEST_LOCAL_FINGERPRINT"] ?? "probe-mac-fingerprint"
        let maxFastFailure = Double(env["AIRSEND_SELFTEST_MAX_BAD_ELAPSED"] ?? "16") ?? 16
        let campusMode = (env["AIRSEND_SELFTEST_CAMPUS"] ?? "0") == "1"

        let goodDevice = Device(
            id: fingerprint,
            alias: alias,
            ip: ip,
            port: goodPort,
            deviceModel: model,
            deviceType: deviceType,
            version: "3.5.0",
            https: deviceUsesHTTPS,
            download: true,
            lastSeen: Date()
        )
        let badDevice = Device(
            id: fingerprint,
            alias: alias,
            ip: ip,
            port: badPort,
            deviceModel: model,
            deviceType: deviceType,
            version: "3.5.0",
            https: deviceUsesHTTPS,
            download: true,
            lastSeen: Date()
        )

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("airsend-selftest-\(UUID().uuidString).txt")
        try "airsend-selftest-\(Int(Date().timeIntervalSince1970))".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let selfTestCoordinator = TransferCoordinator()
        let campusFallback = campusMode
            ? CampusFallbackCoordinator(
                fingerprint: localFingerprint,
                transferCoordinator: selfTestCoordinator
            )
            : nil
        let discoveryService = campusMode ? UDPDiscoveryService(fingerprint: localFingerprint, protocolType: localProtocol) : nil

        if let campusFallback, let discoveryService {
            discoveryService.onCampusFallbackPacket = { data, sourceIP in
                Task {
                    await campusFallback.handlePacket(data, sourceIP: sourceIP)
                }
            }
            await campusFallback.setPacketSender { data in
                discoveryService.sendCampusPacket(data)
            }
            discoveryService.start()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        defer {
            discoveryService?.stop()
        }

        let fileSender = FileSender(fingerprint: localFingerprint, localProtocol: localProtocol, campusFallback: campusFallback)
        let clipboardSender = ClipboardSender(fileSender: fileSender)

        if campusMode {
            let fileGood = await runCase("FILE_GOOD_PORT") {
                _ = try await fileSender.sendFiles([tempFile], to: goodDevice)
            }
            let textGood = await runCase("TEXT_GOOD_PORT") {
                _ = try await clipboardSender.sendText("selftest-text-good-port", to: goodDevice)
            }

            let failures = [fileGood, textGood].filter { !$0.success }
            if !failures.isEmpty {
                let details = failures
                    .map { "\($0.label)=success:\($0.success),elapsed:\(String(format: "%.2f", $0.elapsed)),error:\($0.errorDescription ?? "nil")" }
                    .joined(separator: " | ")
                throw NSError(domain: "SelfTestRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: details])
            }
            print("SELFTEST_OK")
            return
        }

        let fileBad = await runCase("FILE_BAD_PORT") {
            _ = try await fileSender.sendFiles([tempFile], to: badDevice)
        }
        let fileGood = await runCase("FILE_GOOD_PORT") {
            _ = try await fileSender.sendFiles([tempFile], to: goodDevice)
        }
        let textBad = await runCase("TEXT_BAD_PORT") {
            _ = try await clipboardSender.sendText("selftest-text-bad-port", to: badDevice)
        }
        let textGood = await runCase("TEXT_GOOD_PORT") {
            _ = try await clipboardSender.sendText("selftest-text-good-port", to: goodDevice)
        }

        let mustSucceed = [fileGood, textGood].filter { !$0.success }
        let mustFailFast = [fileBad, textBad].filter { $0.success || $0.elapsed > maxFastFailure }

        if !mustSucceed.isEmpty || !mustFailFast.isEmpty {
            let details = (mustSucceed + mustFailFast)
                .map { "\($0.label)=success:\($0.success),elapsed:\(String(format: "%.2f", $0.elapsed)),error:\($0.errorDescription ?? "nil")" }
                .joined(separator: " | ")
            throw NSError(domain: "SelfTestRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: details])
        }

        print("SELFTEST_OK")
    }

    static func runLoopback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("airsend-loopback-\(UUID().uuidString)", isDirectory: true)
        let firstSource = root.appendingPathComponent("first", isDirectory: true)
        let secondSource = root.appendingPathComponent("second", isDirectory: true)
        let destination = root.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstFile = firstSource.appendingPathComponent("note.txt")
        let secondFile = secondSource.appendingPathComponent("note.txt")
        try Data("first ordinary text file".utf8).write(to: firstFile)
        try Data("second ordinary text file".utf8).write(to: secondFile)

        let port = UInt16(54_000 + Int.random(in: 0..<1_000))
        let receiverCoordinator = TransferCoordinator()
        let receiver = HTTPTransferServer(
            port: port,
            fingerprint: "aabbcc",
            transferCoordinator: receiverCoordinator
        )
        let clipboardCapture = SelfTestTextCapture()
        await receiver.setOnTransferRequest { _ in true }
        await receiver.setGetSaveDirectory { _ in destination }
        await receiver.setOnTextReceived { text in clipboardCapture.store(text) }
        try await receiver.start()

        do {
            let senderCoordinator = TransferCoordinator()
            let sender = FileSender(
                fingerprint: "ddeeff",
                localProtocol: .http,
                campusFallback: nil,
                transferCoordinator: senderCoordinator
            )
            let clipboard = ClipboardSender(fileSender: sender)
            let device = Device(
                id: "aabbcc",
                alias: "Loopback Receiver",
                ip: "127.0.0.1",
                port: Int(port),
                deviceModel: "macOS",
                deviceType: DeviceType.desktop.rawValue,
                version: "selftest",
                https: false,
                download: true,
                lastSeen: Date()
            )

            let manualResolver = UDPDiscoveryService(
                fingerprint: "ddeeff",
                protocolType: .http
            )
            let resolved = try await manualResolver.resolveManualPeer(
                alias: "Verified Loopback",
                address: "127.0.0.1",
                port: Int(port),
                expectedFingerprint: "aabbcc"
            )
            guard resolved.id == "aabbcc", resolved.alias == "Verified Loopback" else {
                throw NSError(domain: "SelfTestRunner", code: 15, userInfo: [NSLocalizedDescriptionKey: "Manual peer resolution did not verify endpoint identity"])
            }
            do {
                _ = try await manualResolver.resolveManualPeer(
                    alias: "Wrong Fingerprint",
                    address: "127.0.0.1",
                    port: Int(port),
                    expectedFingerprint: "112233"
                )
                throw NSError(domain: "SelfTestRunner", code: 16, userInfo: [NSLocalizedDescriptionKey: "Manual peer fingerprint mismatch was accepted"])
            } catch ManualPeerProbeError.fingerprintMismatch {
            }

            async let firstSend: UUID = sender.sendFiles([firstFile], to: device)
            async let secondSend: UUID = sender.sendFiles([secondFile], to: device)
            _ = try await (firstSend, secondSend)

            guard clipboardCapture.load() == nil else {
                throw NSError(domain: "SelfTestRunner", code: 10, userInfo: [NSLocalizedDescriptionKey: "Ordinary text files must not update the clipboard"])
            }
            _ = try await clipboard.sendText("loopback clipboard text", to: device)
            guard clipboardCapture.load() == "loopback clipboard text" else {
                throw NSError(domain: "SelfTestRunner", code: 11, userInfo: [NSLocalizedDescriptionKey: "Clipboard identity was not delivered exactly"])
            }

            let receivedFiles = try FileManager.default.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard receivedFiles.count == 2,
                  receivedFiles.allSatisfy({ $0.lastPathComponent != "clipboard.txt" }) else {
                throw NSError(domain: "SelfTestRunner", code: 12, userInfo: [NSLocalizedDescriptionKey: "Duplicate naming or clipboard persistence failed"])
            }
            let receivedPayloads = try Set(receivedFiles.map { try String(contentsOf: $0, encoding: .utf8) })
            guard receivedPayloads == Set(["first ordinary text file", "second ordinary text file"]) else {
                throw NSError(domain: "SelfTestRunner", code: 13, userInfo: [NSLocalizedDescriptionKey: "Concurrent receiver payloads were corrupted"])
            }

            let senderRecords = await senderCoordinator.list()
            let receiverRecords = await receiverCoordinator.list()
            guard senderRecords.count == 3,
                  receiverRecords.count == 3,
                  senderRecords.allSatisfy({ $0.status == .completed }),
                  receiverRecords.allSatisfy({ $0.status == .completed }) else {
                throw NSError(domain: "SelfTestRunner", code: 14, userInfo: [NSLocalizedDescriptionKey: "Loopback transfer records did not reach independent terminal states"])
            }
            await receiver.stop()
        } catch {
            await receiver.stop()
            throw error
        }
    }

    static func runCase(_ label: String, operation: @escaping () async throws -> Void) async -> SelfTestCaseResult {
        let start = Date()
        do {
            try await operation()
            let elapsed = Date().timeIntervalSince(start)
            print("\(label)_SUCCESS elapsed=\(String(format: "%.2f", elapsed))s")
            return SelfTestCaseResult(label: label, success: true, elapsed: elapsed, errorDescription: nil)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("\(label)_FAIL elapsed=\(String(format: "%.2f", elapsed))s error=\(error.localizedDescription)")
            return SelfTestCaseResult(label: label, success: false, elapsed: elapsed, errorDescription: error.localizedDescription)
        }
    }

    static func requiredEnv(_ key: String, env: [String: String]) throws -> String {
        if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        throw NSError(domain: "SelfTestRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing env \(key)"])
    }
}

// Execution Entry Point
SelfTestRunner.runIfRequested()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
