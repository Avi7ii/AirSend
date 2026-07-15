import Cocoa
import UniformTypeIdentifiers

enum LocalFileDrag {
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        legacyFilenamesType
    ]
    @MainActor private static var cachedURLs: [URL] = []
    @MainActor private static var cacheDate: Date?
    private static let cacheMaxAge: TimeInterval = 1.2
    private static let suspiciousRichContentTypes: Set<String> = [
        NSPasteboard.PasteboardType.URL.rawValue,
        NSPasteboard.PasteboardType.string.rawValue,
        NSPasteboard.PasteboardType.html.rawValue,
        NSPasteboard.PasteboardType.rtf.rawValue,
        NSPasteboard.PasteboardType.rtfd.rawValue,
        NSPasteboard.PasteboardType.tiff.rawValue,
        "public.url",
        "public.url-name",
        "public.html",
        "public.rtf",
        "public.utf8-plain-text",
        "public.utf16-external-plain-text",
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.webp",
        "Apple Web Archive pasteboard type",
        "com.apple.webarchive",
        "com.apple.flat-rtfd",
        "com.apple.cocoa.pasteboard.promised-file-content-type",
        "org.chromium.image-url"
    ]

    struct Inspection {
        let urls: [URL]
        let looksLikeStrictLocalFileDrag: Bool
        let typeNames: Set<String>
        let hasLegacyFinderFileList: Bool
        let hasSuspiciousRichContentMarkers: Bool
    }

    struct MetadataEvidence {
        let hasFileRelatedType: Bool
        let hasLegacyFinderFileList: Bool
        let hasSuspiciousRichContentMarkers: Bool

        var canBeLocalFileDrag: Bool {
            hasFileRelatedType && (hasLegacyFinderFileList || !hasSuspiciousRichContentMarkers)
        }
    }

    static func metadataEvidence(from pasteboard: NSPasteboard) -> MetadataEvidence {
        let typeNames = pasteboardTypeNames(from: pasteboard)
        let hasLegacyFinderFileList = typeNames.contains(legacyFilenamesType.rawValue)
            || (pasteboard.propertyList(forType: legacyFilenamesType) as? [String])?.isEmpty == false
        let hasFileRelatedType = typeNames.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
            || hasLegacyFinderFileList
            || typeNames.contains { typeName in
                UTType(typeName)?.conforms(to: .fileURL) == true
            }
        return MetadataEvidence(
            hasFileRelatedType: hasFileRelatedType,
            hasLegacyFinderFileList: hasLegacyFinderFileList,
            hasSuspiciousRichContentMarkers: !typeNames.isDisjoint(with: suspiciousRichContentTypes)
        )
    }

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

    static func inspectLocalFileDrag(from pasteboard: NSPasteboard) -> Inspection {
        let urls = validLocalFileURLs(from: pasteboard)
        let typeNames = pasteboardTypeNames(from: pasteboard)
        let hasLegacyFinderFileList = typeNames.contains(legacyFilenamesType.rawValue)
            || (pasteboard.propertyList(forType: legacyFilenamesType) as? [String])?.isEmpty == false
        let hasSuspiciousRichContentMarkers = !typeNames.isDisjoint(with: suspiciousRichContentTypes)
        let hasEphemeralPaths = urls.contains { isEphemeralDragURL($0) }
        let looksLikeStrictLocalFileDrag = !urls.isEmpty
            && !hasEphemeralPaths
            && (hasLegacyFinderFileList || !hasSuspiciousRichContentMarkers)

        return Inspection(
            urls: urls,
            looksLikeStrictLocalFileDrag: looksLikeStrictLocalFileDrag,
            typeNames: typeNames,
            hasLegacyFinderFileList: hasLegacyFinderFileList,
            hasSuspiciousRichContentMarkers: hasSuspiciousRichContentMarkers
        )
    }

    static func recognizedLocalFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let inspection = inspectLocalFileDrag(from: pasteboard)
        return inspection.looksLikeStrictLocalFileDrag ? inspection.urls : []
    }

    static func containsValidLocalFiles(in pasteboard: NSPasteboard) -> Bool {
        !recognizedLocalFileURLs(from: pasteboard).isEmpty
    }

    @MainActor
    static func stageValidLocalFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = recognizedLocalFileURLs(from: pasteboard)
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
        let inspection = inspectLocalFileDrag(from: pasteboard)
        let itemSummaries = (pasteboard.pasteboardItems ?? []).enumerated().prefix(4).map { index, item in
            let types = item.types.map(\.rawValue).joined(separator: ",")
            return "[\(index):\(types)]"
        }
        let firstItemTypes = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")
        return "items=\(pasteboard.pasteboardItems?.count ?? 0) changeCount=\(pasteboard.changeCount) strict=\(inspection.looksLikeStrictLocalFileDrag) urls=\(inspection.urls.count) legacy=\(inspection.hasLegacyFinderFileList) rich=\(inspection.hasSuspiciousRichContentMarkers) first=\(firstItemTypes) \(itemSummaries.joined(separator: " "))"
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

    private static func pasteboardTypeNames(from pasteboard: NSPasteboard) -> Set<String> {
        var result = Set((pasteboard.types ?? []).map(\.rawValue))
        for item in pasteboard.pasteboardItems ?? [] {
            result.formUnion(item.types.map(\.rawValue))
        }
        return result
    }

    private static func isEphemeralDragURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        let homeCachesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .standardizedFileURL.path

        return path.hasPrefix(temporaryRoot)
            || path.hasPrefix("/private/var/folders/")
            || path.hasPrefix(homeCachesRoot)
            || path.contains("/TemporaryItems/")
            || path.contains("/com.apple.WebKit/")
            || path.contains("/Google/Chrome/")
            || path.contains("/Microsoft Edge/")
            || path.contains("/Firefox/Profiles/")
    }
}
