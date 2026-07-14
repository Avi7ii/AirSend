// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import java.io.IOException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

@Serializable
data class AirSendIpcRequest(
    val id: String,
    val op: String,
    val payload: JsonObject = buildJsonObject {}
)

@Serializable
data class AirSendIpcError(
    val code: String,
    val message: String
)

@Serializable
data class AirSendIpcResponse(
    val id: String,
    val ok: Boolean,
    val data: JsonElement? = null,
    val error: AirSendIpcError? = null
)

@Serializable
data class AirSendIpcEvent(
    val event: String,
    val sequence: Long,
    val data: JsonElement
)

@Serializable
data class AirSendHelloSnapshot(
    val protocolVersion: Int,
    val daemonVersion: String,
    val configVersion: Int,
    val historySchemaVersion: Int,
    val capabilities: List<String>,
    val transportProtocol: String
)

@Serializable
data class AirSendDaemonStateSnapshot(
    val protocolVersion: Int,
    val daemonVersion: String,
    val configVersion: Int,
    val historySchemaVersion: Int,
    val startedAtMs: Long,
    val peerCount: Int,
    val preferredTarget: String? = null,
    val historyCount: Int,
    val activeTransferCount: Int = 0,
    val healthWarnings: List<String> = emptyList(),
    val tlsFingerprint: String,
    val tlsReady: Boolean = false,
    val transportProtocol: String,
    val reverseClipboardIpcReady: Boolean = false,
    val storageReady: Boolean = false,
    val networkBinding: String? = null,
    val transferPort: Int? = null,
    val discoveryPort: Int? = null
)

@Serializable
data class AirSendTransferFileSnapshot(
    val id: String,
    val name: String,
    val mimeType: String,
    val size: Long,
    val transferredBytes: Long,
    val status: String
)

@Serializable
data class AirSendTransferSnapshot(
    val id: String,
    val direction: String,
    val source: String,
    val peerId: String,
    val peerAlias: String,
    val peerFingerprint: String? = null,
    val files: List<AirSendTransferFileSnapshot>,
    val totalBytes: Long,
    val transferredBytes: Long,
    val status: String,
    val startedAtMs: Long,
    val endedAtMs: Long? = null,
    val savedPaths: List<String> = emptyList(),
    val previewPaths: List<String> = emptyList(),
    val previewText: String? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val retryable: Boolean = false
) {
    val progress: Float
        get() = if (totalBytes <= 0L) {
            if (status == "completed") 1f else 0f
        } else {
            (transferredBytes.toDouble() / totalBytes.toDouble()).toFloat().coerceIn(0f, 1f)
        }

    val isTerminal: Boolean
        get() = status in setOf("completed", "failed", "cancelled", "declined")
}

@Serializable
data class AirSendPeerSnapshot(
    val id: String,
    val alias: String,
    val deviceModel: String? = null,
    val deviceType: String? = null,
    val version: String,
    val fingerprint: String,
    val address: String,
    val protocol: String,
    val selected: Boolean = false,
    val manual: Boolean = false,
    val online: Boolean = true
)

@Serializable
data class AirSendManualPeerSnapshot(
    val id: String,
    val alias: String,
    val address: String,
    val port: Int,
    val fingerprint: String? = null
)

@Serializable
data class AirSendConfigSnapshot(
    val version: Int,
    val preferredTarget: String? = null,
    val manualPeers: List<AirSendManualPeerSnapshot> = emptyList(),
    val trustedPeerFingerprints: List<String> = emptyList(),
    val receivePolicy: String,
    val clipboardSyncEnabled: Boolean,
    val screenshotSyncEnabled: Boolean,
    val startupEnabled: Boolean,
    val downloadDestination: String,
    val mediaDestination: String,
    val transportPreference: String,
    val historyLimitPerDirection: Int = 30
)

@Serializable
data class AirSendSnapshotPayload(
    val daemon: AirSendDaemonStateSnapshot,
    val config: AirSendConfigSnapshot,
    val peers: List<AirSendPeerSnapshot> = emptyList(),
    val transfers: List<AirSendTransferSnapshot> = emptyList(),
    val history: List<AirSendTransferSnapshot> = emptyList()
)

class AirSendIpcException(
    val code: String,
    message: String,
    cause: Throwable? = null
) : IOException(message, cause)

internal object AirSendIpcCodec {
    val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    fun decodeResponse(expectedId: String, raw: String): JsonElement {
        val response = runCatching {
            json.decodeFromString<AirSendIpcResponse>(raw)
        }.getOrElse { error ->
            throw AirSendIpcException(
                code = "invalid_response",
                message = "Invalid AirSend daemon response",
                cause = error
            )
        }
        if (response.id != expectedId) {
            throw AirSendIpcException(
                code = "response_id_mismatch",
                message = "Expected response $expectedId but received ${response.id}"
            )
        }
        if (!response.ok) {
            val error = response.error
            throw AirSendIpcException(
                code = error?.code ?: "daemon_error",
                message = error?.message ?: "AirSend daemon rejected the operation"
            )
        }
        return response.data ?: JsonNull
    }

    fun decodeEvent(raw: String): AirSendIpcEvent = runCatching {
        json.decodeFromString<AirSendIpcEvent>(raw)
    }.getOrElse { error ->
        throw AirSendIpcException(
            code = "invalid_event",
            message = "Invalid AirSend daemon event",
            cause = error
        )
    }
}
