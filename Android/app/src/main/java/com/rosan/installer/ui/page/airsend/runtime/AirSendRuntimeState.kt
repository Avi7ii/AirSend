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
    val manual: Boolean = false
)

data class AirSendRuntimeState(
    val serviceRunning: Boolean = false,
    val daemonReachable: Boolean = false,
    val bootStartEnabled: Boolean = true,
    val notificationPermissionGranted: Boolean = true,
    val storagePermissionGranted: Boolean = true,
    val peers: List<AirSendPeer> = emptyList(),
    val protocolVersion: Int? = null,
    val daemonVersion: String? = null,
    val configVersion: Int? = null,
    val historySchemaVersion: Int? = null,
    val daemonStartedAtMs: Long? = null,
    val preferredTargetId: String? = null,
    val historyCount: Int = 0,
    val activeTransferCount: Int = 0,
    val transfers: List<AirSendTransferSnapshot> = emptyList(),
    val healthWarnings: List<String> = emptyList(),
    val tlsFingerprint: String? = null,
    val transportProtocol: String? = null,
    val capabilities: Set<String> = emptySet(),
    val isRefreshing: Boolean = false,
    val lastError: String? = null
)
