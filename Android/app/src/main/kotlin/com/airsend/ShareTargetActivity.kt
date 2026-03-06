package com.airsend

import android.app.Activity
import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import com.airsend.core.utils.IpcCommandEncoder
import com.airsend.core.utils.PathUtils
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import kotlin.concurrent.thread

class ShareTargetActivity : Activity() {

    companion object {
        private const val TAG = "ShareTargetActivity"
        private const val SOCKET_NAME = "airsend_ipc"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntentBackground(intent)
        finish() // 极致无感，分配完任务立刻销毁自身
    }

    private fun handleIntentBackground(intent: Intent?) {
        if (intent == null) return

        // 提取被点击的 Shortcut ID (原生 DirectShare 的传递方式，而不是通过 extras)
        // Android 10+ 原生分享面板会将被点击的 Shortcut ID 作为 EXTRA_SHORTCUT_ID 传入
        val shortcutId = intent.getStringExtra("android.intent.extra.shortcut.ID")
        var targetId = shortcutId?.removePrefix("peer_")

        if (targetId.isNullOrEmpty()) {
            // 当点击主图标 (未带 shortcutID 的原生分享意图) 时：静默抓取第一个可用设备！
            val peer = fetchFirstPeerFromDaemon()
            if (peer != null) {
                targetId = peer.first
                Toast.makeText(this, "🚀 正在静默发送给 ${peer.second}...", Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this, "未能获取目标设备：未发现周围存在 AirSend 电脑", Toast.LENGTH_SHORT).show()
                return
            }
        } else {
            Toast.makeText(this, "🚀 正在传送给目标设备...", Toast.LENGTH_SHORT).show()
        }

        when (intent.action) {
            Intent.ACTION_SEND -> {
                val streamUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (streamUri != null) {
                    processUriAndSend(streamUri, targetId)
                } else {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (!text.isNullOrEmpty()) {
                        sendToRustDaemon(IpcCommandEncoder.sendText(text, targetId))
                    } else {
                        Log.w(TAG, "ACTION_SEND ignored: no EXTRA_STREAM and no EXTRA_TEXT. type=${intent.type}")
                    }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                uris?.forEach { processUriAndSend(it, targetId) }
            }
        }
    }

    private fun fetchFirstPeerFromDaemon(): Pair<String, String>? {
        val socket = LocalSocket()
        return try {
            socket.connect(LocalSocketAddress(SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT))
            socket.soTimeout = 2000

            val writer = OutputStreamWriter(socket.outputStream)
            writer.write(IpcCommandEncoder.getPeers() + "\n")
            writer.flush()

            val reader = InputStreamReader(socket.inputStream)
            val buffer = CharArray(4096)
            val charsRead = reader.read(buffer)
            if (charsRead > 0) {
                val jsonString = String(buffer, 0, charsRead).trim()
                val jsonArray = org.json.JSONArray(jsonString)
                if (jsonArray.length() > 0) {
                    val obj = jsonArray.getJSONObject(0)
                    Pair(obj.getString("id"), obj.getString("alias"))
                } else null
            } else null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to fetch peers", e)
            null
        } finally {
            try { socket.close() } catch (ignored: Exception) {}
        }
    }

    private fun processUriAndSend(uri: Uri, targetId: String) {
        thread {
            val realPath = PathUtils.getRealPathFromURI(this, uri)
            if (realPath != null) {
                sendToRustDaemon(IpcCommandEncoder.sendFile(realPath, targetId))
            } else {
                Log.e(TAG, "Failed to resolve URI: $uri")
                Handler(Looper.getMainLooper()).post {
                    Toast.makeText(this@ShareTargetActivity, "不支持的文件来源，解析物理路径失败", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    private fun sendToRustDaemon(command: String) {
        thread {
            val socket = LocalSocket()
            try {
                socket.connect(LocalSocketAddress(SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT))
                OutputStreamWriter(socket.outputStream).use { writer ->
                    writer.write(command + "\n")
                    writer.flush()
                }
            } catch (e: Exception) {
                Log.e(TAG, "IPC Connection failed: ${e.message}")
            } finally {
                try { socket.close() } catch (ignored: Exception) {}
            }
        }
    }
}
