// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import android.net.Uri
import com.rosan.installer.domain.settings.model.config.Authorizer
import com.rosan.installer.domain.settings.repository.AppSettingsRepository
import com.rosan.installer.domain.settings.repository.BooleanSetting
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

class AirSendRuntimeRepositoryImpl(
    private val ipcClient: AirSendIpcClient,
    private val androidRuntimeReader: AndroidRuntimeReader,
    appScope: CoroutineScope,
    private val appSettingsRepository: AppSettingsRepository? = null
) : AirSendRuntimeRepository {
    private val refreshMutex = Mutex()
    private val configUpdateMutex = Mutex()
    private val _state = MutableStateFlow(readLocalState())
    override val state: StateFlow<AirSendRuntimeState> = _state.asStateFlow()

    init {
        appScope.launch {
            var lastSequence = 0L
            ipcClient.events().collectLatest { event ->
                if (event.sequence > lastSequence) {
                    lastSequence = event.sequence
                    refresh(showIndicator = false)
                }
            }
        }
    }

    override suspend fun refresh(showIndicator: Boolean) = refreshMutex.withLock {
        _state.update { readLocalState(it).copy(isRefreshing = showIndicator) }
        val root = androidRuntimeReader.rootDaemonSnapshot()
        val authorizationMode = appSettingsRepository
            ?.preferencesFlow
            ?.first()
            ?.authorizer
            ?.toAirSendAuthorizationMode()
            ?: _state.value.authorizationMode
        val storedServiceNotificationEnabled = appSettingsRepository
            ?.getBoolean(BooleanSetting.AirSendShowServiceNotification, false)
            ?.first()
            ?: _state.value.serviceNotificationEnabled
        val serviceNotificationEnabled = storedServiceNotificationEnabled ||
            !AirSendForegroundServicePolicy.canRunWithoutAppService(root)
        _state.update {
            it.copy(
                authorizationMode = authorizationMode,
                serviceNotificationEnabled = serviceNotificationEnabled,
                rootAvailable = root.rootAvailable,
                rootProvider = root.rootProvider,
                moduleInstalled = root.moduleInstalled,
                moduleEnabled = root.moduleEnabled,
                moduleVersion = root.moduleVersion,
                moduleVersionCode = root.moduleVersionCode,
                daemonProcessRunning = root.daemonProcessRunning,
                appVersion = com.rosan.installer.BuildConfig.VERSION_NAME,
                appVersionCode = com.rosan.installer.BuildConfig.VERSION_CODE
            )
        }
        runCatching {
            loadRefreshSnapshot()
        }.onSuccess { snapshot ->
            val hello = snapshot.hello
            val daemon = snapshot.daemon
            val compatibilityWarnings = if (hello.protocolVersion == SUPPORTED_PROTOCOL_VERSION) {
                emptyList()
            } else {
                listOf("protocol_version_mismatch")
            }
            _state.value = readLocalState(_state.value).copy(
                daemonReachable = true,
                peers = snapshot.peers,
                protocolVersion = hello.protocolVersion,
                daemonVersion = hello.daemonVersion,
                configVersion = daemon.configVersion,
                historySchemaVersion = daemon.historySchemaVersion,
                daemonStartedAtMs = daemon.startedAtMs,
                preferredTargetId = snapshot.config.preferredTarget,
                receivePolicy = snapshot.config.receivePolicy,
                trustedPeerFingerprints = snapshot.config.trustedPeerFingerprints
                    .mapTo(mutableSetOf()) { it.lowercase() },
                downloadDestination = snapshot.config.downloadDestination,
                mediaDestination = snapshot.config.mediaDestination,
                clipboardSyncEnabled = snapshot.config.clipboardSyncEnabled,
                screenshotSyncEnabled = snapshot.config.screenshotSyncEnabled,
                historyLimitPerDirection = snapshot.config.historyLimitPerDirection,
                historyCount = daemon.historyCount,
                activeTransferCount = daemon.activeTransferCount,
                transfers = snapshot.transfers,
                healthWarnings = daemon.healthWarnings + compatibilityWarnings,
                tlsFingerprint = daemon.tlsFingerprint,
                tlsReady = daemon.tlsReady,
                transportProtocol = daemon.transportProtocol,
                transportPreference = snapshot.config.transportPreference,
                reverseClipboardIpcReady = daemon.reverseClipboardIpcReady,
                storageReady = daemon.storageReady,
                networkBinding = daemon.networkBinding,
                transferPort = daemon.transferPort,
                discoveryPort = daemon.discoveryPort,
                capabilities = hello.capabilities.toSet(),
                isRefreshing = false,
                lastError = null
            )
            androidRuntimeReader.publishShareTargets(
                peers = snapshot.peers,
                preferredTargetId = snapshot.config.preferredTarget
            )
        }.onFailure { error ->
            _state.value = readLocalState(_state.value).copy(
                daemonReachable = false,
                isRefreshing = false,
                lastError = error.message ?: "AirSend daemon unavailable"
            )
        }
        Unit
    }

    private suspend fun loadRefreshSnapshot(): RefreshSnapshot {
        val hello = AirSendIpcCodec.json.decodeFromJsonElement<AirSendHelloSnapshot>(
            ipcClient.request("hello")
        )
        if ("get_snapshot" in hello.capabilities) {
            val payload = AirSendIpcCodec.json.decodeFromJsonElement<AirSendSnapshotPayload>(
                ipcClient.request("get_snapshot")
            )
            return RefreshSnapshot(
                hello = hello,
                daemon = payload.daemon,
                config = payload.config,
                peers = payload.peers.map { it.toRuntimePeer(payload.config.preferredTarget) },
                transfers = mergeTransfers(payload.transfers, payload.history)
            )
        }

        val daemon = AirSendIpcCodec.json.decodeFromJsonElement<AirSendDaemonStateSnapshot>(
            ipcClient.request("get_state")
        )
        val config = AirSendIpcCodec.json.decodeFromJsonElement<AirSendConfigSnapshot>(
            ipcClient.request("get_config")
        )
        val peers = AirSendIpcCodec.json
            .decodeFromJsonElement<List<AirSendPeerSnapshot>>(ipcClient.request("get_peers"))
            .map { it.toRuntimePeer(config.preferredTarget) }
        val activeTransfers = if ("get_transfers" in hello.capabilities) {
            AirSendIpcCodec.json.decodeFromJsonElement<List<AirSendTransferSnapshot>>(
                ipcClient.request("get_transfers")
            )
        } else {
            emptyList()
        }
        val history = if ("get_history" in hello.capabilities) {
            AirSendIpcCodec.json.decodeFromJsonElement<List<AirSendTransferSnapshot>>(
                ipcClient.request(
                    op = "get_history",
                    payload = buildJsonObject {
                        put("limit", config.historyLimitPerDirection * 2)
                    }
                )
            )
        } else {
            emptyList()
        }
        return RefreshSnapshot(hello, daemon, config, peers, mergeTransfers(activeTransfers, history))
    }

    private fun mergeTransfers(
        activeTransfers: List<AirSendTransferSnapshot>,
        history: List<AirSendTransferSnapshot>
    ): List<AirSendTransferSnapshot> {
        val activeIds = activeTransfers.mapTo(mutableSetOf()) { it.id }
        val durableHistory = history.map { transfer ->
            if (transfer.id in activeIds) transfer else transfer.copy(retryable = false)
        }
        return (activeTransfers + durableHistory)
            .distinctBy { it.id }
            .sortedByDescending { it.startedAtMs }
    }

    override suspend fun discoverNow() {
        ipcClient.request("discover_now")
    }

    override suspend fun startService() {
        val root = androidRuntimeReader.rootDaemonSnapshot()
        if (AirSendForegroundServicePolicy.canRunWithoutAppService(root)) {
            androidRuntimeReader.startRootDaemon()
            waitForDaemonAfterRootStart()
        } else {
            androidRuntimeReader.startService()
        }
        updateLocalState()
    }

    override suspend fun stopService() {
        val root = androidRuntimeReader.rootDaemonSnapshot()
        if (AirSendForegroundServicePolicy.canRunWithoutAppService(root)) {
            androidRuntimeReader.stopRootDaemon()
        } else {
            androidRuntimeReader.stopService()
        }
        updateLocalState()
    }

    override suspend fun restartService() {
        val root = androidRuntimeReader.rootDaemonSnapshot()
        if (AirSendForegroundServicePolicy.canRunWithoutAppService(root)) {
            androidRuntimeReader.stopRootDaemon()
            androidRuntimeReader.startRootDaemon()
            waitForDaemonAfterRootStart()
        } else {
            androidRuntimeReader.stopService()
            androidRuntimeReader.startService()
        }
        updateLocalState()
    }

    override suspend fun restartWholeService() {
        val serviceWasRunning = androidRuntimeReader.snapshot().serviceRunning
        val root = androidRuntimeReader.rootDaemonSnapshot()
        val rootDaemonShouldRun = if (appSettingsRepository == null) {
            // Preserve the legacy repository fallback for callers without settings.
            root.rootAvailable && root.daemonProcessRunning
        } else {
            state.value.usesRootAuthorization &&
                root.rootAvailable &&
                root.moduleInstalled &&
                root.moduleEnabled
        }

        androidRuntimeReader.stopService()
        if (serviceWasRunning) {
            waitForForegroundServiceStop()
        }
        if (rootDaemonShouldRun) {
            androidRuntimeReader.stopRootDaemon()
            androidRuntimeReader.startRootDaemon()
            waitForDaemonAfterRootStart()
        }
        if (!rootDaemonShouldRun || state.value.serviceNotificationEnabled) {
            androidRuntimeReader.startService()
        }
        updateLocalState()
    }

    override suspend fun restartDaemon() {
        if (state.value.daemonReachable) {
            ipcClient.request("restart_daemon")
        } else if (state.value.usesRootAuthorization || appSettingsRepository == null) {
            // The app always injects settings; this fallback keeps legacy callers deterministic.
            androidRuntimeReader.repairRootDaemon()
        } else {
            // In non-root mode the bundled daemon is owned by the foreground service.
            androidRuntimeReader.stopService()
            androidRuntimeReader.startService()
        }
    }

    override fun setBootStartEnabled(enabled: Boolean) {
        androidRuntimeReader.setBootStartEnabled(enabled)
        updateLocalState()
    }

    override suspend fun setServiceNotificationEnabled(enabled: Boolean) {
        if (!enabled) {
            val root = androidRuntimeReader.rootDaemonSnapshot()
            require(AirSendForegroundServicePolicy.canRunWithoutAppService(root)) {
                "Android requires a foreground-service notification when the Root daemon is unavailable"
            }
        }
        appSettingsRepository?.putBoolean(
            BooleanSetting.AirSendShowServiceNotification,
            enabled
        ) ?: return
        if (enabled) {
            androidRuntimeReader.startService()
        } else {
            androidRuntimeReader.stopService()
            waitForForegroundServiceStop()
        }
        _state.update { it.copy(serviceNotificationEnabled = enabled) }
    }

    override suspend fun setPreferredTarget(targetId: String?) {
        require(targetId == null || targetId.isNotBlank()) { "Target id must not be blank" }
        ipcClient.request(
            op = "set_preferred_target",
            payload = buildJsonObject {
                targetId?.let { put("targetId", it) }
            }
        )
        androidRuntimeReader.publishShareTargets(state.value.peers, targetId)
    }

    override suspend fun sendText(text: String, targetId: String?) {
        require(text.isNotBlank()) { "Text must not be blank" }
        val target = targetId ?: state.value.preferredTargetId
        require(!target.isNullOrBlank()) { "Select a target before sending" }
        ipcClient.request(
            op = "send_text",
            payload = buildJsonObject {
                put("text", text)
                put("targetId", target)
            }
        )
        androidRuntimeReader.reportShareTargetUsed(target)
    }

    override suspend fun sendClipboardText(targetId: String?) {
        val text = androidRuntimeReader.clipboardText()
        require(!text.isNullOrBlank()) { "Clipboard has no text to send" }
        sendText(text, targetId)
    }

    override suspend fun sendFiles(uris: List<Uri>, targetId: String?) {
        require(uris.isNotEmpty()) { "No files selected" }
        val target = targetId ?: state.value.preferredTargetId
        require(!target.isNullOrBlank()) { "Select a target before sending" }
        val paths = withContext(Dispatchers.IO) {
            uris.map { uri ->
                androidRuntimeReader.resolvePath(uri)
                    ?.takeIf { it.isNotBlank() }
                    ?: error("Unable to read selected file: $uri")
            }
        }
        ipcClient.request(
            op = "send_files",
            payload = buildJsonObject {
                put("paths", JsonArray(paths.map(::JsonPrimitive)))
                put("targetId", target)
            }
        )
        androidRuntimeReader.reportShareTargetUsed(target)
    }

    override suspend fun cancelTransfer(transferId: String) {
        require(transferId.isNotBlank()) { "Transfer id must not be blank" }
        ipcClient.request(
            op = "cancel_transfer",
            payload = buildJsonObject { put("id", transferId) }
        )
    }

    override suspend fun retryTransfer(transferId: String) {
        require(transferId.isNotBlank()) { "Transfer id must not be blank" }
        ipcClient.request(
            op = "retry_transfer",
            payload = buildJsonObject { put("id", transferId) }
        )
    }

    override suspend fun acceptTransfer(transferId: String) {
        decideTransfer("accept_transfer", transferId)
    }

    override suspend fun declineTransfer(transferId: String) {
        decideTransfer("decline_transfer", transferId)
    }

    override suspend fun setReceivePolicy(policy: String) {
        require(policy in setOf("full_access", "trusted_only", "off")) {
            "Unsupported receive policy: $policy"
        }
        updateConfig(buildJsonObject { put("receivePolicy", policy) })
    }

    override suspend fun setClipboardSyncEnabled(enabled: Boolean) {
        updateConfig(buildJsonObject { put("clipboardSyncEnabled", enabled) })
    }

    override suspend fun setScreenshotSyncEnabled(enabled: Boolean) {
        updateConfig(buildJsonObject { put("screenshotSyncEnabled", enabled) })
    }

    override suspend fun setHistoryLimitPerDirection(limit: Int) {
        require(limit in HISTORY_LIMIT_OPTIONS) { "Unsupported history limit: $limit" }
        updateConfig(buildJsonObject { put("historyLimitPerDirection", limit) })
    }

    override suspend fun setTransportPreference(preference: String) {
        require(preference in setOf("https", "http_compatibility")) {
            "Unsupported transport preference: $preference"
        }
        updateConfig(buildJsonObject { put("transportPreference", preference) })
    }

    override suspend fun setPeerTrusted(fingerprint: String, trusted: Boolean) {
        val normalized = fingerprint.trim().lowercase()
        require(normalized.isNotEmpty()) { "Peer fingerprint must not be blank" }
        ipcClient.request(
            op = "set_peer_trust",
            payload = buildJsonObject {
                put("fingerprint", normalized)
                put("trusted", trusted)
            }
        )
    }

    override suspend fun setDownloadDestination(uri: Uri) {
        val path = androidRuntimeReader.resolveDirectory(uri)
            ?: error("Selected folder is not available as a local storage path")
        updateConfig(buildJsonObject { put("downloadDestination", path) })
    }

    override suspend fun setMediaDestination(uri: Uri) {
        val path = androidRuntimeReader.resolveDirectory(uri)
            ?: error("Selected folder is not available as a local storage path")
        updateConfig(buildJsonObject { put("mediaDestination", path) })
    }

    override suspend fun addManualPeer(
        alias: String,
        address: String,
        port: Int,
        fingerprint: String?
    ) {
        require(address.isNotBlank()) { "Address must not be blank" }
        require(port in 1..65535) { "Port must be between 1 and 65535" }
        ipcClient.request(
            op = "add_manual_peer",
            payload = buildJsonObject {
                put("alias", alias.trim())
                put("address", address.trim())
                put("port", port)
                fingerprint?.trim()?.takeIf { it.isNotEmpty() }?.let {
                    put("fingerprint", it)
                }
            }
        )
    }

    override suspend fun removeManualPeer(id: String) {
        require(id.isNotBlank()) { "Manual peer id must not be blank" }
        ipcClient.request(
            op = "remove_manual_peer",
            payload = buildJsonObject { put("id", id) }
        )
    }

    override suspend fun deleteHistory(id: String) {
        require(id.isNotBlank()) { "History id must not be blank" }
        ipcClient.request(
            op = "delete_history",
            payload = buildJsonObject { put("id", id) }
        )
    }

    override suspend fun clearHistory(direction: String) {
        require(direction == "outgoing" || direction == "incoming") {
            "Unsupported history direction: $direction"
        }
        ipcClient.request(
            op = "clear_history_direction",
            payload = buildJsonObject { put("direction", direction) }
        )
    }

    override fun openReceivedFile(path: String, mimeType: String) {
        androidRuntimeReader.openFile(path, mimeType)
    }

    override fun shareReceivedFile(path: String, mimeType: String) {
        androidRuntimeReader.shareFile(path, mimeType)
    }

    override suspend fun exportLogs(uri: Uri) {
        val response = ipcClient.request(
            op = "get_logs",
            payload = buildJsonObject { put("maxBytes", 262_144) }
        ).jsonObject
        val tail = response["tail"]?.jsonPrimitive?.content.orEmpty()
        withContext(Dispatchers.IO) {
            androidRuntimeReader.writeDocument(uri, tail)
        }
    }

    override suspend fun clearLogs() {
        ipcClient.request("clear_logs")
    }

    private suspend fun decideTransfer(op: String, transferId: String) {
        require(transferId.isNotBlank()) { "Transfer id must not be blank" }
        ipcClient.request(
            op = op,
            payload = buildJsonObject { put("id", transferId) }
        )
    }

    private suspend fun updateConfig(patch: kotlinx.serialization.json.JsonObject) =
        configUpdateMutex.withLock {
            try {
                ipcClient.request(op = "patch_config", payload = patch)
            } catch (error: AirSendIpcException) {
                if (error.code != "unknown_operation") throw error
                val current = ipcClient.request("get_config").jsonObject
                ipcClient.request(
                    op = "set_config",
                    payload = kotlinx.serialization.json.JsonObject(current + patch)
                )
            }
    }

    private fun updateLocalState() {
        _state.update { readLocalState(it) }
    }

    private suspend fun waitForDaemonAfterRootStart() {
        repeat(ROOT_DAEMON_START_ATTEMPTS) {
            if (runCatching { ipcClient.request("hello") }.isSuccess) return
            kotlinx.coroutines.delay(ROOT_DAEMON_START_POLL_MS)
        }
    }

    private suspend fun waitForForegroundServiceStop() {
        repeat(FOREGROUND_SERVICE_STOP_ATTEMPTS) {
            if (!androidRuntimeReader.snapshot().serviceRunning) return
            kotlinx.coroutines.delay(FOREGROUND_SERVICE_STOP_POLL_MS)
        }
    }

    private fun readLocalState(
        previous: AirSendRuntimeState = AirSendRuntimeState()
    ): AirSendRuntimeState {
        val local = androidRuntimeReader.snapshot()
        return previous.copy(
            serviceRunning = local.serviceRunning,
            bootStartEnabled = local.bootStartEnabled,
            notificationPermissionGranted = local.notificationPermissionGranted,
            storagePermissionGranted = local.storagePermissionGranted
        )
    }

    private fun AirSendPeerSnapshot.toRuntimePeer(preferredTarget: String?): AirSendPeer = AirSendPeer(
        id = id,
        alias = alias,
        deviceModel = deviceModel ?: "Unknown",
        deviceType = deviceType,
        version = version,
        fingerprint = fingerprint,
        address = address,
        protocol = protocol,
        selected = id == preferredTarget,
        manual = manual,
        online = online
    )

    private data class RefreshSnapshot(
        val hello: AirSendHelloSnapshot,
        val daemon: AirSendDaemonStateSnapshot,
        val config: AirSendConfigSnapshot,
        val peers: List<AirSendPeer>,
        val transfers: List<AirSendTransferSnapshot>
    )

    companion object {
        private const val SUPPORTED_PROTOCOL_VERSION = 1
        private const val ROOT_DAEMON_START_ATTEMPTS = 20
        private const val ROOT_DAEMON_START_POLL_MS = 100L
        private const val FOREGROUND_SERVICE_STOP_ATTEMPTS = 20
        private const val FOREGROUND_SERVICE_STOP_POLL_MS = 50L
        private val HISTORY_LIMIT_OPTIONS = setOf(10, 30, 50, 100)
    }
}

private fun Authorizer.toAirSendAuthorizationMode(): AirSendAuthorizationMode = when (this) {
    Authorizer.Root -> AirSendAuthorizationMode.Root
    Authorizer.Shizuku -> AirSendAuthorizationMode.Shizuku
    Authorizer.Dhizuku -> AirSendAuthorizationMode.Dhizuku
    Authorizer.Customize -> AirSendAuthorizationMode.Customize
    Authorizer.Global,
    Authorizer.None -> AirSendAuthorizationMode.AppProcess
}
