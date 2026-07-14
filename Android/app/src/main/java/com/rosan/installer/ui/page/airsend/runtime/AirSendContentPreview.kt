// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal sealed interface AirSendContentPreview {
    data class Image(val bitmap: Bitmap) : AirSendContentPreview
    data class Text(val text: String) : AirSendContentPreview
    data object Unavailable : AirSendContentPreview
}

internal suspend fun loadAirSendContentPreview(
    context: Context,
    transfer: AirSendTransferSnapshot
): AirSendContentPreview = withContext(Dispatchers.IO) {
    transfer.previewText
        ?.takeIf(String::isNotBlank)
        ?.let { return@withContext AirSendContentPreview.Text(it) }

    val firstFile = transfer.files.firstOrNull()
        ?: return@withContext AirSendContentPreview.Unavailable
    val kind = classifyAirSendFileKind(
        name = firstFile.name,
        mimeType = firstFile.mimeType,
        fileCount = 1
    )
    val maxBytes = when (kind) {
        AirSendFileKind.Image -> MAX_IMAGE_PREVIEW_BYTES
        AirSendFileKind.Text,
        AirSendFileKind.Html,
        AirSendFileKind.Markdown,
        AirSendFileKind.StructuredData,
        AirSendFileKind.Code -> MAX_TEXT_PREVIEW_BYTES
        else -> return@withContext AirSendContentPreview.Unavailable
    }
    val explicitPaths = (transfer.previewPaths + transfer.savedPaths)
        .filter(String::isNotBlank)
        .distinct()
    val paths = if (explicitPaths.isNotEmpty()) {
        explicitPaths
    } else {
        legacyPreviewPaths(firstFile.name)
    }
    val bytes = paths.firstNotNullOfOrNull { path ->
        readPreviewBytes(context.applicationContext, path, maxBytes)
    } ?: return@withContext AirSendContentPreview.Unavailable

    when (kind) {
        AirSendFileKind.Image -> decodeSampledBitmap(bytes)?.let(AirSendContentPreview::Image)
            ?: AirSendContentPreview.Unavailable
        AirSendFileKind.Text,
        AirSendFileKind.Html,
        AirSendFileKind.Markdown,
        AirSendFileKind.StructuredData,
        AirSendFileKind.Code -> decodeTextPreview(bytes)?.let(AirSendContentPreview::Text)
            ?: AirSendContentPreview.Unavailable
        AirSendFileKind.Multiple,
        AirSendFileKind.AndroidPackage,
        AirSendFileKind.Video,
        AirSendFileKind.Audio,
        AirSendFileKind.Pdf,
        AirSendFileKind.Archive,
        AirSendFileKind.Presentation,
        AirSendFileKind.Spreadsheet,
        AirSendFileKind.WordProcessing,
        AirSendFileKind.Document,
        AirSendFileKind.Generic -> AirSendContentPreview.Unavailable
    }
}

private fun readPreviewBytes(context: Context, path: String, maxBytes: Int): ByteArray? {
    readDirect(path, maxBytes)?.let { return it }
    return readAsRoot(context, path, maxBytes)
}

private fun readDirect(path: String, maxBytes: Int): ByteArray? = runCatching {
    File(path).inputStream().buffered().use { input -> readLimited(input, maxBytes) }
}.getOrNull()?.takeIf(ByteArray::isNotEmpty)

private fun readAsRoot(context: Context, path: String, maxBytes: Int): ByteArray? {
    val output = runCatching {
        File.createTempFile("airsend-preview-", ".bin", context.cacheDir)
    }.getOrNull() ?: return null
    return try {
        val blockSize = if (maxBytes <= MAX_TEXT_PREVIEW_BYTES) maxBytes else ROOT_BLOCK_BYTES
        val blockCount = (maxBytes + blockSize - 1) / blockSize
        val command = "dd if=${shellQuote(path)} bs=$blockSize count=$blockCount 2>/dev/null"
        val process = ProcessBuilder("su", "-c", command)
            .redirectOutput(output)
            .start()
        val finished = process.waitFor(ROOT_READ_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        if (!finished) {
            process.destroyForcibly()
            return null
        }
        if (process.exitValue() != 0) return null
        readDirect(output.path, maxBytes)
    } catch (_: Exception) {
        null
    } finally {
        output.delete()
    }
}

private fun readLimited(input: java.io.InputStream, maxBytes: Int): ByteArray {
    val output = ByteArrayOutputStream(minOf(maxBytes, 64 * 1_024))
    val buffer = ByteArray(16 * 1_024)
    var remaining = maxBytes
    while (remaining > 0) {
        val count = input.read(buffer, 0, minOf(buffer.size, remaining))
        if (count <= 0) break
        output.write(buffer, 0, count)
        remaining -= count
    }
    return output.toByteArray()
}

private fun decodeSampledBitmap(bytes: ByteArray): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

    var sampleSize = 1
    while (bounds.outWidth / sampleSize > MAX_PREVIEW_WIDTH_PX * 2 ||
        bounds.outHeight / sampleSize > MAX_PREVIEW_HEIGHT_PX * 2
    ) {
        sampleSize *= 2
    }
    return BitmapFactory.decodeByteArray(
        bytes,
        0,
        bytes.size,
        BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
    )
}

private fun decodeTextPreview(bytes: ByteArray): String? = runCatching {
    bytes.decodeToString()
        .replace('\u0000', ' ')
        .trim()
        .takeIf(String::isNotEmpty)
}.getOrNull()

private fun legacyPreviewPaths(name: String): List<String> {
    val safeName = File(name).name.takeIf(String::isNotBlank) ?: return emptyList()
    return LEGACY_PREVIEW_DIRECTORIES.map { directory -> "$directory/$safeName" }
}

private fun shellQuote(value: String): String =
    "'" + value.replace("'", "'\"'\"'") + "'"

private val LEGACY_PREVIEW_DIRECTORIES = listOf(
    "/sdcard/Pictures/Screenshots",
    "/sdcard/DCIM/Screenshots",
    "/sdcard/Pictures/AirSend",
    "/sdcard/Download/AirSend",
    "/data/media/0/Pictures/Screenshots",
    "/data/media/0/DCIM/Screenshots",
    "/data/media/0/Pictures/AirSend",
    "/data/media/0/Download/AirSend"
)

private const val MAX_PREVIEW_WIDTH_PX = 1_280
private const val MAX_PREVIEW_HEIGHT_PX = 800
private const val MAX_TEXT_PREVIEW_BYTES = 8 * 1_024
private const val MAX_IMAGE_PREVIEW_BYTES = 32 * 1_024 * 1_024
private const val ROOT_BLOCK_BYTES = 1 * 1_024 * 1_024
private const val ROOT_READ_TIMEOUT_SECONDS = 4L
