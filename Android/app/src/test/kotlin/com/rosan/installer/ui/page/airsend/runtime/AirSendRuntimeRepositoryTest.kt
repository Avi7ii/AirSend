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
            respond("get_config", configJson())
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

    @Test
    fun selectingPeerPreservesConfigAndUpdatesPreferredTarget() = runBlocking {
        val client = FakeAirSendIpcClient().apply {
            respond("get_config", configJson())
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val repository = AirSendRuntimeRepositoryImpl(
            client,
            FakeAndroidRuntimeReader(),
            scope
        )

        repository.setPreferredTarget("peer-2")

        val payload = client.payloads.getValue("set_config")
        assertEquals("peer-2", payload["preferredTarget"]?.toString()?.trim('"'))
        assertEquals("trusted_only", payload["receivePolicy"]?.toString()?.trim('"'))
        assertEquals("/sdcard/Download/AirSend", payload["downloadDestination"]?.toString()?.trim('"'))
        assertEquals(1, (payload["trustedPeerFingerprints"] as kotlinx.serialization.json.JsonArray).size)
        scope.cancel()
    }

    @Test
    fun refreshMergesLiveTransfersWithDurableHistoryWithoutDuplicates() = runBlocking {
        val client = FakeAirSendIpcClient().apply {
            respond(
                "hello",
                """{"protocolVersion":1,"daemonVersion":"3.5.1","configVersion":1,"historySchemaVersion":1,"capabilities":["get_transfers","get_history"],"transportProtocol":"https"}"""
            )
            respond(
                "get_state",
                """{"protocolVersion":1,"daemonVersion":"3.5.1","configVersion":1,"historySchemaVersion":1,"startedAtMs":10,"peerCount":0,"historyCount":2,"activeTransferCount":1,"healthWarnings":[],"tlsFingerprint":"aa:bb","transportProtocol":"https"}"""
            )
            respond("get_peers", "[]")
            respond("get_config", configJson())
            respond("get_transfers", "[${transferJson("live", "transferring", 20, true)}]")
            respond(
                "get_history",
                "[${transferJson("live", "failed", 10, true)},${transferJson("old", "failed", 5, true)}]"
            )
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val repository = AirSendRuntimeRepositoryImpl(client, FakeAndroidRuntimeReader(), scope)

        repository.refresh()

        val transfers = repository.state.value.transfers
        assertEquals(listOf("live", "old"), transfers.map { it.id })
        assertEquals("transferring", transfers.first().status)
        assertTrue(transfers.first().retryable)
        assertFalse(transfers.last().retryable)
        scope.cancel()
    }

    @Test
    fun transferActionsUseStableSessionId() = runBlocking {
        val client = FakeAirSendIpcClient()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val repository = AirSendRuntimeRepositoryImpl(client, FakeAndroidRuntimeReader(), scope)

        repository.cancelTransfer("transfer-1")
        repository.retryTransfer("transfer-1")

        assertEquals("transfer-1", client.payloads.getValue("cancel_transfer")["id"].toString().trim('"'))
        assertEquals("transfer-1", client.payloads.getValue("retry_transfer")["id"].toString().trim('"'))
        scope.cancel()
    }

    companion object {
        private fun configJson(): String =
            """{"version":1,"preferredTarget":"peer-1","manualPeers":[],"trustedPeerFingerprints":["aa11"],"receivePolicy":"trusted_only","clipboardSyncEnabled":false,"screenshotSyncEnabled":false,"startupEnabled":true,"downloadDestination":"/sdcard/Download/AirSend","mediaDestination":"/sdcard/Pictures/AirSend","transportPreference":"https"}"""

        private fun transferJson(
            id: String,
            status: String,
            startedAtMs: Long,
            retryable: Boolean
        ): String =
            """{"id":"$id","direction":"outgoing","source":"app_picker","peerId":"peer-1","peerAlias":"Mac","files":[{"id":"file-1","name":"one.txt","mimeType":"text/plain","size":100,"transferredBytes":50,"status":"transferring"}],"totalBytes":100,"transferredBytes":50,"status":"$status","startedAtMs":$startedAtMs,"savedPaths":[],"retryable":$retryable}"""
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
