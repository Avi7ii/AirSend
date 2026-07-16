import CoreServices
import Foundation
import UniformTypeIdentifiers
import AirSendAutomationSupport

@MainActor
final class ScreenshotWatcher {
    enum State: Equatable {
        case stopped
        case watching(URL)
        case failed(String)
    }

    private var source: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var scanWorkItem: DispatchWorkItem?
    private var seenPaths: [String: Date] = [:]
    private var startedAt = Date.distantFuture
    private var onScreenshot: ((URL) -> Void)?

    private(set) var state: State = .stopped

    deinit {
        source?.cancel()
        if directoryDescriptor >= 0 {
            close(directoryDescriptor)
        }
    }

    func start(directory: URL, onScreenshot: @escaping (URL) -> Void) {
        stop()
        let standardizedDirectory = directory.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedDirectory.path) else {
            state = .failed("Screenshot folder is unavailable")
            return
        }

        let descriptor = open(standardizedDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            state = .failed("Screenshot folder cannot be monitored")
            return
        }

        directoryDescriptor = descriptor
        startedAt = Date()
        self.onScreenshot = onScreenshot
        seedExistingFiles(in: standardizedDirectory)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDirectoryScan(in: standardizedDirectory)
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.directoryDescriptor >= 0 {
                close(self.directoryDescriptor)
                self.directoryDescriptor = -1
            }
        }
        self.source = source
        state = .watching(standardizedDirectory)
        source.resume()
    }

    func stop() {
        scanWorkItem?.cancel()
        scanWorkItem = nil
        source?.cancel()
        source = nil
        onScreenshot = nil
        seenPaths.removeAll(keepingCapacity: false)
        state = .stopped
    }

    static func defaultCaptureDirectory(fileManager: FileManager = .default) -> URL {
        if let configured = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture")?["location"] as? String,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func seedExistingFiles(in directory: URL) {
        for url in imageFiles(in: directory) {
            seenPaths[url.standardizedFileURL.path] = fileDate(url)
        }
        pruneSeenPaths()
    }

    private func scheduleDirectoryScan(in directory: URL) {
        scanWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.scanDirectory(directory)
        }
        scanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func scanDirectory(_ directory: URL) {
        scanWorkItem = nil
        let candidates = imageFiles(in: directory)
            .filter { fileDate($0) >= startedAt.addingTimeInterval(-1) }
            .filter { seenPaths[$0.standardizedFileURL.path] == nil }
            .filter(Self.looksLikeScreenshot)
            .sorted { fileDate($0) < fileDate($1) }

        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            seenPaths[path] = fileDate(candidate)
            verifyStableFile(candidate)
        }
        pruneSeenPaths()
    }

    private func verifyStableFile(_ url: URL) {
        let firstSize = fileSize(url)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let path = url.path
            let secondSize = await Task.detached(priority: .utility) {
                Self.fileSizeAtPath(path)
            }.value
            guard let self,
                  firstSize > 0,
                  firstSize == secondSize,
                  FileManager.default.fileExists(atPath: path) else { return }
            self.onScreenshot?(url)
        }
    }

    private func imageFiles(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey, .contentModificationDateKey, .creationDateKey]
        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ))?.filter { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return false }
            return values.contentType?.conforms(to: .image) == true
        } ?? []
    }

    private static func looksLikeScreenshot(_ url: URL) -> Bool {
        if let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
           let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool,
           value {
            return true
        }
        return ScreenshotNameClassifier.isLikelyScreenshotFilename(url.lastPathComponent)
    }

    private func fileDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate ?? .distantPast
    }

    private func fileSize(_ url: URL) -> Int64 {
        Self.fileSizeAtPath(url.path)
    }

    nonisolated private static func fileSizeAtPath(_ path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func pruneSeenPaths() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        seenPaths = seenPaths.filter { $0.value >= cutoff }
        if seenPaths.count > 512 {
            let newest = seenPaths.sorted { $0.value > $1.value }.prefix(512)
            seenPaths = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }
}
