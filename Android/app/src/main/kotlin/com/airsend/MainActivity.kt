package com.airsend

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        val btn = Button(this).apply {
            text = "启动 AirSend 同步服务"
            setOnClickListener {
                startAirSendService()
            }
        }
        setContentView(btn)

        // 致命暗坑三：权限申请
        requestPermissionsIfNeed()

        // 提示：现在基础同步不再强制要求 App 进程拥有 Root 权限
        // 因为守护进程已由 Magisk 系统级拉起
    }

    private fun requestPermissionsIfNeed() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermissions(arrayOf(
                android.Manifest.permission.READ_MEDIA_IMAGES,
                android.Manifest.permission.READ_MEDIA_VIDEO
            ), 101)
        } else {
            requestPermissions(arrayOf(
                android.Manifest.permission.READ_EXTERNAL_STORAGE
            ), 101)
        }
    }

    private fun startAirSendService() {
        val intent = Intent(this, AirSendService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        Toast.makeText(this, "AirSend 服务已在后台启动", Toast.LENGTH_SHORT).show()
    }
}