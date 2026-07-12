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
            val peers = AirSendIpcCodec.json
                .decodeFromJsonElement<List<AirSendPeerSnapshot>>(
                    ipcClient.request("get_peers")
                )
                .map { it.toRuntimePeer() }
            Triple(hello, daemon, peers)
        }.onSuccess { (hello, daemon, peers) ->
            val compatibilityWarnings = if (hello.protocolVersion == SUPPORTED_PROTOCOL_VERSION) {
                emptyList()
            } else {
                listOf("protocol_version_mismatch")
            }
            _state.value = readLocalState(_state.value).copy(
                daemonReachable = true,
                peers = peers,
                protocolVersion = hello.protocolVersion,
                daemonVersion = hello.daemonVersion,
                configVersion = daemon.configVersion,
                historySchemaVersion = daemon.historySchemaVersion,
                daemonStartedAtMs = daemon.startedAtMs,
                preferredTargetId = daemon.preferredTarget,
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

    private fun AirSendPeerSnapshot.toRuntimePeer(): AirSendPeer = AirSendPeer(
        id = id,
        alias = alias,
        deviceModel = deviceModel ?: "Unknown",
        deviceType = deviceType,
        version = version,
        fingerprint = fingerprint,
        address = address,
        protocol = protocol,
        selected = selected,
        manual = manual
    )

    companion object {
        private const val SUPPORTED_PROTOCOL_VERSION = 1
    }
}
