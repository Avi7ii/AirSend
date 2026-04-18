import Foundation

@Sendable
func logTransfer(_ message: String) {
    FileLogger.log(message)
}

enum FileLogger {
    private static let store = FileLogStore.shared

    static func bootstrap() {
        Task(priority: .background) {
            await store.bootstrap()
        }
    }
    static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        print(logMessage, terminator: "")

        Task(priority: .background) {
            await store.persist(logMessage)
        }
    }
}

private actor FileLogStore {
    static let shared = FileLogStore()

    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    private let appSupportURL: URL
    private let logDirectoryURL: URL
    private let currentLogURL: URL
    private let legacyLogURL: URL
    private let logVersionDefaultsKey = "airsend.logger.last_app_version"
    private let maxCurrentLogBytes = 2 * 1024 * 1024
    private let maxTotalLogBytes = 8 * 1024 * 1024
    private let maxArchivedLogs = 5
    private let cleanupInterval: TimeInterval = 6 * 60 * 60
    private let retentionInterval: TimeInterval = 14 * 24 * 60 * 60

    private var didPrepareStorage = false
    private var lastCleanupAt: Date = .distantPast

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AirSend-macOS", isDirectory: true)
        self.appSupportURL = appSupport
        self.logDirectoryURL = appSupport.appendingPathComponent(".logs", isDirectory: true)
        self.currentLogURL = logDirectoryURL.appendingPathComponent(".airsend.log", isDirectory: false)
        self.legacyLogURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("AirSend.log", isDirectory: false)
    }

    func bootstrap() {
        prepareStorageIfNeeded()
        rotateCurrentLogIfNeeded()
        cleanupLogsIfNeeded(force: true)
    }

    func persist(_ message: String) {
        prepareStorageIfNeeded()
        append(data: Data(message.utf8), to: currentLogURL)
        rotateCurrentLogIfNeeded()
        cleanupLogsIfNeeded(force: false)
    }

    private func prepareStorageIfNeeded() {
        guard !didPrepareStorage else { return }

        do {
            try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            try resetLogsIfVersionChanged()

            if !fileManager.fileExists(atPath: currentLogURL.path) {
                try migrateLegacyLogIfNeeded()
            }

            if !fileManager.fileExists(atPath: currentLogURL.path) {
                fileManager.createFile(
                    atPath: currentLogURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }

            didPrepareStorage = true
        } catch {
            fputs("AirSend logger setup failed: \(error)\n", stderr)
        }
    }

    private func resetLogsIfVersionChanged() throws {
        guard let currentVersion = currentAppVersion else { return }

        let previousVersion = defaults.string(forKey: logVersionDefaultsKey)
        defer {
            defaults.set(currentVersion, forKey: logVersionDefaultsKey)
        }

        guard let previousVersion else { return }
        guard previousVersion != currentVersion else { return }

        for file in existingLogFiles() {
            try? fileManager.removeItem(at: file)
        }

        if fileManager.fileExists(atPath: legacyLogURL.path) {
            try? fileManager.removeItem(at: legacyLogURL)
        }
    }

    private func migrateLegacyLogIfNeeded() throws {
        guard fileManager.fileExists(atPath: legacyLogURL.path) else { return }

        if !fileManager.fileExists(atPath: currentLogURL.path) {
            try fileManager.moveItem(at: legacyLogURL, to: currentLogURL)
            return
        }

        let legacyData = try Data(contentsOf: legacyLogURL)
        if !legacyData.isEmpty {
            append(data: legacyData, to: currentLogURL)
        }

        try? fileManager.removeItem(at: legacyLogURL)
    }

    private func append(data: Data, to url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fputs("AirSend logger write failed: \(error)\n", stderr)
        }
    }

    private func rotateCurrentLogIfNeeded() {
        guard let fileSize = fileSize(of: currentLogURL), fileSize > maxCurrentLogBytes else { return }

        let archiveURL = nextArchiveURL()
        do {
            if fileManager.fileExists(atPath: archiveURL.path) {
                try fileManager.removeItem(at: archiveURL)
            }
            try fileManager.moveItem(at: currentLogURL, to: archiveURL)
            fileManager.createFile(
                atPath: currentLogURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        } catch {
            fputs("AirSend logger rotation failed: \(error)\n", stderr)
        }
    }

    private func cleanupLogsIfNeeded(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastCleanupAt) >= cleanupInterval else { return }
        lastCleanupAt = now

        var logFiles = existingLogFiles()
        let expirationDate = now.addingTimeInterval(-retentionInterval)

        for file in logFiles where file != currentLogURL {
            let modifiedAt = fileTimestamp(for: file) ?? .distantPast
            if modifiedAt < expirationDate {
                try? fileManager.removeItem(at: file)
            }
        }

        var archivedLogs = existingLogFiles()
            .filter { $0 != currentLogURL }
            .sorted(by: oldestFirst)

        while archivedLogs.count > maxArchivedLogs {
            let file = archivedLogs.removeFirst()
            try? fileManager.removeItem(at: file)
        }

        logFiles = existingLogFiles()
        var totalBytes = logFiles.reduce(0) { $0 + (fileSize(of: $1) ?? 0) }
        archivedLogs = logFiles.filter { $0 != currentLogURL }.sorted(by: oldestFirst)

        while totalBytes > maxTotalLogBytes, let oldest = archivedLogs.first {
            let removedBytes = fileSize(of: oldest) ?? 0
            try? fileManager.removeItem(at: oldest)
            archivedLogs.removeFirst()
            totalBytes = max(0, totalBytes - removedBytes)
        }
    }

    private func existingLogFiles() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []
    }

    private func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private func fileTimestamp(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate
    }

    private func oldestFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        (fileTimestamp(for: lhs) ?? .distantPast) < (fileTimestamp(for: rhs) ?? .distantPast)
    }

    private func nextArchiveURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let stamp = formatter.string(from: Date())
        var candidate = logDirectoryURL.appendingPathComponent(".airsend-\(stamp).log", isDirectory: false)
        var suffix = 1

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = logDirectoryURL.appendingPathComponent(".airsend-\(stamp)-\(suffix).log", isDirectory: false)
            suffix += 1
        }

        return candidate
    }

    private var currentAppVersion: String? {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let shortVersion, let buildVersion, !buildVersion.isEmpty, buildVersion != shortVersion {
            return "\(shortVersion) (\(buildVersion))"
        }

        return shortVersion ?? buildVersion
    }
}
