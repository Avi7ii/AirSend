package com.airsend.core

import android.content.ClipData
import android.os.IBinder
import android.util.Log

class ClipboardController {
    private var clipboardService: Any? = null

    init {
        try {
            val serviceManager = Class.forName("android.os.ServiceManager")
            val getService = serviceManager.getMethod("getService", String::class.java)
            val binder = getService.invoke(null, "clipboard") as IBinder
            val stub = Class.forName("android.content.IClipboard\$Stub")
            val asInterface = stub.getMethod("asInterface", IBinder::class.java)
            clipboardService = asInterface.invoke(null, binder)
        } catch (e: Exception) {
            Log.e("ClipboardController", "Failed to init IClipboard", e)
        }
    }

    fun setText(text: String) {
        try {
            val clipData = ClipData.newPlainText("AirSend", text)
            val methods = clipboardService?.javaClass?.methods
            val method = methods?.find { it.name == "setPrimaryClip" }
            
            when (method?.parameterTypes?.size) {
                2 -> method.invoke(clipboardService, clipData, "android")
                3 -> method.invoke(clipboardService, clipData, "android", 0)
                else -> Log.e("ClipboardController", "Unknown setPrimaryClip signature")
            }
        } catch (e: Exception) {
            Log.e("ClipboardController", "Set clipboard failed", e)
        }
    }

    fun getText(): String? {
        return try {
            val methods = clipboardService?.javaClass?.methods
            val method = methods?.find { it.name == "getPrimaryClip" }
            val clipData = when (method?.parameterTypes?.size) {
                1 -> method.invoke(clipboardService, "android")
                2 -> method.invoke(clipboardService, "android", 0)
                else -> null
            } as? ClipData
            clipData?.getItemAt(0)?.text?.toString()
        } catch (e: Exception) {
            Log.e("ClipboardController", "Get clipboard failed", e)
            null
        }
    }
}
