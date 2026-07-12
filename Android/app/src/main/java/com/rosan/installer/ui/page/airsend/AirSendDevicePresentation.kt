// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend

import com.rosan.installer.ui.page.airsend.runtime.AirSendPeer
import java.util.Locale

enum class AirSendDeviceKind {
    Phone,
    Tablet,
    Laptop,
    Desktop,
    Tv,
    Watch,
    Other
}

fun AirSendPeer.deviceKind(): AirSendDeviceKind {
    val normalized = listOf(alias, deviceModel, deviceType.orEmpty())
        .joinToString(" ")
        .lowercase(Locale.ROOT)

    return when {
        listOf("macbook", "notebook", "laptop").any(normalized::contains) ->
            AirSendDeviceKind.Laptop
        deviceType.equals("mobile", ignoreCase = true) ||
            deviceType.equals("phone", ignoreCase = true) ||
            deviceType.equals("smartphone", ignoreCase = true) -> AirSendDeviceKind.Phone
        deviceType.equals("tablet", ignoreCase = true) -> AirSendDeviceKind.Tablet
        deviceType.equals("laptop", ignoreCase = true) -> AirSendDeviceKind.Laptop
        deviceType.equals("desktop", ignoreCase = true) -> AirSendDeviceKind.Desktop
        deviceType.equals("tv", ignoreCase = true) -> AirSendDeviceKind.Tv
        deviceType.equals("watch", ignoreCase = true) -> AirSendDeviceKind.Watch
        else -> AirSendDeviceKind.Other
    }
}

fun AirSendPeer.deviceSubtitle(): String = listOf(
    deviceModel,
    protocol.uppercase(Locale.ROOT),
    version
).filter(String::isNotBlank).joinToString(" · ")
