package com.airsend.core.watcher

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.FileObserver
import android.util.Log
import java.io.File
import java.io.OutputStreamWriter
import kotlin.concurrent.thread

class MagicWatcher(private val path: String) : FileObserver(File(path), CLOSE_WRITE) {

    companion object {
        private const val TAG = "MagicWatcher"
        private const val SOCKET_NAME = "airsend_ipc"
    }

    override fun onEvent(event: Int, fileName: String?) {
        if (fileName == null) return
        
        val fullPath = "$path/$fileName"
        Log.i(TAG, "New file detected: $fullPath")
        
        // 过滤临时文件或非媒体文件
        if (fileName.startsWith(".") || fileName.endsWith(".tmp") || fileName.endsWith(".pending")) return

        sendToDaemon("SEND_FILE:$fullPath")
    }

    private fun sendToDaemon(command: String) {
        thread {
            val socket = LocalSocket()
            try {
                // 使用 ABSTRACT 命名空间，绕过文件权限和 SELinux 对文件路径的限制
                socket.connect(LocalSocketAddress(SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT))
                socket.soTimeout = 2000 // 致命暗坑二：补齐超时控制，防止僵死
                OutputStreamWriter(socket.outputStream).use { writer ->
                    writer.write(command + "\n")
                    writer.flush()
                }
                Log.d(TAG, "Watch event sent to daemon: $command")
            } catch (e: Exception) {
                Log.e(TAG, "通知 Daemon 发送文件失败 (UDS): ${e.message}")
            } finally {
                try {
                    socket.close()
                } catch (ignored: Exception) {}
            }
        }
    }
}
