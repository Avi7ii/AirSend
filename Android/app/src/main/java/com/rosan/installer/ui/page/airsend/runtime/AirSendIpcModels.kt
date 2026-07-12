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
    val healthWarnings: List<String> = emptyList(),
    val tlsFingerprint: String,
    val transportProtocol: String
)

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
    val manual: Boolean = false
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
