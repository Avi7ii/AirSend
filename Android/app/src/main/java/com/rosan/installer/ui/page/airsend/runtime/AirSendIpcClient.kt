// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

interface AirSendIpcClient {
    suspend fun request(
        op: String,
        payload: JsonObject = buildJsonObject {}
    ): JsonElement

    fun events(): Flow<AirSendIpcEvent>
}
