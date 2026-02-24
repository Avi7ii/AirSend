package com.airsend

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlin.concurrent.thread

class AirSendService : Service() {

    companion object {
        private const val TAG = "AirSendService"
        private const val CHANNEL_ID = "airsend_service_channel"
        private const val NOTIFICATION_ID = 1
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "AirSend Foreground Service Created")
        createNotificationChannel()
        
        val notification = createNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ 支持，Android 14+ 强制要求
            startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "AirSend 后台同步服务",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("AirSend 已启动")
            .setContentText("正在保持后台同步运行...")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startPeersSyncTask()
        return START_STICKY
    }

    private var lastPeersHash: Int = 0 // 🔋 shortcut 去重

    private fun startPeersSyncTask() {
        thread {
            while (true) {
                try {
                    val socket = LocalSocket()
                    socket.connect(LocalSocketAddress("airsend_ipc", LocalSocketAddress.Namespace.ABSTRACT))
                    socket.soTimeout = 2000
                    
                    val writer = java.io.OutputStreamWriter(socket.outputStream)
                    writer.write("GET_PEERS\n")
                    writer.flush()
                    
                    val reader = java.io.InputStreamReader(socket.inputStream)
                    val buffer = CharArray(4096)
                    val charsRead = reader.read(buffer)
                    
                    if (charsRead > 0) {
                        val jsonString = String(buffer, 0, charsRead).trim()
                        // 🔋 仅在 peers 数据变化时才更新 shortcut（避免无意义 binder IPC）
                        val hash = jsonString.hashCode()
                        if (hash != lastPeersHash) {
                            lastPeersHash = hash
                            updateDirectShareShortcuts(jsonString)
                        }
                    }
                    socket.close()
                } catch (e: Exception) {
                    Log.d(TAG, "Daemon IPC Sync failed: ${e.message}")
                }
                Thread.sleep(30_000) // 🔋 30s 轮询（原 5s）
            }
        }
    }

    private fun updateDirectShareShortcuts(jsonString: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        
        try {
            val jsonArray = org.json.JSONArray(jsonString)
            val shortcutManager = getSystemService(android.content.pm.ShortcutManager::class.java)
            val shortcuts = mutableListOf<android.content.pm.ShortcutInfo>()
            
            for (i in 0 until jsonArray.length()) {
                val obj = jsonArray.getJSONObject(i)
                val id = obj.getString("id")
                val alias = obj.getString("alias")
                
                val iconRes = android.graphics.drawable.Icon.createWithResource(this, android.R.drawable.ic_menu_share)
                
                // 将快捷方式的点击目的地设为我们的无相 Target
                val intent = Intent(this, ShareTargetActivity::class.java).apply {
                    action = Intent.ACTION_SEND
                    putExtra("targetId", id)
                    putExtra("targetAlias", alias)
                    // 需要给它配对 categories 以被系统识别为分享入口
                }
                
                val shortcut = android.content.pm.ShortcutInfo.Builder(this, "peer_$id")
                    .setShortLabel(alias)
                    .setLongLabel("发送给 $alias")
                    .setIcon(iconRes)
                    .setCategories(setOf("com.airsend.category.DIRECT_SHARE_TARGET"))
                    .setIntent(intent)
                    .build()
                    
                shortcuts.add(shortcut)
            }
            
            // 全盘覆写动态分享菜单
            shortcutManager.dynamicShortcuts = shortcuts
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse and update shortcuts", e)
        }
    }

    override fun onDestroy() {
        Log.d(TAG, "AirSend Service Destroyed")
        super.onDestroy()
    }
}
