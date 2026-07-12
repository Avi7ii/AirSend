// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

class LocalSocketAirSendIpcClient : AirSendIpcClient {
    override suspend fun request(
        op: String,
        payload: JsonObject
    ): JsonElement = withContext(Dispatchers.IO) {
        val request = AirSendIpcRequest(
            id = UUID.randomUUID().toString(),
            op = op,
            payload = payload
        )
        LocalSocket().use { socket ->
            connect(socket, timeoutFor(op))
            writeRequest(socket, request)
            val response = readBoundedLine(socket.inputStream)
                ?: throw AirSendIpcException(
                    code = "no_response",
                    message = "AirSend daemon closed the connection without a response"
                )
            AirSendIpcCodec.decodeResponse(request.id, response)
        }
    }

    override fun events(): Flow<AirSendIpcEvent> = flow {
        var reconnectDelayMs = INITIAL_RECONNECT_DELAY_MS
        while (currentCoroutineContext().isActive) {
            try {
                LocalSocket().use { socket ->
                    connect(socket, EVENT_READ_TIMEOUT_MS)
                    val request = AirSendIpcRequest(
                        id = UUID.randomUUID().toString(),
                        op = "subscribe"
                    )
                    writeRequest(socket, request)
                    val acknowledgement = readBoundedLine(socket.inputStream)
                        ?: throw AirSendIpcException(
                            code = "no_response",
                            message = "AirSend daemon did not acknowledge event subscription"
                        )
                    AirSendIpcCodec.decodeResponse(request.id, acknowledgement)
                    reconnectDelayMs = INITIAL_RECONNECT_DELAY_MS

                    while (currentCoroutineContext().isActive) {
                        val line = readBoundedLine(socket.inputStream)
                            ?: throw AirSendIpcException(
                                code = "event_stream_closed",
                                message = "AirSend daemon event stream closed"
                            )
                        emit(AirSendIpcCodec.decodeEvent(line))
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                delay(reconnectDelayMs)
                reconnectDelayMs = (reconnectDelayMs * 2).coerceAtMost(MAX_RECONNECT_DELAY_MS)
            }
        }
    }.flowOn(Dispatchers.IO)

    private fun connect(socket: LocalSocket, timeoutMs: Int) {
        socket.connect(
            LocalSocketAddress(SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT)
        )
        socket.soTimeout = timeoutMs
    }

    private fun writeRequest(socket: LocalSocket, request: AirSendIpcRequest) {
        val bytes = (
            AirSendIpcCodec.json.encodeToString(request) + "\n"
            ).toByteArray(Charsets.UTF_8)
        socket.outputStream.write(bytes)
        socket.outputStream.flush()
    }

    private fun readBoundedLine(input: InputStream): String? {
        val output = ByteArrayOutputStream()
        while (output.size() <= MAX_RESPONSE_BYTES) {
            val byte = input.read()
            if (byte == -1) {
                if (output.size() == 0) return null
                break
            }
            if (byte == '\n'.code) break
            if (byte != '\r'.code) output.write(byte)
        }
        if (output.size() > MAX_RESPONSE_BYTES) {
            throw AirSendIpcException(
                code = "response_too_large",
                message = "AirSend daemon response exceeded $MAX_RESPONSE_BYTES bytes"
            )
        }
        return output.toString(Charsets.UTF_8.name())
    }

    private fun timeoutFor(op: String): Int = when (op) {
        "send_file" -> FILE_SEND_TIMEOUT_MS
        "send_text" -> TEXT_SEND_TIMEOUT_MS
        else -> REQUEST_TIMEOUT_MS
    }

    companion object {
        private const val SOCKET_NAME = "airsend_ipc"
        private const val MAX_RESPONSE_BYTES = 1024 * 1024
        private const val REQUEST_TIMEOUT_MS = 5_000
        private const val TEXT_SEND_TIMEOUT_MS = 60_000
        private const val FILE_SEND_TIMEOUT_MS = 240_000
        private const val EVENT_READ_TIMEOUT_MS = 15_000
        private const val INITIAL_RECONNECT_DELAY_MS = 500L
        private const val MAX_RECONNECT_DELAY_MS = 8_000L
    }
}
