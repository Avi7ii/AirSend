// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

internal enum class AirSendFileKind {
    Multiple,
    AndroidPackage,
    Image,
    Video,
    Audio,
    Pdf,
    Archive,
    Presentation,
    Spreadsheet,
    WordProcessing,
    Html,
    Markdown,
    StructuredData,
    Code,
    Text,
    Document,
    Generic
}

internal fun classifyAirSendFileKind(
    name: String,
    mimeType: String,
    fileCount: Int = 1
): AirSendFileKind {
    if (fileCount != 1) return AirSendFileKind.Multiple

    val type = mimeType.trim().lowercase()
    val extension = name.substringAfterLast('.', missingDelimiterValue = "").lowercase()
    return when {
        type == "application/vnd.android.package-archive" ||
            extension in androidPackageExtensions -> AirSendFileKind.AndroidPackage
        type.startsWith("image/") || type in appleImageTypes ||
            extension in imageExtensions -> AirSendFileKind.Image
        type.startsWith("video/") || type in appleVideoTypes ||
            extension in videoExtensions -> AirSendFileKind.Video
        type.startsWith("audio/") || type in appleAudioTypes ||
            extension in audioExtensions -> AirSendFileKind.Audio
        type == "application/pdf" || type == "com.adobe.pdf" ||
            extension == "pdf" -> AirSendFileKind.Pdf
        type in archiveTypes || extension in archiveExtensions -> AirSendFileKind.Archive
        type in presentationTypes || extension in presentationExtensions ->
            AirSendFileKind.Presentation
        type in spreadsheetTypes || extension in spreadsheetExtensions ->
            AirSendFileKind.Spreadsheet
        type in wordProcessingTypes || extension in wordProcessingExtensions ->
            AirSendFileKind.WordProcessing
        type in htmlTypes || extension in htmlExtensions -> AirSendFileKind.Html
        type in markdownTypes || extension in markdownExtensions -> AirSendFileKind.Markdown
        type in structuredDataTypes || type.endsWith("+json") || type.endsWith("+xml") ||
            extension in structuredDataExtensions -> AirSendFileKind.StructuredData
        type in codeTypes || extension in codeExtensions -> AirSendFileKind.Code
        type.startsWith("text/") || type in appleTextTypes ||
            extension in textExtensions -> AirSendFileKind.Text
        type.contains("document") || type.contains("presentation") ||
            type.contains("spreadsheet") || extension in documentExtensions -> AirSendFileKind.Document
        else -> AirSendFileKind.Generic
    }
}

private val androidPackageExtensions = setOf("apk", "apks", "apkm", "xapk")

private val imageExtensions = setOf(
    "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp"
)
private val appleImageTypes = setOf(
    "com.compuserve.gif",
    "com.microsoft.bmp",
    "org.webmproject.webp",
    "public.avif",
    "public.heic",
    "public.heif",
    "public.jpeg",
    "public.png",
    "public.svg-image",
    "public.tiff"
)

private val videoExtensions = setOf("3gp", "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm")
private val appleVideoTypes = setOf(
    "com.apple.quicktime-movie",
    "public.avi",
    "public.mpeg",
    "public.mpeg-4",
    "public.movie",
    "public.video"
)

private val audioExtensions = setOf("aac", "flac", "m4a", "mp3", "ogg", "opus", "wav", "wma")
private val appleAudioTypes = setOf(
    "com.microsoft.waveform-audio",
    "public.aac-audio",
    "public.audio",
    "public.mp3",
    "public.mpeg-4-audio"
)

private val archiveExtensions = setOf("7z", "bz2", "gz", "rar", "tar", "xz", "zip", "zst")
private val archiveTypes = setOf(
    "application/gzip",
    "application/vnd.rar",
    "application/x-7z-compressed",
    "application/x-tar",
    "application/zip",
    "com.pkware.zip-archive",
    "public.archive",
    "public.zip-archive"
)

private val presentationExtensions = setOf("key", "keynote", "odp", "ppt", "pptx")
private val presentationTypes = setOf(
    "application/vnd.apple.keynote",
    "application/vnd.ms-powerpoint",
    "application/vnd.oasis.opendocument.presentation",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "com.microsoft.powerpoint.ppt",
    "org.openxmlformats.presentationml.presentation"
)

private val spreadsheetExtensions = setOf("csv", "numbers", "ods", "xls", "xlsx")
private val spreadsheetTypes = setOf(
    "application/vnd.apple.numbers",
    "application/vnd.ms-excel",
    "application/vnd.oasis.opendocument.spreadsheet",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "com.microsoft.excel.xls",
    "org.openxmlformats.spreadsheetml.sheet",
    "text/csv"
)

private val wordProcessingExtensions = setOf("doc", "docx", "odt", "pages", "rtf")
private val wordProcessingTypes = setOf(
    "application/msword",
    "application/rtf",
    "application/vnd.apple.pages",
    "application/vnd.oasis.opendocument.text",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "com.microsoft.word.doc",
    "org.openxmlformats.wordprocessingml.document",
    "text/rtf"
)

private val htmlExtensions = setOf("htm", "html", "xhtml")
private val htmlTypes = setOf("application/xhtml+xml", "public.html", "text/html")

private val markdownExtensions = setOf("markdown", "md", "mdown", "mkdn")
private val markdownTypes = setOf("net.daringfireball.markdown", "text/markdown")

private val structuredDataExtensions = setOf("json", "jsonl", "toml", "xml", "yaml", "yml")
private val structuredDataTypes = setOf(
    "application/json",
    "application/toml",
    "application/xml",
    "application/yaml",
    "public.json",
    "public.xml",
    "text/json",
    "text/xml",
    "text/yaml"
)

private val codeExtensions = setOf(
    "c", "cc", "cpp", "cs", "css", "dart", "go", "h", "hpp", "java", "js", "jsx",
    "kt", "kts", "lua", "php", "py", "rb", "rs", "sh", "sql", "swift", "ts", "tsx"
)
private val codeTypes = setOf("public.script", "public.shell-script", "public.source-code")

private val textExtensions = setOf("ini", "log", "properties", "txt")
private val appleTextTypes = setOf(
    "public.plain-text",
    "public.text",
    "public.utf16-external-plain-text",
    "public.utf16-plain-text",
    "public.utf8-plain-text"
)

private val documentExtensions = setOf(
    "epub", "mobi"
)
