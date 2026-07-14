package com.airsend

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.rosan.installer.ui.page.airsend.runtime.AirSendIpcCodec
import com.rosan.installer.ui.page.airsend.runtime.AirSendSnapshotPayload
import com.rosan.installer.ui.page.airsend.runtime.LocalSocketAirSendIpcClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.decodeFromJsonElement

class AirSendShareShortcutRefreshReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val ipc = LocalSocketAirSendIpcClient()
                val snapshot = AirSendIpcCodec.json.decodeFromJsonElement<AirSendSnapshotPayload>(
                    ipc.request("get_snapshot")
                )
                AirSendShareShortcutPublisher.publish(
                    context = context.applicationContext,
                    targets = snapshot.peers.map { peer ->
                        AirSendShareTarget(
                            id = peer.id,
                            alias = peer.alias,
                            deviceType = peer.deviceType,
                            online = peer.online
                        )
                    },
                    preferredTargetId = snapshot.config.preferredTarget
                )
            } catch (error: Exception) {
                Log.d(TAG, "Shortcut refresh after app update skipped: ${error.message}")
            } finally {
                pendingResult.finish()
            }
        }
    }

    private companion object {
        const val TAG = "AirSendShareShortcuts"
    }
}
