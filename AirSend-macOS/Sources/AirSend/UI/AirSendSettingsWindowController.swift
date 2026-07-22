import Cocoa
import AirSendConsoleSupport
import Darwin
import SwiftUI

extension Notification.Name {
    static let airSendSettingsEntranceDidSettle = Notification.Name(
        "AirSendSettingsEntranceDidSettle"
    )
}

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

struct AirSendSettingsSnapshot: Equatable {
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
        let setLanguage: (String) -> Void
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
        let previewTransfer: (String, [String], [String: AirSendQuickLookAnchor]) -> Void
        let revealTransfer: (String) -> Void
        let shareTransfer: (String) -> Void
        let exportLogs: () -> Void
        let clearLogs: () -> Void
        let restartRuntime: () -> Void
    }

    @Published private(set) var snapshot: AirSendSettingsSnapshot
    @Published private(set) var quickLookSelectionID: String?
    @Published private(set) var isWindowPresented = false
    let actions: Actions

    init(snapshot: AirSendSettingsSnapshot, actions: Actions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    func update(snapshot: AirSendSettingsSnapshot, forceRefresh: Bool = false) {
        guard snapshot != self.snapshot else {
            if forceRefresh {
                objectWillChange.send()
            }
            return
        }
        self.snapshot = snapshot
    }

    func selectTransferFromQuickLook(_ id: String) {
        quickLookSelectionID = id
    }

    func setWindowPresented(_ isPresented: Bool) {
        isWindowPresented = isPresented
    }
}

@MainActor
final class AirSendSettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultSize = NSSize(width: 920, height: 640)
    private static let minimumSize = NSSize(width: 800, height: 520)
    private static let backgroundBlurRadius: Int32 = 50

    let store: AirSendSettingsStore
    var onWindowVisibilityChanged: ((Bool) -> Void)?
    var onWindowRenderingActivityChanged: ((Bool) -> Void)?
    private let glassContainer: AirSendSettingsGlassContainer
    private let hostingView: AirSendSettingsHostingView<AirSendSettingsView>
    private var didConfigureWindowBackgroundBlur = false

    init(store: AirSendSettingsStore) {
        self.store = store

        let rootView = AirSendSettingsView(store: store)
        let glassContainer = AirSendSettingsGlassContainer()
        let hostingView = AirSendSettingsHostingView(rootView: rootView)
        self.glassContainer = glassContainer
        self.hostingView = hostingView
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        glassContainer.rootView.frame = NSRect(origin: .zero, size: Self.defaultSize)
        glassContainer.rootView.autoresizingMask = [.width, .height]
        glassContainer.installContentView(hostingView)
        window.contentView = glassContainer.rootView
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsEntranceDidSettle(_:)),
            name: .airSendSettingsEntranceDidSettle,
            object: nil
        )
        configureWindowBackgroundBlurIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettingsWindow() {
        guard let window else { return }
        configureWindowBackgroundBlurIfNeeded()
        hostingView.setSettledRasterizationEnabled(
            false,
            scale: window.backingScaleFactor
        )
        store.setWindowPresented(true)
        onWindowVisibilityChanged?(true)
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        reportRenderingActivity()
    }

    func windowWillClose(_ notification: Notification) {
        store.setWindowPresented(false)
        onWindowRenderingActivityChanged?(false)
        onWindowVisibilityChanged?(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        reportRenderingActivity()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        reportRenderingActivity()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        reportRenderingActivity()
    }

    var isActivelyRenderingContent: Bool {
        guard let window else { return false }
        return window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    private func reportRenderingActivity() {
        onWindowRenderingActivityChanged?(isActivelyRenderingContent)
    }

    private func configureWindowBackgroundBlurIfNeeded() {
        guard glassContainer.usesWindowLevelBackgroundBlur,
              !didConfigureWindowBackgroundBlur,
              let window,
              AirSendWindowBackgroundBlur.apply(
                to: window,
                radius: Self.backgroundBlurRadius
              ) else {
            return
        }

        didConfigureWindowBackgroundBlur = true
        window.backgroundColor = .clear
        glassContainer.useWindowLevelBackgroundBlur()
    }

    @objc private func settingsEntranceDidSettle(_ notification: Notification) {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(neutralizeSettledEntranceBlurFilters),
            object: nil
        )
        perform(
            #selector(neutralizeSettledEntranceBlurFilters),
            with: nil,
            afterDelay: 0.12
        )
    }

    @objc private func neutralizeSettledEntranceBlurFilters() {
        hostingView.neutralizeSettledEntranceBlurFilters()
        guard let window else { return }
        hostingView.setSettledRasterizationEnabled(
            true,
            scale: window.backingScaleFactor
        )
    }
}

@MainActor
private final class AirSendSettingsGlassContainer {
    private let containerView: NSView
    private let materialView: NSView
    private let foregroundView: NSView
    let usesWindowLevelBackgroundBlur: Bool

    var rootView: NSView {
        containerView
    }

    init() {
        let containerView = NSView(frame: .zero)
        let foregroundView = NSView(frame: .zero)

        let systemMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if #available(macOS 26.0, *), systemMajorVersion == 26 {
            let glassView = NSGlassEffectView()
            glassView.appearance = NSAppearance(named: .vibrantDark)
            glassView.style = .regular
            glassView.cornerRadius = 18
            glassView.tintColor = nil
            glassView.wantsLayer = true
            materialView = glassView
            usesWindowLevelBackgroundBlur = false
        } else {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.appearance = NSAppearance(named: .vibrantDark)
            visualEffectView.material = .hudWindow
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.state = .active
            visualEffectView.isEmphasized = false
            visualEffectView.wantsLayer = true
            materialView = visualEffectView
            usesWindowLevelBackgroundBlur = true
        }

        self.containerView = containerView
        self.foregroundView = foregroundView

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.isOpaque = false

        materialView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(materialView)

        foregroundView.translatesAutoresizingMaskIntoConstraints = false
        foregroundView.wantsLayer = true
        foregroundView.layer?.backgroundColor = NSColor.clear.cgColor
        foregroundView.layer?.isOpaque = false
        containerView.addSubview(foregroundView, positioned: .above, relativeTo: materialView)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            materialView.topAnchor.constraint(equalTo: containerView.topAnchor),
            materialView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            materialView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            foregroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            foregroundView.topAnchor.constraint(equalTo: containerView.topAnchor),
            foregroundView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            foregroundView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    func installContentView(_ contentView: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        foregroundView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: foregroundView.leadingAnchor),
            contentView.topAnchor.constraint(equalTo: foregroundView.topAnchor),
            contentView.trailingAnchor.constraint(equalTo: foregroundView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: foregroundView.bottomAnchor),
        ])
    }

    func useWindowLevelBackgroundBlur() {
        guard let visualEffectView = materialView as? NSVisualEffectView else { return }
        visualEffectView.blendingMode = .withinWindow
    }
}

@MainActor
private enum AirSendWindowBackgroundBlur {
    private typealias DefaultConnectionFunction = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias SetBlurFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        Int,
        Int32
    ) -> Int32

    private struct Functions {
        let defaultConnection: DefaultConnectionFunction
        let setBlur: SetBlurFunction
    }

    private static let functions: Functions? = {
        let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL),
              let defaultConnectionSymbol = dlsym(handle, "CGSDefaultConnectionForThread"),
              let setBlurSymbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else {
            return nil
        }

        return Functions(
            defaultConnection: unsafeBitCast(
                defaultConnectionSymbol,
                to: DefaultConnectionFunction.self
            ),
            setBlur: unsafeBitCast(
                setBlurSymbol,
                to: SetBlurFunction.self
            )
        )
    }()

    static func apply(to window: NSWindow, radius: Int32) -> Bool {
        guard let functions,
              let connection = functions.defaultConnection() else {
            return false
        }

        return functions.setBlur(connection, window.windowNumber, radius) == 0
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

    func neutralizeSettledEntranceBlurFilters() {
        guard let layer else { return }

        var neutralizedCount = 0
        func visit(_ currentLayer: CALayer) {
            for filter in currentLayer.filters ?? [] {
                guard String(describing: filter) == "gaussianBlur",
                      let filterObject = filter as? NSObject,
                      let radius = filterObject.value(forKey: "inputRadius") as? NSNumber,
                      radius.doubleValue > 0,
                      radius.doubleValue <= 0.01 else {
                    continue
                }
                filterObject.setValue(0.0, forKey: "inputRadius")
                neutralizedCount += 1
            }
            currentLayer.sublayers?.forEach(visit)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        visit(layer)
        CATransaction.commit()

        if neutralizedCount > 0 {
            NSLog(
                "AirSend settings compositor: neutralized %d settled entrance blur filters",
                neutralizedCount
            )
        }
    }

    func setSettledRasterizationEnabled(_ isEnabled: Bool, scale: CGFloat) {
        guard let layer else { return }
        layer.shouldRasterize = isEnabled
        layer.rasterizationScale = max(scale, 1)
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
