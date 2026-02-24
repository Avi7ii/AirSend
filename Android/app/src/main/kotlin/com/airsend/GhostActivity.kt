package com.airsend

import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.airsend.core.utils.PathUtils
import java.io.OutputStreamWriter
import kotlin.concurrent.thread

/**
 * 幽灵分享 Activity：无 UI 界面，仅作为 Intent 转发中转站
 */
class GhostActivity : AppCompatActivity() {
    
    companion object {
        private const val TAG = "GhostActivity"
        private const val SOCKET_NAME = "airsend_ipc"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 立即处理 Intent
        handleIntent(intent)
        // 任务完成后立即关闭，不显示任何 UI
        finish()
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        
        when (intent.action) {
            Intent.ACTION_SEND -> {
                if ("text/plain" == intent.type) {
                    handleSendText(intent)
                } else {
                    handleSendFile(intent)
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                handleSendMultipleFiles(intent)
            }
        }
    }

    private fun handleSendText(intent: Intent) {
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
        Log.i(TAG, "Ghost sending text: ${text.take(20)}...")
        sendToRustDaemon("SEND_TEXT:$text")
        Toast.makeText(this, "正在同步文字至 Mac...", Toast.LENGTH_SHORT).show()
    }

    private fun handleSendFile(intent: Intent) {
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return
        processUriAndSend(uri)
    }

    private fun handleSendMultipleFiles(intent: Intent) {
        val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: return
        Toast.makeText(this, "正在同步 ${uris.size} 个文件...", Toast.LENGTH_SHORT).show()
        uris.forEach { processUriAndSend(it) }
    }

    private fun processUriAndSend(uri: Uri) {
        thread {
            // 尝试解析真实物理路径
            val realPath = PathUtils.getRealPathFromURI(this, uri)
            if (realPath != null) {
                sendToRustDaemon("SEND_FILE:$realPath")
            } else {
                // 如果解析失败（例如来自加密应用），目前 Daemon 暂不支持 content:// URI
                // 可以在此扩展：通过 ContentResolver 读取流并写入临时文件再发送
                Log.e(TAG, "Failed to resolve URI: $uri")
            }
        }
    }

    private fun sendToRustDaemon(command: String) {
        val socket = LocalSocket()
        try {
            // 对齐 RootService 使用的 ABSTRACT 命名空间
            socket.connect(LocalSocketAddress(SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT))
            OutputStreamWriter(socket.outputStream).use { writer ->
                writer.write(command + "\n")
                writer.flush()
            }
        } catch (e: Exception) {
            Log.e(TAG, "IPC Connection failed: ${e.message}")
        } finally {
            try {
                socket.close()
            } catch (ignored: Exception) {}
        }
    }
}
