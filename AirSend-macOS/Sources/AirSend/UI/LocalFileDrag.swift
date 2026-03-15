import Cocoa

enum LocalFileDrag {
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        legacyFilenamesType
    ]
    @MainActor private static var cachedURLs: [URL] = []
    @MainActor private static var cacheDate: Date?
    private static let cacheMaxAge: TimeInterval = 5

    static func validLocalFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard containsSupportedFileType(in: pasteboard) else { return [] }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            let filtered = filterExistingLocalFileURLs(urls)
            if !filtered.isEmpty {
                return filtered
            }
        }

        if let paths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] {
            return filterExistingLocalFileURLs(paths.map { URL(fileURLWithPath: $0) })
        }

        return []
    }

    static func containsValidLocalFiles(in pasteboard: NSPasteboard) -> Bool {
        !validLocalFileURLs(from: pasteboard).isEmpty
    }

    @MainActor
    static func stageValidLocalFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = validLocalFileURLs(from: pasteboard)
        if !urls.isEmpty {
            cachedURLs = urls
            cacheDate = Date()
        }
        return urls
    }

    @MainActor
    static func stagedOrCurrentLocalFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let current = stageValidLocalFileURLs(from: pasteboard)
        if !current.isEmpty {
            return current
        }

        guard let cacheDate, Date().timeIntervalSince(cacheDate) <= cacheMaxAge else {
            clearCachedDragPayload()
            return []
        }

        let cached = filterExistingLocalFileURLs(cachedURLs)
        if cached.isEmpty {
            clearCachedDragPayload()
        }
        return cached
    }

    @MainActor
    static func clearCachedDragPayload() {
        cachedURLs = []
        cacheDate = nil
    }

    static func filterExistingLocalFileURLs(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private static func containsSupportedFileType(in pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(.fileURL) || types.contains(legacyFilenamesType)
    }
}
