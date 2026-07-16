import AirSendUpdater
import Cocoa
import Foundation
import Security

#if canImport(Sparkle) && ENABLE_SPARKLE
import Sparkle
#endif

@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private let updater: any UpdaterProviding
    var onStatusChange: (() -> Void)?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "5.0.0"
    }

    var isUpdateReady: Bool {
        updater.updateStatus.isUpdateReady
    }

    var isAvailable: Bool {
        updater.isAvailable
    }

    var unavailableReason: String? {
        updater.unavailableReason
    }

    private init(updater: (any UpdaterProviding)? = nil) {
        self.updater = updater ?? makeUpdaterController(savedAutoUpdate: Self.savedAutoUpdatePreference)
        self.updater.updateStatus.onChange = { [weak self] in
            self?.onStatusChange?()
        }
    }

    static var savedAutoUpdatePreference: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.autoUpdateDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: Self.autoUpdateDefaultsKey)
    }

    static let autoUpdateDefaultsKey = "auto_update_enabled"

    func configureAutoUpdate(enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
    }

    func checkUpdate(explicit: Bool) {
        guard explicit else {
            return
        }

        guard updater.isAvailable else {
            showUnavailableAlert()
            return
        }

        updater.checkForUpdates(NSApp)
    }

    func installUpdate() {
        guard updater.isAvailable else {
            showUnavailableAlert()
            return
        }

        updater.installUpdate()
    }

    private func showUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Updates Unavailable"
        alert.informativeText = updater.unavailableReason ?? "This build cannot use automatic updates."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

#if canImport(Sparkle) && ENABLE_SPARKLE
@MainActor
private final class SparkleUpdaterController: NSObject, UpdaterProviding, SPUUpdaterDelegate {
    private final class ImmediateInstallHandler: @unchecked Sendable {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        func install() {
            handler()
        }
    }

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private let pendingInstaller = PendingUpdateInstaller()
    let unavailableReason: String? = nil

    var updateStatus: UpdateStatus {
        pendingInstaller.status
    }

    init(savedAutoUpdate: Bool) {
        super.init()
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = savedAutoUpdate
        updater.automaticallyDownloadsUpdates = savedAutoUpdate
        controller.startUpdater()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var isAvailable: Bool {
        true
    }

    func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    func installUpdate() {
        guard pendingInstaller.installIfReady() else {
            controller.checkForUpdates(nil)
            return
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        _ = updater
        _ = item
        _ = error
        Task { @MainActor in
            self.pendingInstaller.clear()
        }
    }

    nonisolated func userDidCancelDownload(_ updater: SPUUpdater) {
        _ = updater
        Task { @MainActor in
            self.pendingInstaller.clear()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        _ = updater
        _ = item
        let installHandler = ImmediateInstallHandler(immediateInstallHandler)
        Task { @MainActor in
            self.pendingInstaller.markReady {
                installHandler.install()
            }
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        _ = updater
        _ = error
        Task { @MainActor in
            self.pendingInstaller.clear()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        _ = updater
        _ = updateItem
        let downloaded = state.stage == .downloaded
        Task { @MainActor in
            switch choice {
            case .install, .skip:
                self.pendingInstaller.clear()
            case .dismiss:
                if !downloaded {
                    self.pendingInstaller.clear()
                }
            @unknown default:
                self.pendingInstaller.clear()
            }
        }
    }
}

private enum InstallOrigin {
    static func isHomebrewCask(appBundleURL: URL) -> Bool {
        let resolved = appBundleURL.resolvingSymlinksInPath()
        let path = resolved.path
        return path.contains("/Caskroom/") || path.contains("/Homebrew/Caskroom/")
    }
}

private func hasCertificateBackedSignature(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode else { return false }

    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return false }
    return !certs.isEmpty
}

@MainActor
private func makeUpdaterController(savedAutoUpdate: Bool) -> any UpdaterProviding {
    let bundleURL = Bundle.main.bundleURL
    let isBundledApp = bundleURL.pathExtension == "app"
    guard isBundledApp else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    if InstallOrigin.isHomebrewCask(appBundleURL: bundleURL) {
        return DisabledUpdaterController(unavailableReason: "Updates are managed by Homebrew for this installation.")
    }

    guard hasCertificateBackedSignature(bundleURL: bundleURL) else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    return SparkleUpdaterController(savedAutoUpdate: savedAutoUpdate)
}
#else
@MainActor
private func makeUpdaterController(savedAutoUpdate: Bool) -> any UpdaterProviding {
    _ = savedAutoUpdate
    return DisabledUpdaterController(unavailableReason: "Sparkle is not available in this build.")
}
#endif
