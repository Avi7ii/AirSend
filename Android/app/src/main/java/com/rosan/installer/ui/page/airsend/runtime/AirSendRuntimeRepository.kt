// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import android.net.Uri
import kotlinx.coroutines.flow.StateFlow

interface AirSendRuntimeRepository {
    val state: StateFlow<AirSendRuntimeState>

    suspend fun refresh()
    fun startService()
    fun stopService()
    fun restartService()
    fun setBootStartEnabled(enabled: Boolean)
    suspend fun setPreferredTarget(targetId: String?)
    suspend fun sendText(text: String, targetId: String? = null)
    suspend fun sendClipboardText(targetId: String? = null)
    suspend fun sendFiles(uris: List<Uri>, targetId: String? = null)
    suspend fun cancelTransfer(transferId: String)
    suspend fun retryTransfer(transferId: String)
}
