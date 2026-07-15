import Foundation

public struct TransferArtifactCandidate: Sendable {
    public let fileID: String
    public let fileName: String
    public let sourceURL: URL

    public init(fileID: String, fileName: String, sourceURL: URL) {
        self.fileID = fileID
        self.fileName = fileName
        self.sourceURL = sourceURL
    }
}

public actor TransferArtifactStore {
    public let directoryURL: URL
    private let maximumFileBytes: Int64
    private let maximumTotalBytes: Int64

    public init(
        directoryURL: URL,
        maximumFileBytes: Int64 = 128 * 1_024 * 1_024,
        maximumTotalBytes: Int64 = 1_024 * 1_024 * 1_024
    ) {
        self.directoryURL = directoryURL
        self.maximumFileBytes = max(0, maximumFileBytes)
        self.maximumTotalBytes = max(0, maximumTotalBytes)
    }

    public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AirSend-macOS", isDirectory: true)
            .appendingPathComponent("transfer-artifacts", isDirectory: true)
    }

    public func preserve(
        transferID: UUID,
        candidates: [TransferArtifactCandidate]
    ) throws -> [String: String] {
        let fileManager = FileManager.default
        try prepareRoot(fileManager: fileManager)

        let transferDirectory = directoryURL.appendingPathComponent(transferID.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: transferDirectory)
        try fileManager.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transferDirectory.path)

        var preservedPaths: [String: String] = [:]
        for (index, candidate) in candidates.sorted(by: { $0.fileID < $1.fileID }).enumerated() {
            let values = try candidate.sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  Int64(fileSize) <= maximumFileBytes else {
                continue
            }

            let fileDirectory = transferDirectory.appendingPathComponent(String(index), isDirectory: true)
            try fileManager.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
            let leafName = safeLeafName(candidate.fileName, fallback: candidate.fileID)
            let destinationURL = fileDirectory.appendingPathComponent(leafName, isDirectory: false)
            try fileManager.copyItem(at: candidate.sourceURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            preservedPaths[candidate.fileID] = destinationURL.path
        }

        if preservedPaths.isEmpty {
            try? fileManager.removeItem(at: transferDirectory)
        } else {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: transferDirectory.path)
        }
        try enforceBudget(protecting: [transferID], fileManager: fileManager)
        return preservedPaths
    }

    public func remove(ids: Set<UUID>) throws {
        let fileManager = FileManager.default
        for id in ids {
            try? fileManager.removeItem(
                at: directoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
            )
        }
    }

    public func prune(keeping ids: Set<UUID>) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        for url in try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let id = UUID(uuidString: url.lastPathComponent), ids.contains(id) else {
                try? fileManager.removeItem(at: url)
                continue
            }
        }
        try enforceBudget(protecting: [], fileManager: fileManager)
    }

    private func prepareRoot(fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func enforceBudget(protecting protectedIDs: Set<UUID>, fileManager: FileManager) throws {
        guard maximumTotalBytes > 0, fileManager.fileExists(atPath: directoryURL.path) else { return }
        var directories = try artifactDirectories(fileManager: fileManager)
        var totalBytes = directories.reduce(Int64(0)) { $0 + $1.bytes }
        guard totalBytes > maximumTotalBytes else { return }

        directories.sort { $0.modifiedAt < $1.modifiedAt }
        for directory in directories where totalBytes > maximumTotalBytes {
            if let id = UUID(uuidString: directory.url.lastPathComponent), protectedIDs.contains(id) {
                continue
            }
            try? fileManager.removeItem(at: directory.url)
            totalBytes = max(0, totalBytes - directory.bytes)
        }
    }

    private func artifactDirectories(fileManager: FileManager) throws -> [(url: URL, modifiedAt: Date, bytes: Int64)] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { return nil }
            return (
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                bytes: directorySize(at: url, fileManager: fileManager)
            )
        }
    }

    private func directorySize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func safeLeafName(_ value: String, fallback: String) -> String {
        let leaf = (value as NSString).lastPathComponent
        if !leaf.isEmpty, leaf != ".", leaf != ".." { return leaf }
        let fallbackLeaf = (fallback as NSString).lastPathComponent
        return fallbackLeaf.isEmpty ? "artifact" : fallbackLeaf
    }
}
