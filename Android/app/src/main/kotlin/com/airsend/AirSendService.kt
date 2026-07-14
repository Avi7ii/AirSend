package com.airsend

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.database.ContentObserver
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.NotificationCompat
import com.rosan.installer.R
import com.rosan.installer.domain.settings.repository.AppSettingsRepository
import com.rosan.installer.domain.settings.repository.BooleanSetting
import com.airsend.core.utils.IpcCommandEncoder
import com.rosan.installer.ui.page.airsend.runtime.AndroidRuntimeReaderImpl
import com.rosan.installer.ui.page.airsend.runtime.AirSendForegroundServicePolicy
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.koin.android.ext.android.inject

class AirSendService : Service() {

    companion object {
        private const val TAG = "AirSendService"
        private const val VISIBLE_CHANNEL_ID = "airsend_service_channel"
        private const val SILENT_CHANNEL_ID = "airsend_service_silent_channel"
        private const val NOTIFICATION_ID = 1
        private const val REVERSE_CLIPBOARD_SOCKET = "airsend_app_ipc"
        private const val MAX_CLIPBOARD_BYTES = 1024 * 1024
        private const val CLIPBOARD_DEDUP_WINDOW_MS = 3_000L
        const val ACTION_UPDATE_NOTIFICATION = "com.airsend.action.UPDATE_NOTIFICATION"
        const val EXTRA_SHOW_SERVICE_NOTIFICATION = "show_service_notification"
        @Volatile
        private var localDaemonProcess: Process? = null
    }

    private val appSettingsRepository: AppSettingsRepository by inject()
    private val serviceScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    @Volatile
    private var serviceDestroyed = false
    private var showServiceNotification = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "AirSend Foreground Service Created")
        // The foreground contract must be fulfilled immediately. Start silently, then
        // apply the persisted preference without delaying service initialization.
        updateForegroundNotification(show = false)
        serviceScope.launch {
            val enabled = runCatching {
                appSettingsRepository
                    .getBoolean(BooleanSetting.AirSendShowServiceNotification, false)
                    .first()
            }.getOrDefault(false)
            if (!serviceDestroyed) {
                applyNotificationPreference(enabled)
            }
        }
        startAppClipboardReceiver()
        startBundledDaemonIfNeeded()
    }

    private fun startBundledDaemonIfNeeded() {
        if (daemonIpcReachable()) return
        synchronized(AirSendService::class.java) {
            if (daemonIpcReachable() || localDaemonProcess?.isAlive == true) return

            val daemon = File(applicationInfo.nativeLibraryDir, "libairsend_daemon.so")
            if (!daemon.canExecute()) {
                Log.e(TAG, "Bundled daemon is not executable: $daemon")
                return
            }
            val daemonData = File(filesDir, "daemon").apply { mkdirs() }
            val daemonLogs = File(filesDir, "logs").apply { mkdirs() }
            val externalRoot = getExternalFilesDir(null) ?: filesDir
            val downloads = File(externalRoot, "Download").apply { mkdirs() }
            val media = File(externalRoot, "Pictures").apply { mkdirs() }
            val log = File(daemonLogs, "bootstrap.log")

            runCatching {
                ProcessBuilder(daemon.absolutePath)
                    .redirectErrorStream(true)
                    .redirectOutput(ProcessBuilder.Redirect.appendTo(log))
                    .apply {
                        environment()["AIRSEND_DATA_DIR"] = daemonData.absolutePath
                        environment()["AIRSEND_LOG_DIR"] = daemonLogs.absolutePath
                        environment()["AIRSEND_DOWNLOAD_DESTINATION"] = downloads.absolutePath
                        environment()["AIRSEND_MEDIA_DESTINATION"] = media.absolutePath
                    }
                    .start()
            }.onSuccess {
                localDaemonProcess = it
                Log.i(TAG, "Bundled no-root daemon started")
                registerNoRootClipboardObserver()
                registerNoRootScreenshotObserver()
            }.onFailure {
                Log.e(TAG, "Unable to start bundled no-root daemon", it)
            }
        }
    }

    private fun daemonIpcReachable(): Boolean = runCatching {
        LocalSocket().use { socket ->
            socket.connect(
                LocalSocketAddress("airsend_ipc", LocalSocketAddress.Namespace.ABSTRACT)
            )
        }
        true
    }.getOrDefault(false)

    private fun updateForegroundNotification(show: Boolean) {
        showServiceNotification = show
        createNotificationChannel(show)
        val notification = createNotification(show)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // AirSend maintains a user-visible connection to devices on the local network.
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun applyNotificationPreference(show: Boolean) {
        val bundledDaemonRunning = localDaemonProcess?.isAlive == true
        if (AirSendForegroundServicePolicy.shouldStopAppService(
                showNotification = show,
                daemonIpcReachable = daemonIpcReachable(),
                bundledDaemonRunning = bundledDaemonRunning
            )
        ) {
            Log.i(TAG, "Root daemon is available; stopping App foreground service")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return
        }
        updateForegroundNotification(show)
    }

    private fun createNotificationChannel(show: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = if (show) VISIBLE_CHANNEL_ID else SILENT_CHANNEL_ID
            val serviceChannel = NotificationChannel(
                channelId,
                getString(R.string.airsend_service_channel_name),
                if (show) NotificationManager.IMPORTANCE_LOW else NotificationManager.IMPORTANCE_MIN
            ).apply {
                setShowBadge(false)
                lockscreenVisibility = if (show) {
                    Notification.VISIBILITY_PRIVATE
                } else {
                    Notification.VISIBILITY_SECRET
                }
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    private fun createNotification(show: Boolean): Notification {
        val channelId = if (show) VISIBLE_CHANNEL_ID else SILENT_CHANNEL_ID
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle(getString(R.string.airsend_service_notification_title))
            .setContentText(getString(R.string.airsend_service_notification_text))
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(!show)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(
                if (show) Notification.VISIBILITY_PRIVATE else Notification.VISIBILITY_SECRET
            )
            .setPriority(
                if (show) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_MIN
            )
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_UPDATE_NOTIFICATION) {
            applyNotificationPreference(
                intent.getBooleanExtra(EXTRA_SHOW_SERVICE_NOTIFICATION, false)
            )
        }
        startPeerEventSubscription()
        return START_STICKY
    }

    private val peersSubscriptionLock = Any()
    private var peersSubscriptionThread: Thread? = null
    @Volatile
    private var peersSubscriptionSocket: LocalSocket? = null
    private var lastPeersHash: Int = 0
    private var screenshotObserver: ContentObserver? = null
    private var lastScreenshotUri: String? = null
    private var reverseClipboardServer: LocalServerSocket? = null
    private var reverseClipboardThread: Thread? = null
    private var lastReceivedClipboardText: String? = null
    private var lastReceivedClipboardAtMs: Long = 0L
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null

    private fun startAppClipboardReceiver() {
        if (reverseClipboardThread?.isAlive == true) return
        reverseClipboardThread = thread(name = "AirSendClipboardReceiver") {
            try {
                val server = LocalServerSocket(REVERSE_CLIPBOARD_SOCKET).also {
                    reverseClipboardServer = it
                }
                while (!Thread.currentThread().isInterrupted) {
                    val socket = server.accept()
                    thread(name = "AirSendClipboardDelivery") {
                        socket.use {
                            val text = readClipboardPayload(it) ?: return@thread
                            deliverClipboardText(text)
                        }
                    }
                }
            } catch (error: Exception) {
                if (!Thread.currentThread().isInterrupted) {
                    Log.i(TAG, "App clipboard receiver is already provided by the privileged runtime")
                }
            } finally {
                reverseClipboardServer?.close()
                reverseClipboardServer = null
            }
        }
    }

    private fun readClipboardPayload(socket: LocalSocket): String? {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (output.size() <= MAX_CLIPBOARD_BYTES) {
            val count = socket.inputStream.read(buffer)
            if (count < 0) break
            output.write(buffer, 0, count)
        }
        if (output.size() == 0 || output.size() > MAX_CLIPBOARD_BYTES) return null
        return output.toString(Charsets.UTF_8.name()).takeIf(String::isNotBlank)
    }

    private fun deliverClipboardText(text: String) {
        if (text.isBlank()) return
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(this) {
            if (text == lastReceivedClipboardText &&
                now - lastReceivedClipboardAtMs < CLIPBOARD_DEDUP_WINDOW_MS
            ) {
                return
            }
            lastReceivedClipboardText = text
            lastReceivedClipboardAtMs = now
        }
        Handler(Looper.getMainLooper()).post {
            getSystemService(ClipboardManager::class.java)
                ?.setPrimaryClip(ClipData.newPlainText("AirSend", text))
        }
    }

    private fun registerNoRootClipboardObserver() {
        if (clipboardListener != null) return
        val manager = getSystemService(ClipboardManager::class.java) ?: return
        val listener = ClipboardManager.OnPrimaryClipChangedListener {
            val text = manager.primaryClip
                ?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)
                ?.coerceToText(this)
                ?.toString()
                ?.takeIf(String::isNotBlank)
                ?: return@OnPrimaryClipChangedListener
            val now = android.os.SystemClock.elapsedRealtime()
            synchronized(this) {
                if (text == lastReceivedClipboardText &&
                    now - lastReceivedClipboardAtMs < CLIPBOARD_DEDUP_WINDOW_MS
                ) {
                    return@OnPrimaryClipChangedListener
                }
            }
            thread(name = "AirSendClipboardSync") {
                sendLegacyCommand(IpcCommandEncoder.sendText(text, source = "clipboard"))
            }
        }
        manager.addPrimaryClipChangedListener(listener)
        clipboardListener = listener
    }

    private fun registerNoRootScreenshotObserver() {
        if (screenshotObserver != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: android.net.Uri?) {
                if (uri == null || uri.toString() == lastScreenshotUri) return
                val isScreenshot = runCatching {
                    contentResolver.query(
                        uri,
                        arrayOf(
                            MediaStore.MediaColumns.DISPLAY_NAME,
                            MediaStore.MediaColumns.RELATIVE_PATH
                        ),
                        null,
                        null,
                        null
                    )?.use { cursor ->
                        if (!cursor.moveToFirst()) return@use false
                        val name = cursor.getString(0).orEmpty()
                        val relative = cursor.getString(1).orEmpty()
                        name.contains("screenshot", ignoreCase = true) ||
                            relative.contains("screenshot", ignoreCase = true)
                    } ?: false
                }.getOrDefault(false)
                if (!isScreenshot) return

                lastScreenshotUri = uri.toString()
                thread(name = "AirSendScreenshotSync") {
                    Thread.sleep(600)
                    val path = AndroidRuntimeReaderImpl(this@AirSendService).resolvePath(uri)
                        ?: return@thread
                    sendLegacyCommand(IpcCommandEncoder.sendFile(path, source = "screenshot"))
                }
            }
        }
        contentResolver.registerContentObserver(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            true,
            observer
        )
        screenshotObserver = observer
    }

    private fun sendLegacyCommand(command: String) {
        runCatching {
            LocalSocket().use { socket ->
                socket.connect(
                    LocalSocketAddress("airsend_ipc", LocalSocketAddress.Namespace.ABSTRACT)
                )
                socket.outputStream.bufferedWriter().use { writer ->
                    writer.write(command)
                    writer.newLine()
                    writer.flush()
                }
            }
        }.onFailure { Log.w(TAG, "Screenshot sync IPC failed", it) }
    }

    private fun startPeerEventSubscription() {
        synchronized(peersSubscriptionLock) {
            if (peersSubscriptionThread?.isAlive == true) {
                Log.d(TAG, "Peer event subscription already running")
                return
            }

            peersSubscriptionThread = thread(name = "AirSendPeerEvents") {
                runPeerEventSubscriptionLoop()
            }
        }
    }

    private fun runPeerEventSubscriptionLoop() {
        var reconnectDelayMs = 1_000L
        try {
            while (!Thread.currentThread().isInterrupted) {
                val connected = runCatching {
                    LocalSocket().use { socket ->
                        peersSubscriptionSocket = socket
                        socket.connect(
                            LocalSocketAddress("airsend_ipc", LocalSocketAddress.Namespace.ABSTRACT)
                        )
                        val writer = java.io.OutputStreamWriter(socket.outputStream)
                        writer.write(
                            "{\"id\":\"service-subscribe\",\"op\":\"subscribe\",\"payload\":{}}\n"
                        )
                        writer.flush()

                        val reader = socket.inputStream.bufferedReader()
                        val response = reader.readLine()
                            ?: error("daemon closed the subscription before acknowledging it")
                        if (!org.json.JSONObject(response).optBoolean("ok")) {
                            error("daemon rejected the peer event subscription")
                        }
                        reconnectDelayMs = 1_000L
                        fetchPeersAndUpdateShortcuts()
                        while (!Thread.currentThread().isInterrupted) {
                            val line = reader.readLine() ?: break
                            val event = org.json.JSONObject(line)
                            if (event.optString("event") == "peers_changed") {
                                fetchPeersAndUpdateShortcuts()
                            }
                        }
                    }
                }.isSuccess
                peersSubscriptionSocket = null
                if (Thread.currentThread().isInterrupted) break
                if (!connected) {
                    Log.d(TAG, "Daemon peer event subscription failed; retrying")
                }
                sleepBeforeReconnect(reconnectDelayMs)
                reconnectDelayMs = (reconnectDelayMs * 2).coerceAtMost(30_000L)
            }
        } finally {
            peersSubscriptionSocket?.close()
            peersSubscriptionSocket = null
            synchronized(peersSubscriptionLock) {
                if (peersSubscriptionThread === Thread.currentThread()) {
                    peersSubscriptionThread = null
                }
            }
        }
    }

    private fun sleepBeforeReconnect(delayMs: Long) {
        try {
            Thread.sleep(delayMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun fetchPeersAndUpdateShortcuts() {
        runCatching {
            LocalSocket().use { socket ->
                socket.connect(
                    LocalSocketAddress("airsend_ipc", LocalSocketAddress.Namespace.ABSTRACT)
                )
                socket.soTimeout = 2_000
                val writer = socket.outputStream.bufferedWriter()
                writer.write("GET_PEERS")
                writer.newLine()
                writer.flush()
                val jsonString = socket.inputStream.bufferedReader().readLine()
                    ?.trim()
                    ?.takeIf(String::isNotEmpty)
                    ?: return
                val hash = jsonString.hashCode()
                if (hash != lastPeersHash) {
                    lastPeersHash = hash
                    updateDirectShareShortcuts(jsonString)
                }
            }
        }.onFailure { error ->
            Log.d(TAG, "Daemon peer snapshot failed: ${error.message}")
        }
    }

    private fun updateDirectShareShortcuts(jsonString: String) {
        try {
            val jsonArray = org.json.JSONArray(jsonString)
            val targets = mutableListOf<AirSendShareTarget>()

            for (i in 0 until jsonArray.length()) {
                val obj = jsonArray.getJSONObject(i)
                targets += AirSendShareTarget(
                    id = obj.getString("id"),
                    alias = obj.getString("alias"),
                    deviceType = obj.optString("deviceType").takeIf(String::isNotBlank),
                    online = obj.optBoolean("online", true)
                )
            }
            AirSendShareShortcutPublisher.publish(this, targets)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse and update shortcuts", e)
        }
    }

    override fun onDestroy() {
        Log.d(TAG, "AirSend Service Destroyed")
        serviceDestroyed = true
        serviceScope.cancel()
        synchronized(peersSubscriptionLock) {
            peersSubscriptionThread?.interrupt()
            peersSubscriptionSocket?.close()
            peersSubscriptionThread = null
        }
        synchronized(AirSendService::class.java) {
            localDaemonProcess?.destroy()
            localDaemonProcess = null
        }
        reverseClipboardThread?.interrupt()
        reverseClipboardThread = null
        reverseClipboardServer?.close()
        reverseClipboardServer = null
        clipboardListener?.let { listener ->
            getSystemService(ClipboardManager::class.java)
                ?.removePrimaryClipChangedListener(listener)
        }
        clipboardListener = null
        screenshotObserver?.let(contentResolver::unregisterContentObserver)
        screenshotObserver = null
        super.onDestroy()
    }

}
