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
import androidx.core.content.ContextCompat
import com.airsend.AirSendService
import com.airsend.BootReceiver
import com.airsend.core.utils.PathUtils

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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(appContext, intent)
        } else {
            appContext.startService(intent)
        }
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

    override fun resolvePath(uri: Uri): String? = PathUtils.getRealPathFromURI(appContext, uri)

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
}
