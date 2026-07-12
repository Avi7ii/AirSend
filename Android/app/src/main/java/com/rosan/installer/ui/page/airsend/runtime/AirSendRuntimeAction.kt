// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import android.net.Uri

sealed interface AirSendRuntimeAction {
    data object Refresh : AirSendRuntimeAction
    data object StartService : AirSendRuntimeAction
    data object StopService : AirSendRuntimeAction
    data object RestartService : AirSendRuntimeAction
    data class SetBootStartEnabled(val enabled: Boolean) : AirSendRuntimeAction
    data class SelectPeer(val targetId: String) : AirSendRuntimeAction
    data class SendClipboardText(val targetId: String? = null) : AirSendRuntimeAction
    data class SendFiles(val uris: List<Uri>, val targetId: String? = null) : AirSendRuntimeAction
    data class CancelTransfer(val transferId: String) : AirSendRuntimeAction
    data class RetryTransfer(val transferId: String) : AirSendRuntimeAction
}
