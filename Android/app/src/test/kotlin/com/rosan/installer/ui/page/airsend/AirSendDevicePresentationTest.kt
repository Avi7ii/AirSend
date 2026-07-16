// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend

import com.rosan.installer.ui.page.airsend.runtime.AirSendPeer
import org.junit.Assert.assertEquals
import org.junit.Test

class AirSendDevicePresentationTest {
    @Test
    fun macBookUsesLaptopIconEvenWhenProtocolReportsDesktop() {
        assertEquals(
            AirSendDeviceKind.Laptop,
            peer(alias = "Thom's MacBook Air", model = "macOS", type = "desktop").deviceKind()
        )
    }

    @Test
    fun knownDeviceTypesMapToDistinctKinds() {
        assertEquals(AirSendDeviceKind.Phone, peer(type = "mobile").deviceKind())
        assertEquals(AirSendDeviceKind.Tablet, peer(type = "tablet").deviceKind())
        assertEquals(AirSendDeviceKind.Desktop, peer(type = "desktop").deviceKind())
        assertEquals(AirSendDeviceKind.Tv, peer(type = "tv").deviceKind())
        assertEquals(AirSendDeviceKind.Watch, peer(type = "watch").deviceKind())
        assertEquals(AirSendDeviceKind.Other, peer(type = "headless").deviceKind())
    }

    @Test
    fun subtitleUsesModelSecureTransportAndVersion() {
        assertEquals(
            "macOS · HTTPS · 5.0.0",
            peer(model = "macOS", type = "desktop", version = "5.0.0").deviceSubtitle()
        )
    }

    private fun peer(
        alias: String = "Peer",
        model: String = "Device",
        type: String = "phone",
        version: String = ""
    ) = AirSendPeer(
        id = "peer-1",
        alias = alias,
        deviceModel = model,
        deviceType = type,
        version = version,
        protocol = "https"
    )
}
