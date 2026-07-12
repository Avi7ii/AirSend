// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

class AirSendRuntimeRepositoryImpl(
    private val ipcClient: AirSendIpcClient,
    private val androidRuntimeReader: AndroidRuntimeReader,
    appScope: CoroutineScope
) : AirSendRuntimeRepository {
    private val refreshMutex = Mutex()
    private val _state = MutableStateFlow(readLocalState())
    override val state: StateFlow<AirSendRuntimeState> = _state.asStateFlow()

    init {
        appScope.launch {
            var lastSequence = 0L
            ipcClient.events().collectLatest { event ->
                if (event.sequence > lastSequence) {
                    lastSequence = event.sequence
                    refresh()
                }
            }
        }
    }

    override suspend fun refresh() = refreshMutex.withLock {
        _state.update { readLocalState(it).copy(isRefreshing = true) }
        runCatching {
            val hello = AirSendIpcCodec.json.decodeFromJsonElement<AirSendHelloSnapshot>(
                ipcClient.request("hello")
            )
            val daemon = AirSendIpcCodec.json.decodeFromJsonElement<AirSendDaemonStateSnapshot>(
                ipcClient.request("get_state")
            )
            val config = AirSendIpcCodec.json.decodeFromJsonElement<AirSendConfigSnapshot>(
                ipcClient.request("get_config")
            )
            val peers = AirSendIpcCodec.json
                .decodeFromJsonElement<List<AirSendPeerSnapshot>>(
                    ipcClient.request("get_peers")
                )
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
                        payload = buildJsonObject { put("limit", 100) }
                    )
                )
            } else {
                emptyList()
            }
            val activeIds = activeTransfers.mapTo(mutableSetOf()) { it.id }
            val durableHistory = history.map { transfer ->
                if (transfer.id in activeIds) transfer else transfer.copy(retryable = false)
            }
            val transfers = (activeTransfers + durableHistory)
                .distinctBy { it.id }
                .sortedByDescending { it.startedAtMs }
            RefreshSnapshot(hello, daemon, config, peers, transfers)
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
                historyCount = daemon.historyCount,
                activeTransferCount = daemon.activeTransferCount,
                transfers = snapshot.transfers,
                healthWarnings = daemon.healthWarnings + compatibilityWarnings,
                tlsFingerprint = daemon.tlsFingerprint,
                transportProtocol = daemon.transportProtocol,
                capabilities = hello.capabilities.toSet(),
                isRefreshing = false,
                lastError = null
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

    override fun startService() {
        androidRuntimeReader.startService()
        updateLocalState()
    }

    override fun stopService() {
        androidRuntimeReader.stopService()
        updateLocalState()
    }

    override fun restartService() {
        androidRuntimeReader.stopService()
        androidRuntimeReader.startService()
        updateLocalState()
    }

    override fun setBootStartEnabled(enabled: Boolean) {
        androidRuntimeReader.setBootStartEnabled(enabled)
        updateLocalState()
    }

    override suspend fun setPreferredTarget(targetId: String?) {
        require(targetId == null || targetId.isNotBlank()) { "Target id must not be blank" }
        val config = AirSendIpcCodec.json.decodeFromJsonElement<AirSendConfigSnapshot>(
            ipcClient.request("get_config")
        )
        val updated = config.copy(preferredTarget = targetId)
        ipcClient.request(
            op = "set_config",
            payload = AirSendIpcCodec.json.encodeToJsonElement(updated).jsonObject
        )
    }

    override suspend fun sendText(text: String, targetId: String?) {
        require(text.isNotEmpty()) { "Text must not be empty" }
        val target = targetId ?: state.value.preferredTargetId
        require(!target.isNullOrBlank()) { "Select a target before sending" }
        ipcClient.request(
            op = "send_text",
            payload = buildJsonObject {
                put("text", text)
                put("targetId", target)
            }
        )
    }

    override suspend fun sendClipboardText(targetId: String?) {
        val text = androidRuntimeReader.clipboardText()
        require(!text.isNullOrEmpty()) { "Clipboard has no text to send" }
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

    private fun updateLocalState() {
        _state.update { readLocalState(it) }
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
        manual = manual
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
    }
}
