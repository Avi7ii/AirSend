import Cocoa
import AirSendConsoleSupport
import SwiftUI

struct AirSendSettingsDeviceSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let model: String
    let deviceType: String
    let ipAddress: String
    let port: Int
    let protocolLabel: String
    let versionLabel: String
    let fingerprintSuffix: String
    let statusLabel: String
    let peerCount: Int
    let isSelected: Bool
    let isManual: Bool
    let isOnline: Bool
}

enum AirSendConsoleHealthTone: String, Hashable {
    case good
    case warning
    case neutral
}

struct AirSendActivitySummary: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let createdAt: Date
    let symbolName: String
    let tone: AirSendConsoleHealthTone

    var timeLabel: String {
        AirSendRelativeTimeFormatter.label(since: createdAt)
    }
}

struct AirSendTransferSummary: Identifiable, Hashable {
    let id: String
    let direction: String
    let source: String
    let peerTitle: String
    let fileTitle: String
    let detail: String
    let fileKind: AirSendTransferFileKind
    let status: String
    let progress: Double
    let byteProgress: String
    let startedAt: Date
    let savedPaths: [String]
    let previewText: String?
    let failureMessage: String?
    let canCancel: Bool
    let canRetry: Bool
    let hasAvailableFiles: Bool

    var timeLabel: String {
        AirSendRelativeTimeFormatter.label(since: startedAt)
    }
}

struct AirSendManualPeerSummary: Identifiable, Hashable {
    let id: String
    let alias: String
    let endpoint: String
    let fingerprintSuffix: String?
}

struct AirSendTrustedPeerSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let fingerprintSuffix: String
    let isOnline: Bool
}

struct AirSendDiagnosticSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let value: String
    let detail: String?
    let symbolName: String
    let tone: AirSendConsoleHealthTone
}

struct AirSendSettingsSnapshot {
    var clipboardSyncEnabled: Bool
    var screenshotSyncEnabled: Bool
    var autoUpdateEnabled: Bool
    var launchAtLoginEnabled: Bool
    var compatibilityModeEnabled: Bool
    var discoveredDeviceCount: Int
    var rememberedDeviceCount: Int
    var isDiscoveryRefreshing: Bool
    var discoveryRefreshSummary: String
    var selectedTargetTitle: String
    var selectedTargetSubtitle: String
    var selectedTargetIsBroadcast: Bool
    var canSendToSelectedTarget: Bool
    var protocolLabel: String
    var fingerprintSuffix: String
    var currentVersion: String
    var nearbyDevices: [AirSendSettingsDeviceSummary]
    var healthTitle: String
    var healthDetail: String
    var healthTone: AirSendConsoleHealthTone
    var preflightSummary: String
    var recentActivities: [AirSendActivitySummary]
    var activeTransfers: [AirSendTransferSummary]
    var sentHistory: [AirSendTransferSummary]
    var receivedHistory: [AirSendTransferSummary]
    var receivePolicy: String
    var downloadDestination: String
    var mediaDestination: String
    var screenshotWatchFolder: String
    var screenshotWatcherStatus: String
    var historyLimitPerDirection: Int
    var manualPeers: [AirSendManualPeerSummary]
    var trustedPeers: [AirSendTrustedPeerSummary]
    var diagnostics: [AirSendDiagnosticSummary]
    var diagnosticsUpdatedAt: Date?
    var logTail: [String]
}

@MainActor
final class AirSendSettingsStore: ObservableObject {
    struct Actions {
        let setClipboardSyncEnabled: (Bool) -> Void
        let setScreenshotSyncEnabled: (Bool) -> Void
        let setAutoUpdateEnabled: (Bool) -> Void
        let setLaunchAtLoginEnabled: (Bool) -> Void
        let setCompatibilityModeEnabled: (Bool) -> Void
        let sendClipboardNow: () -> Void
        let chooseFilesToSend: () -> Void
        let rescan: () -> Void
        let addDeviceByIP: () -> Void
        let clearDiscoveredDevices: () -> Void
        let resetIdentity: () -> Void
        let checkForUpdates: () -> Void
        let selectBroadcastTarget: () -> Void
        let selectDeviceTarget: (String) -> Void
        let openAndroidRepository: () -> Void
        let runDiagnostics: () -> Void
        let setReceivePolicy: (String) -> Void
        let setHistoryLimitPerDirection: (Int) -> Void
        let trustKnownDevice: () -> Void
        let revokeTrustedPeer: (String) -> Void
        let removeManualPeer: (String) -> Void
        let selectDownloadDestination: () -> Void
        let selectMediaDestination: () -> Void
        let cancelTransfer: (String) -> Void
        let retryTransfer: (String) -> Void
        let deleteHistory: (String) -> Void
        let clearHistory: (String) -> Void
        let previewTransfer: (String, [String]) -> Void
        let revealTransfer: (String) -> Void
        let shareTransfer: (String) -> Void
        let exportLogs: () -> Void
        let clearLogs: () -> Void
        let restartRuntime: () -> Void
    }

    @Published private(set) var snapshot: AirSendSettingsSnapshot
    @Published private(set) var quickLookSelectionID: String?
    let actions: Actions

    init(snapshot: AirSendSettingsSnapshot, actions: Actions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    func update(snapshot: AirSendSettingsSnapshot) {
        self.snapshot = snapshot
    }

    func selectTransferFromQuickLook(_ id: String) {
        quickLookSelectionID = id
    }
}

@MainActor
final class AirSendSettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultSize = NSSize(width: 920, height: 640)
    private static let minimumSize = NSSize(width: 800, height: 520)

    let store: AirSendSettingsStore
    var onWindowVisibilityChanged: ((Bool) -> Void)?
    private let glassContainerView: AirSendSettingsGlassContainerView
    private let hostingView: AirSendSettingsHostingView<AirSendSettingsView>

    init(store: AirSendSettingsStore) {
        self.store = store

        let rootView = AirSendSettingsView(store: store)
        let glassContainerView = AirSendSettingsGlassContainerView()
        let hostingView = AirSendSettingsHostingView(rootView: rootView)
        self.glassContainerView = glassContainerView
        self.hostingView = hostingView
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        glassContainerView.frame = NSRect(origin: .zero, size: Self.defaultSize)
        glassContainerView.autoresizingMask = [.width, .height]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        glassContainerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: glassContainerView.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: glassContainerView.topAnchor),
            hostingView.trailingAnchor.constraint(equalTo: glassContainerView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: glassContainerView.bottomAnchor),
        ])
        window.contentView = glassContainerView
        window.title = "AirSend"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.setContentSize(Self.defaultSize)
        window.toolbarStyle = .unifiedCompact

        super.init(window: window)
        shouldCascadeWindows = false
        self.window?.delegate = self
        self.window?.identifier = NSUserInterfaceItemIdentifier("AirSendSettingsWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettingsWindow() {
        guard let window else { return }
        onWindowVisibilityChanged?(true)
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowVisibilityChanged?(false)
    }
}

private final class AirSendSettingsGlassContainerView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .vibrantDark)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        isEmphasized = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class AirSendSettingsHostingView<Content: View>: NSHostingView<Content> {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        addLayoutGuide(zeroSafeAreaLayoutGuide)
        NSLayoutConstraint.activate([
            zeroSafeAreaLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            zeroSafeAreaLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            zeroSafeAreaLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            zeroSafeAreaLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override var safeAreaRect: NSRect {
        bounds
    }

    override var safeAreaInsets: NSEdgeInsets {
        .init()
    }

    override var safeAreaLayoutGuide: NSLayoutGuide {
        zeroSafeAreaLayoutGuide
    }
}
