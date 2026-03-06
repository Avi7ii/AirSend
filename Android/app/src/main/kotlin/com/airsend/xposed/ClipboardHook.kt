package com.airsend.xposed

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import android.util.Log
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam
import com.airsend.core.utils.IpcCommandEncoder
import kotlin.concurrent.thread

class ClipboardHook : IXposedHookLoadPackage {
    
    companion object {
        private const val TAG = "AirSendXposed"
        private const val SOCKET_NAME = "airsend_ipc"           // 发给Daemon的通道
        private const val REVERSE_SOCKET_NAME = "airsend_app_ipc" // 接收Daemon的通道
        
        // 关键：防死循环锁。当接收 Mac 数据并写入时，不要触发我们自己的发送监听
        @Volatile
        private var isWritingFromSync = false
        private var isServerStarted = false
    }

    override fun handleLoadPackage(lpparam: LoadPackageParam) {
        if (lpparam.packageName != "android") return

        // 1. 在 system_server 中启动上帝模式接收总线
        if (!isServerStarted) {
            isServerStarted = true
            startGodModeIpcServer(lpparam.classLoader)
        }

        // 2. 原有的剪贴板监听逻辑
        try {
            val clipboardImplClass = XposedHelpers.findClass(
                "com.android.server.clipboard.ClipboardService\$ClipboardImpl",
                lpparam.classLoader
            )
            val setPrimaryClipMethods = clipboardImplClass.declaredMethods.filter { it.name == "setPrimaryClip" }

            for (method in setPrimaryClipMethods) {
                XposedBridge.hookMethod(method, object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        if (isWritingFromSync) {
                            Log.d(TAG, "🔒 屏蔽自身同步写入事件，防止无限回环")
                        }
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        if (isWritingFromSync) return // 是我们自己写入的，直接丢弃，不发给Mac
                        
                        val clipData = param.args.firstOrNull { it is ClipData } as? ClipData ?: return
                        val text = clipData.getItemAt(0)?.text?.toString() ?: return
                        
                        Log.d(TAG, "📤 Intercepted clipboard: $text")
                        sendToDaemonViaUDS(text)
                    }
                })
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Hook Failed", e)
        }
    }

    private fun startGodModeIpcServer(classLoader: ClassLoader) {
        thread(name = "Xposed-ReverseIPC") {
            try {
                // 占领原先分配给 App 的 Socket 名称，Rust 端完全不需要改代码！
                val serverSocket = LocalServerSocket(REVERSE_SOCKET_NAME)
                Log.i(TAG, "🚀 God-Mode IPC Server 启动监听: \\0$REVERSE_SOCKET_NAME")
                
                while (true) {
                    val socket = serverSocket.accept()
                    thread {
                        try {
                            val text = socket.inputStream.reader().readText()
                            Log.d(TAG, "📥 [Xposed] 收到 Mac 下发的文本, 长度: ${text.length}")
                            
                            // 切换到主线程调用系统 API
                            Handler(Looper.getMainLooper()).post {
                                writeToSystemClipboard(text, classLoader)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "读取 Daemon 数据异常", e)
                        } finally {
                            socket.close()
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "上帝模式逆向 IPC 总线启动失败", e)
            }
        }
    }

    private fun writeToSystemClipboard(text: String, classLoader: ClassLoader) {
        try {
            // 上锁
            isWritingFromSync = true
            
            // 黑科技：直接从 ActivityThread 榨取 system_server 的核心 Context
            val activityThreadClass = XposedHelpers.findClass("android.app.ActivityThread", classLoader)
            val currentActivityThread = XposedHelpers.callStaticMethod(activityThreadClass, "currentActivityThread")
            val systemContext = XposedHelpers.callMethod(currentActivityThread, "getSystemContext") as Context
            
            // 获取 ClipboardManager 并写入（UID 1000 无视一切焦点限制）
            val cm = systemContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("AirSend", text)
            cm.setPrimaryClip(clip)
            
            Log.d(TAG, "✅ [Xposed] 已通过 system_server 上帝权限强制写入剪贴板！")
        } catch (e: Exception) {
            Log.e(TAG, "写入剪贴板失败", e)
        } finally {
            // 延迟 500ms 释放锁，防止系统剪贴板事件的极速异步回调再次触发发送
            Handler(Looper.getMainLooper()).postDelayed({
                isWritingFromSync = false
            }, 500)
        }
    }

    private fun sendToDaemonViaUDS(text: String) {
        thread {
            val socket = LocalSocket()
            try {
                socket.connect(LocalSocketAddress(SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT))
                socket.soTimeout = 2000 
                socket.outputStream.use { out ->
                    out.write((IpcCommandEncoder.sendText(text) + "\n").toByteArray())
                    out.flush()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to forward clipboard to daemon: ${e.message}")
            } finally {
                try { socket.close() } catch (ignored: Exception) {}
            }
        }
    }
}
