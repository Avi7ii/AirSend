// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend

import androidx.annotation.StringRes
import com.rosan.installer.R
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeState

enum class AirSendHomeStatusTone {
    Neutral,
    Ready,
    Critical
}

enum class AirSendHomeStatusKind {
    Checking,
    RootPermissionMissing,
    RootModuleMissing,
    LsposedInactive,
    NotificationPermissionMissing,
    MediaPermissionMissing,
    BackgroundServiceOffline,
    DaemonOffline,
    TlsUnavailable,
    StorageUnavailable,
    NoNearbyDevices,
    Ready
}

data class AirSendHomeStatus(
    val kind: AirSendHomeStatusKind,
    val tone: AirSendHomeStatusTone,
    @StringRes val titleRes: Int,
    @StringRes val descriptionRes: Int,
    val descriptionCount: Int? = null
)

/**
 * Produces one user-facing home state from runtime facts.
 *
 * Blocking failures take priority and are critical. A healthy runtime with no
 * online peers is an ordinary discovery state, so it stays neutral instead of
 * being presented as an error.
 */
fun AirSendRuntimeState.homeStatus(): AirSendHomeStatus {
    fun status(
        kind: AirSendHomeStatusKind,
        tone: AirSendHomeStatusTone,
        @StringRes titleRes: Int,
        @StringRes descriptionRes: Int,
        descriptionCount: Int? = null
    ) = AirSendHomeStatus(kind, tone, titleRes, descriptionRes, descriptionCount)

    if (appVersion.isBlank()) {
        return status(
            AirSendHomeStatusKind.Checking,
            AirSendHomeStatusTone.Neutral,
            R.string.airsend_home_checking,
            R.string.airsend_home_checking_desc
        )
    }

    if (usesRootAuthorization && !rootAvailable) {
        return status(
            AirSendHomeStatusKind.RootPermissionMissing,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_root_permission,
            R.string.airsend_home_root_permission_desc
        )
    }

    if (usesRootAuthorization && !moduleInstalled) {
        return status(
            AirSendHomeStatusKind.RootModuleMissing,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_root_module_missing,
            R.string.airsend_home_root_module_missing_desc
        )
    }

    if (usesRootAuthorization && !moduleEnabled) {
        return status(
            AirSendHomeStatusKind.LsposedInactive,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_lsposed_inactive,
            R.string.airsend_home_lsposed_inactive_desc
        )
    }

    if (serviceNotificationEnabled && !notificationPermissionGranted) {
        return status(
            AirSendHomeStatusKind.NotificationPermissionMissing,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_notification_permission,
            R.string.airsend_home_notification_permission_desc
        )
    }

    if (!storagePermissionGranted) {
        return status(
            AirSendHomeStatusKind.MediaPermissionMissing,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_media_permission,
            R.string.airsend_home_media_permission_desc
        )
    }

    if (!backgroundServiceRunning) {
        return status(
            AirSendHomeStatusKind.BackgroundServiceOffline,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_service_offline,
            R.string.airsend_home_service_offline_desc
        )
    }

    if (!daemonReachable) {
        return status(
            AirSendHomeStatusKind.DaemonOffline,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_daemon_offline,
            R.string.airsend_home_daemon_offline_desc
        )
    }

    if (!tlsReady) {
        return status(
            AirSendHomeStatusKind.TlsUnavailable,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_tls_unavailable,
            R.string.airsend_home_tls_unavailable_desc
        )
    }

    if (!storageReady) {
        return status(
            AirSendHomeStatusKind.StorageUnavailable,
            AirSendHomeStatusTone.Critical,
            R.string.airsend_home_storage_unavailable,
            R.string.airsend_home_storage_unavailable_desc
        )
    }

    val onlinePeerCount = peers.count { it.online }
    if (onlinePeerCount == 0) {
        return status(
            AirSendHomeStatusKind.NoNearbyDevices,
            AirSendHomeStatusTone.Neutral,
            R.string.airsend_home_no_nearby_devices,
            R.string.airsend_home_no_nearby_devices_desc
        )
    }

    return status(
        AirSendHomeStatusKind.Ready,
        AirSendHomeStatusTone.Ready,
        R.string.airsend_status_ready,
        R.string.airsend_home_ready_desc,
        descriptionCount = onlinePeerCount
    )
}
