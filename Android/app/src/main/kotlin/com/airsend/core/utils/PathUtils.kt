package com.airsend.core.utils

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import java.io.File
import java.io.FileOutputStream

object PathUtils {
    private const val TAG = "PathUtils"

    /**
     * 核心方法：尝试将 content:// URI 转换为物理文件路径
     */
    fun getRealPathFromURI(context: Context, uri: Uri): String? {
        Log.d(TAG, "Attempting to resolve URI: $uri (Scheme: ${uri.scheme}, Authority: ${uri.authority})")

        // 1. 如果本来就是 file:// 协议，直接返回
        if ("file".equals(uri.scheme, ignoreCase = true)) {
            return uri.path
        }

        // 2. 如果是 content:// 协议
        if ("content".equals(uri.scheme, ignoreCase = true)) {
            
            // A. 判断是否为 DocumentsContract URI (Android 4.4+)
            if (DocumentsContract.isDocumentUri(context, uri)) {
                // ExternalStorageProvider
                if (isExternalStorageDocument(uri)) {
                    val docId = DocumentsContract.getDocumentId(uri)
                    val split = docId.split(":")
                    val type = split[0]
                    if ("primary".equals(type, ignoreCase = true)) {
                        return Environment.getExternalStorageDirectory().toString() + "/" + split[1]
                    } else {
                        // 挂载的 SD 卡或其他存储
                        return "/storage/${type}/${split[1]}"
                    }
                }
                // DownloadsProvider
                else if (isDownloadsDocument(uri)) {
                    val id = DocumentsContract.getDocumentId(uri)
                    if (id.startsWith("raw:")) {
                        return id.substring(4)
                    }
                    try {
                        val contentUri = ContentUris.withAppendedId(
                            Uri.parse("content://downloads/public_downloads"), java.lang.Long.valueOf(id)
                        )
                        return getDataColumn(context, contentUri, null, null)
                    } catch (e: Exception) {
                        return getDataColumn(context, uri, null, null)
                    }
                }
                // MediaProvider
                else if (isMediaDocument(uri)) {
                    val docId = DocumentsContract.getDocumentId(uri)
                    val split = docId.split(":")
                    val type = split[0]

                    var contentUri: Uri? = null
                    when (type) {
                        "image" -> contentUri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        "video" -> contentUri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        "audio" -> contentUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                    }

                    val selection = "_id=?"
                    val selectionArgs = arrayOf(split[1])

                    if (contentUri != null) {
                        return getDataColumn(context, contentUri, selection, selectionArgs)
                    }
                }
            } 
            // B. MediaStore 普通 / 非 Document 的 content://
            else if ("media".equals(uri.authority, ignoreCase = true)) {
                return getDataColumn(context, uri, null, null)
            } else {
                // 先盲查一次 _data 字段，看其他 Provider 会不会良心发现给出路径
                val path = getDataColumn(context, uri, null, null)
                if (path != null) return path
            }

            // C. 暴力核弹方法：/proc/self/fd 映射 (应对微信、QQ沙盒内分享等极端不给绝对路径的场景)
            try {
                context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    val fd = pfd.fd
                    val fdFile = File("/proc/self/fd/$fd")
                    if (fdFile.exists()) {
                        val canonicalPath = fdFile.canonicalPath
                        Log.d(TAG, "Resolved via proc fd -> $canonicalPath")
                        // 很多时候 content provider 分配的 fd 指向 /dev/fuse 或者 cache 目录
                        // 只要它是个可读路径，并且不全是乱码虚拟设备，我们就敢把这个绝对路径发给 Daemon！
                        if (canonicalPath != null && !canonicalPath.startsWith("/dev/")) {
                            return canonicalPath
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Proc FD fallback failed: ${e.message}")
            }

            // D. 最后的保底手段：将流拷贝到 Cache 目录 (仅限于前面所有方法全部失败，极慢，但能用)
            Log.w(TAG, "⚠️ All physical path resolutions failed! Falling back to cache copy for $uri")
            return copyUriToCache(context, uri)
        }

        return null
    }

    private fun getDataColumn(context: Context, uri: Uri, selection: String?, selectionArgs: Array<String>?): String? {
        var cursor: Cursor? = null
        val column = "_data"
        val projection = arrayOf(column)

        try {
            cursor = context.contentResolver.query(uri, projection, selection, selectionArgs, null)
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndexOrThrow(column)
                val data = cursor.getString(index)
                if (!data.isNullOrEmpty()) {
                    return data
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get _data column from $uri", e)
        } finally {
            cursor?.close()
        }
        return null
    }

    private fun isExternalStorageDocument(uri: Uri): Boolean = "com.android.externalstorage.documents" == uri.authority
    private fun isDownloadsDocument(uri: Uri): Boolean = "com.android.providers.downloads.documents" == uri.authority
    private fun isMediaDocument(uri: Uri): Boolean = "com.android.providers.media.documents" == uri.authority

    private fun copyUriToCache(context: Context, uri: Uri): String? {
        val contentResolver: ContentResolver = context.contentResolver
        val fileName = getFileName(contentResolver, uri) ?: "temp_sync_file"
        val cacheFile = File(context.cacheDir, fileName)

        try {
            contentResolver.openInputStream(uri)?.use { inputStream ->
                FileOutputStream(cacheFile).use { outputStream ->
                    inputStream.copyTo(outputStream)
                }
            }
            // 确保 Daemon 能读
            cacheFile.setReadable(true, false)
            Log.d(TAG, "Successfully copied to cache: ${cacheFile.absolutePath}")
            return cacheFile.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "Failed to copy URI to cache", e)
        }
        return null
    }

    private fun getFileName(contentResolver: ContentResolver, uri: Uri): String? {
        var name: String? = null
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex != -1) {
                        name = cursor.getString(nameIndex)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get file name", e)
        }
        return name ?: uri.lastPathSegment
    }
}
