// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import android.net.Uri

sealed interface AirSendRuntimeAction {
    data object Refresh : AirSendRuntimeAction
    data object RefreshSilently : AirSendRuntimeAction
    data object DiscoverNow : AirSendRuntimeAction
    data object StartService : AirSendRuntimeAction
    data object StopService : AirSendRuntimeAction
    data object RestartService : AirSendRuntimeAction
    data object RestartWholeService : AirSendRuntimeAction
    data object RestartDaemon : AirSendRuntimeAction
    data class SetBootStartEnabled(val enabled: Boolean) : AirSendRuntimeAction
    data class SetServiceNotificationEnabled(val enabled: Boolean) : AirSendRuntimeAction
    data class SelectPeer(val targetId: String) : AirSendRuntimeAction
    data class SendClipboardText(val targetId: String? = null) : AirSendRuntimeAction
    data class SendFiles(val uris: List<Uri>, val targetId: String? = null) : AirSendRuntimeAction
    data class CancelTransfer(val transferId: String) : AirSendRuntimeAction
    data class RetryTransfer(val transferId: String) : AirSendRuntimeAction
    data class AcceptTransfer(val transferId: String) : AirSendRuntimeAction
    data class DeclineTransfer(val transferId: String) : AirSendRuntimeAction
    data class SetReceivePolicy(val policy: String) : AirSendRuntimeAction
    data class SetClipboardSyncEnabled(val enabled: Boolean) : AirSendRuntimeAction
    data class SetScreenshotSyncEnabled(val enabled: Boolean) : AirSendRuntimeAction
    data class SetHistoryLimitPerDirection(val limit: Int) : AirSendRuntimeAction
    data class SetTransportPreference(val preference: String) : AirSendRuntimeAction
    data class SetPeerTrusted(val fingerprint: String, val trusted: Boolean) : AirSendRuntimeAction
    data class SetDownloadDestination(val uri: Uri) : AirSendRuntimeAction
    data class SetMediaDestination(val uri: Uri) : AirSendRuntimeAction
    data class AddManualPeer(
        val alias: String,
        val address: String,
        val port: Int,
        val fingerprint: String? = null
    ) : AirSendRuntimeAction
    data class RemoveManualPeer(val id: String) : AirSendRuntimeAction
    data class DeleteHistory(val id: String) : AirSendRuntimeAction
    data class ClearHistory(val direction: String) : AirSendRuntimeAction
    data class OpenReceivedFile(val path: String, val mimeType: String) : AirSendRuntimeAction
    data class ShareReceivedFile(val path: String, val mimeType: String) : AirSendRuntimeAction
    data class ExportLogs(val uri: Uri) : AirSendRuntimeAction
    data object ClearLogs : AirSendRuntimeAction
}
