// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import android.net.Uri
import kotlinx.coroutines.flow.StateFlow

interface AirSendRuntimeRepository {
    val state: StateFlow<AirSendRuntimeState>

    suspend fun refresh(showIndicator: Boolean = false)
    suspend fun discoverNow()
    suspend fun startService()
    suspend fun stopService()
    suspend fun restartService()
    suspend fun restartWholeService()
    suspend fun restartDaemon()
    fun setBootStartEnabled(enabled: Boolean)
    suspend fun setServiceNotificationEnabled(enabled: Boolean)
    suspend fun setPreferredTarget(targetId: String?)
    suspend fun sendText(text: String, targetId: String? = null)
    suspend fun sendClipboardText(targetId: String? = null)
    suspend fun sendFiles(uris: List<Uri>, targetId: String? = null)
    suspend fun cancelTransfer(transferId: String)
    suspend fun retryTransfer(transferId: String)
    suspend fun acceptTransfer(transferId: String)
    suspend fun declineTransfer(transferId: String)
    suspend fun setReceivePolicy(policy: String)
    suspend fun setClipboardSyncEnabled(enabled: Boolean)
    suspend fun setScreenshotSyncEnabled(enabled: Boolean)
    suspend fun setHistoryLimitPerDirection(limit: Int)
    suspend fun setTransportPreference(preference: String)
    suspend fun setPeerTrusted(fingerprint: String, trusted: Boolean)
    suspend fun setDownloadDestination(uri: Uri)
    suspend fun setMediaDestination(uri: Uri)
    suspend fun addManualPeer(alias: String, address: String, port: Int, fingerprint: String?)
    suspend fun removeManualPeer(id: String)
    suspend fun deleteHistory(id: String)
    suspend fun clearHistory(direction: String)
    fun openReceivedFile(path: String, mimeType: String)
    fun shareReceivedFile(path: String, mimeType: String)
    suspend fun exportLogs(uri: Uri)
    suspend fun clearLogs()
}
