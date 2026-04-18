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
        var candidateURLs: [URL] = []
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            candidateURLs.append(contentsOf: urls)
        }

        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let type = item.availableType(from: [.fileURL]),
                   let rawValue = item.string(forType: type),
                   let url = URL(string: rawValue) {
                    candidateURLs.append(url)
                }

                if let type = item.availableType(from: [legacyFilenamesType]),
                   let rawPath = item.string(forType: type),
                   !rawPath.isEmpty {
                    candidateURLs.append(URL(fileURLWithPath: rawPath))
                }
            }
        }

        if let paths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] {
            candidateURLs.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }

        let deduped = dedupeFileURLs(candidateURLs)
        return filterExistingLocalFileURLs(deduped)
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

    static func debugSummary(from pasteboard: NSPasteboard) -> String {
        let itemSummaries = (pasteboard.pasteboardItems ?? []).enumerated().prefix(4).map { index, item in
            let types = item.types.map(\.rawValue).joined(separator: ",")
            return "[\(index):\(types)]"
        }
        let firstItemTypes = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")
        return "items=\(pasteboard.pasteboardItems?.count ?? 0) first=\(firstItemTypes) \(itemSummaries.joined(separator: " "))"
    }

    static func filterExistingLocalFileURLs(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private static func dedupeFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }
}
