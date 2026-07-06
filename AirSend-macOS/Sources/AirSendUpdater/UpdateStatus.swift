import Foundation

@MainActor
public final class UpdateStatus {
    public var onChange: (() -> Void)?
    public var isUpdateReady: Bool {
        didSet {
            guard oldValue != isUpdateReady else { return }
            onChange?()
        }
    }

    public init(isUpdateReady: Bool = false) {
        self.isUpdateReady = isUpdateReady
    }
}

@MainActor
public final class PendingUpdateInstaller {
    public let status: UpdateStatus
    private var installHandler: (() -> Void)?

    public var onChange: (() -> Void)? {
        get { status.onChange }
        set { status.onChange = newValue }
    }

    public var isUpdateReady: Bool {
        status.isUpdateReady
    }

    public init(status: UpdateStatus = UpdateStatus()) {
        self.status = status
    }

    public func markReady(_ handler: @escaping () -> Void) {
        installHandler = handler
        status.isUpdateReady = true
    }

    public func clear() {
        guard installHandler != nil || status.isUpdateReady else { return }
        installHandler = nil
        status.isUpdateReady = false
    }

    @discardableResult
    public func installIfReady() -> Bool {
        guard let installHandler else { return false }
        installHandler()
        return true
    }
}

@MainActor
public protocol UpdaterProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    var updateStatus: UpdateStatus { get }

    func checkForUpdates(_ sender: Any?)
    func installUpdate()
}

@MainActor
public final class DisabledUpdaterController: UpdaterProviding {
    public var automaticallyChecksForUpdates = false
    public var automaticallyDownloadsUpdates = false
    public let isAvailable = false
    public let unavailableReason: String?
    public let updateStatus = UpdateStatus()

    public init(unavailableReason: String? = nil) {
        self.unavailableReason = unavailableReason
    }

    public func checkForUpdates(_ sender: Any?) {}
    public func installUpdate() {}
}
