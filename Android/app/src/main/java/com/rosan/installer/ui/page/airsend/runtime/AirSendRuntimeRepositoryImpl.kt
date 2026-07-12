// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
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
            RefreshSnapshot(hello, daemon, config, peers)
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
        ipcClient.request(
            op = "send_text",
            payload = buildJsonObject {
                put("text", text)
                targetId?.let { put("targetId", it) }
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
        uris.forEach { uri ->
            val path = androidRuntimeReader.resolvePath(uri)
            require(!path.isNullOrEmpty()) { "Unable to resolve file: $uri" }
            ipcClient.request(
                op = "send_file",
                payload = buildJsonObject {
                    put("path", path)
                    targetId?.let { put("targetId", it) }
                }
            )
        }
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
        val peers: List<AirSendPeer>
    )

    companion object {
        private const val SUPPORTED_PROTOCOL_VERSION = 1
    }
}
