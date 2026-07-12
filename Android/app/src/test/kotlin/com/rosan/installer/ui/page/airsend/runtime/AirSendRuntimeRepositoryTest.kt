// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AirSendRuntimeRepositoryTest {
    @Test
    fun refreshMapsDaemonVersionsWarningsAndPeers() = runBlocking {
        val client = FakeAirSendIpcClient().apply {
            respond(
                "hello",
                """{"protocolVersion":1,"daemonVersion":"3.5.1","configVersion":1,"historySchemaVersion":1,"capabilities":["get_state"],"transportProtocol":"https"}"""
            )
            respond(
                "get_state",
                """{"protocolVersion":1,"daemonVersion":"3.5.1","configVersion":1,"historySchemaVersion":1,"startedAtMs":10,"peerCount":1,"preferredTarget":"peer-1","historyCount":4,"healthWarnings":["config_recovered"],"tlsFingerprint":"aa:bb","transportProtocol":"https"}"""
            )
            respond(
                "get_peers",
                """[{"id":"peer-1","alias":"Mac","deviceModel":"MacBook Pro","deviceType":"desktop","version":"2.1","fingerprint":"11:22","address":"192.168.1.2:53317","protocol":"https","selected":true,"manual":false}]"""
            )
        }
        val runtime = FakeAndroidRuntimeReader()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val repository = AirSendRuntimeRepositoryImpl(client, runtime, scope)

        repository.refresh()

        val state = repository.state.value
        assertTrue(state.daemonReachable)
        assertEquals(1, state.protocolVersion)
        assertEquals("3.5.1", state.daemonVersion)
        assertEquals("https", state.transportProtocol)
        assertEquals(listOf("config_recovered"), state.healthWarnings)
        assertEquals("peer-1", state.preferredTargetId)
        assertEquals(4, state.historyCount)
        assertEquals("Mac", state.peers.single().alias)
        assertTrue(state.peers.single().selected)
        assertFalse(state.isRefreshing)
        scope.cancel()
    }

    @Test
    fun sendFailureIsPropagatedInsteadOfShowingSuccess() = runBlocking {
        val client = FakeAirSendIpcClient().apply {
            fail("send_text", "target_offline", "Target is offline")
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val repository = AirSendRuntimeRepositoryImpl(
            client,
            FakeAndroidRuntimeReader(),
            scope
        )

        try {
            repository.sendText("hello", "peer-1")
            fail("Expected AirSendIpcException")
        } catch (error: AirSendIpcException) {
            assertEquals("target_offline", error.code)
        }
        assertEquals("peer-1", client.payloads.getValue("send_text")["targetId"]?.toString()?.trim('"'))
        scope.cancel()
    }
}

private class FakeAirSendIpcClient : AirSendIpcClient {
    private val responses = mutableMapOf<String, JsonElement>()
    private val failures = mutableMapOf<String, AirSendIpcException>()
    val payloads = mutableMapOf<String, JsonObject>()

    fun respond(op: String, raw: String) {
        responses[op] = AirSendIpcCodec.json.parseToJsonElement(raw)
    }

    fun fail(op: String, code: String, message: String) {
        failures[op] = AirSendIpcException(code, message)
    }

    override suspend fun request(op: String, payload: JsonObject): JsonElement {
        payloads[op] = payload
        failures[op]?.let { throw it }
        return responses[op] ?: buildJsonObject { put("ok", true) }
    }

    override fun events(): Flow<AirSendIpcEvent> = emptyFlow()
}

private class FakeAndroidRuntimeReader : AndroidRuntimeReader {
    override fun snapshot(): AndroidRuntimeSnapshot = AndroidRuntimeSnapshot(
        serviceRunning = true,
        bootStartEnabled = true,
        notificationPermissionGranted = true,
        storagePermissionGranted = true
    )

    override fun startService() = Unit
    override fun stopService() = Unit
    override fun setBootStartEnabled(enabled: Boolean) = Unit
    override fun clipboardText(): String? = "clipboard"
    override fun resolvePath(uri: Uri): String? = uri.path
}
