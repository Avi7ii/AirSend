// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

data class AirSendPeer(
    val id: String,
    val alias: String,
    val deviceModel: String,
    val deviceType: String? = null,
    val version: String = "",
    val fingerprint: String = "",
    val address: String = "",
    val protocol: String = "",
    val selected: Boolean = false,
    val manual: Boolean = false,
    val online: Boolean = true
)

data class AirSendRuntimeState(
    val serviceRunning: Boolean = false,
    val daemonReachable: Boolean = false,
    val authorizationMode: AirSendAuthorizationMode = AirSendAuthorizationMode.AppProcess,
    val rootAvailable: Boolean = false,
    val rootProvider: String? = null,
    val moduleInstalled: Boolean = false,
    val moduleEnabled: Boolean = false,
    val moduleVersion: String? = null,
    val daemonProcessRunning: Boolean = false,
    val appVersion: String = "",
    val appVersionCode: Int = 0,
    val bootStartEnabled: Boolean = true,
    val serviceNotificationEnabled: Boolean = false,
    val notificationPermissionGranted: Boolean = true,
    val storagePermissionGranted: Boolean = true,
    val peers: List<AirSendPeer> = emptyList(),
    val protocolVersion: Int? = null,
    val daemonVersion: String? = null,
    val configVersion: Int? = null,
    val historySchemaVersion: Int? = null,
    val daemonStartedAtMs: Long? = null,
    val preferredTargetId: String? = null,
    val receivePolicy: String = "full_access",
    val trustedPeerFingerprints: Set<String> = emptySet(),
    val downloadDestination: String = "/sdcard/Download/AirSend",
    val mediaDestination: String = "/sdcard/Pictures/AirSend",
    val clipboardSyncEnabled: Boolean = true,
    val screenshotSyncEnabled: Boolean = true,
    val historyLimitPerDirection: Int = 30,
    val historyCount: Int = 0,
    val activeTransferCount: Int = 0,
    val transfers: List<AirSendTransferSnapshot> = emptyList(),
    val healthWarnings: List<String> = emptyList(),
    val tlsFingerprint: String? = null,
    val tlsReady: Boolean = false,
    val transportProtocol: String? = null,
    val transportPreference: String = "https",
    val reverseClipboardIpcReady: Boolean = false,
    val storageReady: Boolean = false,
    val networkBinding: String? = null,
    val transferPort: Int? = null,
    val discoveryPort: Int? = null,
    val capabilities: Set<String> = emptySet(),
    val isRefreshing: Boolean = false,
    val lastError: String? = null
) {
    val usesRootAuthorization: Boolean
        get() = authorizationMode == AirSendAuthorizationMode.Root

    val canDisableServiceNotification: Boolean
        get() = rootAvailable && moduleInstalled && moduleEnabled

    val backgroundServiceRunning: Boolean
        get() = if (canDisableServiceNotification) daemonProcessRunning else serviceRunning

    val lspActivationPending: Boolean
        get() = usesRootAuthorization && moduleInstalled && !moduleEnabled

    val rootRuntimeHealthy: Boolean
        get() = !usesRootAuthorization || (
            rootAvailable &&
                moduleInstalled &&
                moduleEnabled &&
                daemonProcessRunning
            )
}
