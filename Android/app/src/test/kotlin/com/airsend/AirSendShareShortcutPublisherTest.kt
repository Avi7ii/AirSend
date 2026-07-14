package com.airsend

import org.junit.Assert.assertEquals
import org.junit.Test

class AirSendShareShortcutPublisherTest {
    @Test
    fun `preferred online device ranks first and invalid targets are omitted`() {
        val ranked = rankTargets(
            targets = listOf(
                AirSendShareTarget("phone", "Phone"),
                AirSendShareTarget("mac", "Mac"),
                AirSendShareTarget("offline", "Offline", online = false),
                AirSendShareTarget("mac", "Duplicate")
            ),
            preferredTargetId = "mac"
        )

        assertEquals(listOf("mac", "phone"), ranked.map { it.id })
    }

    @Test
    fun `shortcut ids stay stable for system ranking history`() {
        assertEquals("peer_device-123", AirSendShareShortcutPublisher.shortcutId("device-123"))
    }
}
