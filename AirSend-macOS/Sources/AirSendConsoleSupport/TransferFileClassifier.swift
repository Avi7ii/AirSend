import Foundation

public enum AirSendTransferFileKind: String, Hashable, Sendable {
    case multiple
    case androidPackage
    case image
    case video
    case audio
    case pdf
    case archive
    case presentation
    case spreadsheet
    case wordProcessing
    case html
    case markdown
    case structuredData
    case code
    case text
    case document
    case generic
}

public enum AirSendTransferFileClassifier {
    public static func classify(
        name: String,
        mimeType: String,
        fileCount: Int = 1
    ) -> AirSendTransferFileKind {
        guard fileCount == 1 else { return .multiple }

        let type = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        let fileExtension = components.count > 1 ? String(components.last!).lowercased() : ""

        if type == "application/vnd.android.package-archive" || androidPackageExtensions.contains(fileExtension) {
            return .androidPackage
        }
        if type.hasPrefix("image/") || appleImageTypes.contains(type) || imageExtensions.contains(fileExtension) {
            return .image
        }
        if type.hasPrefix("video/") || appleVideoTypes.contains(type) || videoExtensions.contains(fileExtension) {
            return .video
        }
        if type.hasPrefix("audio/") || appleAudioTypes.contains(type) || audioExtensions.contains(fileExtension) {
            return .audio
        }
        if type == "application/pdf" || type == "com.adobe.pdf" || fileExtension == "pdf" {
            return .pdf
        }
        if archiveTypes.contains(type) || archiveExtensions.contains(fileExtension) {
            return .archive
        }
        if presentationTypes.contains(type) || presentationExtensions.contains(fileExtension) {
            return .presentation
        }
        if spreadsheetTypes.contains(type) || spreadsheetExtensions.contains(fileExtension) {
            return .spreadsheet
        }
        if wordProcessingTypes.contains(type) || wordProcessingExtensions.contains(fileExtension) {
            return .wordProcessing
        }
        if htmlTypes.contains(type) || htmlExtensions.contains(fileExtension) {
            return .html
        }
        if markdownTypes.contains(type) || markdownExtensions.contains(fileExtension) {
            return .markdown
        }
        if structuredDataTypes.contains(type) || type.hasSuffix("+json") || type.hasSuffix("+xml") || structuredDataExtensions.contains(fileExtension) {
            return .structuredData
        }
        if codeTypes.contains(type) || codeExtensions.contains(fileExtension) {
            return .code
        }
        if type.hasPrefix("text/") || appleTextTypes.contains(type) || textExtensions.contains(fileExtension) {
            return .text
        }
        if type.contains("document") || type.contains("presentation") || type.contains("spreadsheet") || documentExtensions.contains(fileExtension) {
            return .document
        }
        return .generic
    }
}

private let androidPackageExtensions: Set<String> = ["apk", "apks", "apkm", "xapk"]

private let imageExtensions: Set<String> = [
    "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp",
]
private let appleImageTypes: Set<String> = [
    "com.compuserve.gif", "com.microsoft.bmp", "org.webmproject.webp", "public.avif", "public.heic",
    "public.heif", "public.jpeg", "public.png", "public.svg-image", "public.tiff",
]

private let videoExtensions: Set<String> = ["3gp", "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm"]
private let appleVideoTypes: Set<String> = [
    "com.apple.quicktime-movie", "public.avi", "public.mpeg", "public.mpeg-4", "public.movie", "public.video",
]

private let audioExtensions: Set<String> = ["aac", "flac", "m4a", "mp3", "ogg", "opus", "wav", "wma"]
private let appleAudioTypes: Set<String> = [
    "com.microsoft.waveform-audio", "public.aac-audio", "public.audio", "public.mp3", "public.mpeg-4-audio",
]

private let archiveExtensions: Set<String> = ["7z", "bz2", "gz", "rar", "tar", "xz", "zip", "zst"]
private let archiveTypes: Set<String> = [
    "application/gzip", "application/vnd.rar", "application/x-7z-compressed", "application/x-tar",
    "application/zip", "com.pkware.zip-archive", "public.archive", "public.zip-archive",
]

private let presentationExtensions: Set<String> = ["key", "keynote", "odp", "ppt", "pptx"]
private let presentationTypes: Set<String> = [
    "application/vnd.apple.keynote", "application/vnd.ms-powerpoint", "application/vnd.oasis.opendocument.presentation",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation", "com.microsoft.powerpoint.ppt",
    "org.openxmlformats.presentationml.presentation",
]

private let spreadsheetExtensions: Set<String> = ["csv", "numbers", "ods", "xls", "xlsx"]
private let spreadsheetTypes: Set<String> = [
    "application/vnd.apple.numbers", "application/vnd.ms-excel", "application/vnd.oasis.opendocument.spreadsheet",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "com.microsoft.excel.xls",
    "org.openxmlformats.spreadsheetml.sheet", "text/csv",
]

private let wordProcessingExtensions: Set<String> = ["doc", "docx", "odt", "pages", "rtf"]
private let wordProcessingTypes: Set<String> = [
    "application/msword", "application/rtf", "application/vnd.apple.pages", "application/vnd.oasis.opendocument.text",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "com.microsoft.word.doc",
    "org.openxmlformats.wordprocessingml.document", "text/rtf",
]

private let htmlExtensions: Set<String> = ["htm", "html", "xhtml"]
private let htmlTypes: Set<String> = ["application/xhtml+xml", "public.html", "text/html"]

private let markdownExtensions: Set<String> = ["markdown", "md", "mdown", "mkdn"]
private let markdownTypes: Set<String> = ["net.daringfireball.markdown", "text/markdown"]

private let structuredDataExtensions: Set<String> = ["json", "jsonl", "toml", "xml", "yaml", "yml"]
private let structuredDataTypes: Set<String> = [
    "application/json", "application/toml", "application/xml", "application/yaml", "public.json", "public.xml",
    "text/json", "text/xml", "text/yaml",
]

private let codeExtensions: Set<String> = [
    "c", "cc", "cpp", "cs", "css", "dart", "go", "h", "hpp", "java", "js", "jsx", "kt", "kts", "lua",
    "php", "py", "rb", "rs", "sh", "sql", "swift", "ts", "tsx",
]
private let codeTypes: Set<String> = ["public.script", "public.shell-script", "public.source-code"]

private let textExtensions: Set<String> = ["ini", "log", "properties", "txt"]
private let appleTextTypes: Set<String> = [
    "public.plain-text", "public.text", "public.utf16-external-plain-text", "public.utf16-plain-text",
    "public.utf8-plain-text",
]

private let documentExtensions: Set<String> = ["epub", "mobi"]
