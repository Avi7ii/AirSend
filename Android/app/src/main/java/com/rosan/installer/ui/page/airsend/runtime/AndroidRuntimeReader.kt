// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import android.Manifest
import android.app.ActivityManager
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.core.content.ContextCompat
import com.airsend.AirSendService
import com.airsend.BootReceiver
import com.airsend.core.utils.PathUtils
import java.io.File
import java.util.UUID

data class AndroidRuntimeSnapshot(
    val serviceRunning: Boolean,
    val bootStartEnabled: Boolean,
    val notificationPermissionGranted: Boolean,
    val storagePermissionGranted: Boolean
)

interface AndroidRuntimeReader {
    fun snapshot(): AndroidRuntimeSnapshot
    fun startService()
    fun stopService()
    fun setBootStartEnabled(enabled: Boolean)
    fun clipboardText(): String?
    fun resolvePath(uri: Uri): String?
}

class AndroidRuntimeReaderImpl(context: Context) : AndroidRuntimeReader {
    private val appContext = context.applicationContext

    override fun snapshot(): AndroidRuntimeSnapshot = AndroidRuntimeSnapshot(
        serviceRunning = isServiceRunning(),
        bootStartEnabled = isBootStartEnabled(),
        notificationPermissionGranted = hasNotificationPermission(),
        storagePermissionGranted = hasStoragePermission()
    )

    override fun startService() {
        val intent = Intent(appContext, AirSendService::class.java)
        ContextCompat.startForegroundService(appContext, intent)
    }

    override fun stopService() {
        appContext.stopService(Intent(appContext, AirSendService::class.java))
    }

    override fun setBootStartEnabled(enabled: Boolean) {
        val component = ComponentName(appContext, BootReceiver::class.java)
        appContext.packageManager.setComponentEnabledSetting(
            component,
            if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            },
            PackageManager.DONT_KILL_APP
        )
    }

    override fun clipboardText(): String? {
        val clipboard = appContext.getSystemService(ClipboardManager::class.java)
        return clipboard
            ?.primaryClip
            ?.takeIf { it.itemCount > 0 }
            ?.getItemAt(0)
            ?.coerceToText(appContext)
            ?.toString()
    }

    override fun resolvePath(uri: Uri): String? {
        val directPath = runCatching {
            PathUtils.getRealPathFromURI(appContext, uri)
        }.getOrNull()?.takeIf { File(it).isFile }
        if (directPath != null) return directPath

        val root = File(appContext.cacheDir, OUTGOING_CACHE_DIR).apply { mkdirs() }
        pruneOutgoingCache(root)
        val transferDir = File(root, UUID.randomUUID().toString()).apply { mkdirs() }
        val destination = File(transferDir, displayName(uri))
        return runCatching {
            val input = appContext.contentResolver.openInputStream(uri)
                ?: error("Unable to open $uri")
            input.use { source ->
                destination.outputStream().buffered().use { output ->
                    source.copyTo(output, DEFAULT_BUFFER_SIZE)
                }
            }
            destination.absolutePath
        }.getOrElse {
            transferDir.deleteRecursively()
            null
        }
    }

    private fun displayName(uri: Uri): String {
        val providerName = runCatching {
            appContext.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull()
        return (providerName ?: uri.lastPathSegment ?: "file")
            .replace(Regex("[\\/\\p{Cntrl}]"), "_")
            .takeIf { it.isNotBlank() }
            ?: "file"
    }

    private fun pruneOutgoingCache(root: File) {
        val cutoff = System.currentTimeMillis() - OUTGOING_CACHE_RETENTION_MS
        root.listFiles()
            ?.filter { it.lastModified() < cutoff }
            ?.forEach(File::deleteRecursively)
    }

    @Suppress("DEPRECATION")
    private fun isServiceRunning(): Boolean {
        val manager = appContext.getSystemService(ActivityManager::class.java) ?: return false
        return manager.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == AirSendService::class.java.name
        }
    }

    private fun isBootStartEnabled(): Boolean {
        val component = ComponentName(appContext, BootReceiver::class.java)
        return when (appContext.packageManager.getComponentEnabledSetting(component)) {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER -> false
            else -> true
        }
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasStoragePermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val imageGranted = ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.READ_MEDIA_IMAGES
            ) == PackageManager.PERMISSION_GRANTED
            val videoGranted = ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.READ_MEDIA_VIDEO
            ) == PackageManager.PERMISSION_GRANTED
            return imageGranted && videoGranted
        }
        return ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.READ_EXTERNAL_STORAGE
        ) == PackageManager.PERMISSION_GRANTED
    }

    private companion object {
        const val OUTGOING_CACHE_DIR = "airsend-outgoing"
        const val OUTGOING_CACHE_RETENTION_MS = 24L * 60L * 60L * 1000L
    }
}
