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
import android.os.SystemClock
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.airsend.AirSendShareShortcutPublisher
import com.airsend.AirSendShareTarget
import com.rosan.installer.BuildConfig
import com.airsend.AirSendService
import com.airsend.BootReceiver
import com.airsend.core.utils.PathUtils
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class AndroidRuntimeSnapshot(
    val serviceRunning: Boolean,
    val bootStartEnabled: Boolean,
    val notificationPermissionGranted: Boolean,
    val storagePermissionGranted: Boolean
)

data class RootDaemonSnapshot(
    val rootAvailable: Boolean = false,
    val rootProvider: String? = null,
    val moduleInstalled: Boolean = false,
    val moduleEnabled: Boolean = false,
    val moduleVersion: String? = null,
    val daemonProcessRunning: Boolean = false
)

interface AndroidRuntimeReader {
    fun snapshot(): AndroidRuntimeSnapshot
    suspend fun rootDaemonSnapshot(): RootDaemonSnapshot
    suspend fun startRootDaemon()
    suspend fun repairRootDaemon()
    suspend fun stopRootDaemon()
    fun startService()
    fun stopService()
    fun updateServiceNotification(enabled: Boolean) {}
    fun publishShareTargets(peers: List<AirSendPeer>, preferredTargetId: String?) {}
    fun reportShareTargetUsed(targetId: String) {}
    fun setBootStartEnabled(enabled: Boolean)
    fun clipboardText(): String?
    fun resolvePath(uri: Uri): String?
    fun resolveDirectory(uri: Uri): String?
    fun openFile(path: String, mimeType: String)
    fun shareFile(path: String, mimeType: String)
    fun writeDocument(uri: Uri, content: String)
}

class AndroidRuntimeReaderImpl(context: Context) : AndroidRuntimeReader {
    private val appContext = context.applicationContext
    private val rootSnapshotMutex = Mutex()
    private var cachedRootSnapshot: RootDaemonSnapshot? = null
    private var cachedRootSnapshotAtMs = 0L

    override fun snapshot(): AndroidRuntimeSnapshot = AndroidRuntimeSnapshot(
        serviceRunning = isServiceRunning(),
        bootStartEnabled = isBootStartEnabled(),
        notificationPermissionGranted = hasNotificationPermission(),
        storagePermissionGranted = hasStoragePermission()
    )

    override suspend fun rootDaemonSnapshot(): RootDaemonSnapshot = withContext(Dispatchers.IO) {
        rootSnapshotMutex.withLock {
            val now = SystemClock.elapsedRealtime()
            cachedRootSnapshot
                ?.takeIf { now - cachedRootSnapshotAtMs < ROOT_STATUS_CACHE_MS }
                ?.let { return@withLock it }

            val output = runRootCommand(ROOT_STATUS_COMMAND)
                ?: return@withLock cachedRootSnapshot ?: RootDaemonSnapshot()
            val values = output.lineSequence()
                .mapNotNull { line ->
                    val split = line.indexOf('=')
                    if (split <= 0) null else line.substring(0, split) to line.substring(split + 1)
                }
                .toMap()
            RootDaemonSnapshot(
                rootAvailable = values["rootAvailable"] == "1",
                rootProvider = values["rootProvider"]?.takeIf(String::isNotBlank),
                moduleInstalled = values["moduleInstalled"] == "1",
                moduleEnabled = values["moduleEnabled"] == "1",
                moduleVersion = values["moduleVersion"]?.takeIf(String::isNotBlank),
                daemonProcessRunning = values["daemonProcessRunning"] == "1"
            ).also {
                cachedRootSnapshot = it
                cachedRootSnapshotAtMs = now
            }
        }
    }

    override suspend fun startRootDaemon() = withContext(Dispatchers.IO) {
        requireRootSuccess(
            "if pidof airsend_daemon >/dev/null 2>&1; then exit 0; fi; " +
                "SUPERVISOR=/system/bin/airsend_supervisor; " +
                "if [ -x \"\$SUPERVISOR\" ]; then " +
                "nohup \"\$SUPERVISOR\" >>/data/local/tmp/airsend_daemon_bootstrap.log 2>&1 & exit 0; fi; " +
                "DAEMON=/system/bin/airsend_daemon; " +
                "test -x \"\$DAEMON\" || exit 12; " +
                "nohup \"\$DAEMON\" >>/data/local/tmp/airsend_daemon_bootstrap.log 2>&1 &"
        )
        invalidateRootSnapshot()
    }

    override suspend fun repairRootDaemon() = withContext(Dispatchers.IO) {
        requireRootSuccess(
            "if [ -r /data/local/tmp/airsend_supervisor/.lock/pid ]; then " +
                "SUPERVISOR_PID=\$(cat /data/local/tmp/airsend_supervisor/.lock/pid); " +
                "case \"\$SUPERVISOR_PID\" in ''|*[!0-9]*) ;; *) " +
                "kill -TERM \"\$SUPERVISOR_PID\" 2>/dev/null || true ;; esac; " +
                "fi; " +
                "for _ in \$(seq 1 20); do " +
                "[ -r /data/local/tmp/airsend_supervisor/.lock/pid ] || break; " +
                "sleep 0.1; " +
                "done; " +
                "for PID in \$(pidof airsend_daemon 2>/dev/null); do " +
                "kill -TERM \"\$PID\" 2>/dev/null || true; " +
                "done; " +
                "for _ in \$(seq 1 20); do " +
                "pidof airsend_daemon >/dev/null 2>&1 || break; " +
                "sleep 0.1; " +
                "done; " +
                "for PID in \$(pidof airsend_daemon 2>/dev/null); do " +
                "kill -KILL \"\$PID\" 2>/dev/null || true; " +
                "done; " +
                "SUPERVISOR=/system/bin/airsend_supervisor; " +
                "if [ -x \"\$SUPERVISOR\" ]; then " +
                "nohup \"\$SUPERVISOR\" >>/data/local/tmp/airsend_daemon_bootstrap.log 2>&1 & exit 0; fi; " +
                "DAEMON=/system/bin/airsend_daemon; " +
                "test -x \"\$DAEMON\" || exit 12; " +
                "nohup \"\$DAEMON\" >>/data/local/tmp/airsend_daemon_bootstrap.log 2>&1 &"
        )
        invalidateRootSnapshot()
    }

    override suspend fun stopRootDaemon() = withContext(Dispatchers.IO) {
        requireRootSuccess(
            "if [ -r /data/local/tmp/airsend_supervisor/.lock/pid ]; then " +
                "SUPERVISOR_PID=\$(cat /data/local/tmp/airsend_supervisor/.lock/pid); " +
                "case \"\$SUPERVISOR_PID\" in ''|*[!0-9]*) ;; *) " +
                "kill -TERM \"\$SUPERVISOR_PID\" 2>/dev/null || true ;; esac; " +
                "fi; " +
                "for _ in \$(seq 1 20); do " +
                "[ -r /data/local/tmp/airsend_supervisor/.lock/pid ] || break; " +
                "sleep 0.1; " +
                "done; " +
                "for PID in \$(pidof airsend_daemon 2>/dev/null); do " +
                "kill -TERM \"\$PID\" 2>/dev/null || true; " +
                "done; " +
                "for _ in \$(seq 1 20); do " +
                "pidof airsend_daemon >/dev/null 2>&1 || break; " +
                "sleep 0.1; " +
                "done; " +
                "for PID in \$(pidof airsend_daemon 2>/dev/null); do " +
                "kill -KILL \"\$PID\" 2>/dev/null || true; " +
                "done"
        )
        invalidateRootSnapshot()
    }

    override fun startService() {
        val intent = Intent(appContext, AirSendService::class.java)
        ContextCompat.startForegroundService(appContext, intent)
    }

    override fun stopService() {
        appContext.stopService(Intent(appContext, AirSendService::class.java))
    }

    override fun updateServiceNotification(enabled: Boolean) {
        if (!isServiceRunning()) return
        val intent = Intent(appContext, AirSendService::class.java)
            .setAction(AirSendService.ACTION_UPDATE_NOTIFICATION)
            .putExtra(AirSendService.EXTRA_SHOW_SERVICE_NOTIFICATION, enabled)
        appContext.startService(intent)
    }

    override fun publishShareTargets(peers: List<AirSendPeer>, preferredTargetId: String?) {
        AirSendShareShortcutPublisher.publish(
            context = appContext,
            targets = peers.map { peer ->
                AirSendShareTarget(
                    id = peer.id,
                    alias = peer.alias,
                    deviceType = peer.deviceType,
                    online = peer.online
                )
            },
            preferredTargetId = preferredTargetId
        )
    }

    override fun reportShareTargetUsed(targetId: String) {
        AirSendShareShortcutPublisher.reportUsed(appContext, targetId)
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

    override fun resolveDirectory(uri: Uri): String? {
        val documentId = runCatching {
            DocumentsContract.getTreeDocumentId(uri)
        }.getOrNull() ?: return null
        val separator = documentId.indexOf(':')
        val volume = if (separator >= 0) documentId.substring(0, separator) else documentId
        val relative = if (separator >= 0) documentId.substring(separator + 1) else ""
        val root = when {
            volume.equals("primary", ignoreCase = true) -> "/storage/emulated/0"
            volume.matches(Regex("[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}")) -> "/storage/$volume"
            else -> return null
        }
        val path = if (relative.isBlank()) root else "$root/$relative"
        return path.replace(Regex("/+"), "/")
    }

    override fun openFile(path: String, mimeType: String) {
        val uri = fileUri(path)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mimeType.ifBlank { "application/octet-stream" })
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        appContext.startActivity(intent)
    }

    override fun shareFile(path: String, mimeType: String) {
        val uri = fileUri(path)
        val send = Intent(Intent.ACTION_SEND)
            .setType(mimeType.ifBlank { "application/octet-stream" })
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        appContext.startActivity(
            Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    override fun writeDocument(uri: Uri, content: String) {
        val output = appContext.contentResolver.openOutputStream(uri, "wt")
            ?: error("Unable to open the selected document")
        output.bufferedWriter().use { writer -> writer.write(content) }
    }

    private fun fileUri(path: String): Uri {
        val file = File(path)
        require(file.isFile) { "Received file no longer exists: $path" }
        return FileProvider.getUriForFile(
            appContext,
            "${BuildConfig.APPLICATION_ID}.fileprovider",
            file
        )
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

    private fun runRootCommand(command: String): String? = runCatching {
        val process = ProcessBuilder("su", "-c", command)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        if (process.waitFor() == 0) output else null
    }.getOrNull()

    private fun requireRootSuccess(command: String) {
        check(runRootCommand(command) != null) { "Root authorization is unavailable" }
    }

    private suspend fun invalidateRootSnapshot() {
        rootSnapshotMutex.withLock {
            cachedRootSnapshot = null
            cachedRootSnapshotAtMs = 0L
        }
    }

    private companion object {
        const val OUTGOING_CACHE_DIR = "airsend-outgoing"
        const val OUTGOING_CACHE_RETENTION_MS = 24L * 60L * 60L * 1000L
        const val ROOT_STATUS_CACHE_MS = 15_000L
        val ROOT_STATUS_COMMAND = """
            MOD=/data/adb/modules/airsend_daemon
            echo rootAvailable=1
            if command -v magisk >/dev/null 2>&1; then echo rootProvider=Magisk
            elif command -v ksud >/dev/null 2>&1; then echo rootProvider=KernelSU
            elif command -v apd >/dev/null 2>&1; then echo rootProvider=APatch
            else echo rootProvider=su; fi
            if [ -f "${'$'}MOD/module.prop" ]; then
              echo moduleInstalled=1
              [ ! -f "${'$'}MOD/disable" ] && echo moduleEnabled=1 || echo moduleEnabled=0
              sed -n 's/^version=//p' "${'$'}MOD/module.prop" | head -n 1 | sed 's/^/moduleVersion=/'
            else
              echo moduleInstalled=0
              echo moduleEnabled=0
            fi
            pidof airsend_daemon >/dev/null 2>&1 && echo daemonProcessRunning=1 || echo daemonProcessRunning=0
        """.trimIndent()
    }
}
