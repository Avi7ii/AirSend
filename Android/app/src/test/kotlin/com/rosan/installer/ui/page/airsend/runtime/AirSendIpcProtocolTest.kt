// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test

class AirSendIpcProtocolTest {
    @Test
    fun requestUsesStableEnvelope() {
        val encoded = AirSendIpcCodec.json.encodeToString(
            AirSendIpcRequest(id = "req-1", op = "hello")
        )

        assertEquals(
            "{\"id\":\"req-1\",\"op\":\"hello\",\"payload\":{}}",
            encoded
        )
    }

    @Test
    fun daemonErrorThrowsStructuredException() {
        val raw =
            """{"id":"req-2","ok":false,"error":{"code":"offline","message":"Offline"}}"""

        try {
            AirSendIpcCodec.decodeResponse("req-2", raw)
            fail("Expected AirSendIpcException")
        } catch (error: AirSendIpcException) {
            assertEquals("offline", error.code)
            assertEquals("Offline", error.message)
        }
    }

    @Test
    fun responseWithDifferentRequestIdIsRejected() {
        val raw = """{"id":"other","ok":true,"data":{}}"""

        try {
            AirSendIpcCodec.decodeResponse("req-3", raw)
            fail("Expected AirSendIpcException")
        } catch (error: AirSendIpcException) {
            assertEquals("response_id_mismatch", error.code)
            assertFalse(error.message.isNullOrBlank())
        }
    }
}
