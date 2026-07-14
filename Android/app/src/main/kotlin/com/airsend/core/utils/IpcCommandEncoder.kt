package com.airsend.core.utils

import org.json.JSONObject

object IpcCommandEncoder {
    fun getPeers(): String {
        return JSONObject()
            .put("op", "get_peers")
            .toString()
    }

    fun sendText(
        text: String,
        targetId: String? = null,
        source: String? = null
    ): String {
        val command = JSONObject()
            .put("op", "send_text")
            .put("text", text)

        if (!targetId.isNullOrEmpty()) {
            command.put("targetId", targetId)
        }
        if (!source.isNullOrEmpty()) {
            command.put("source", source)
        }

        return command.toString()
    }

    fun sendFile(
        path: String,
        targetId: String? = null,
        source: String? = null
    ): String {
        val command = JSONObject()
            .put("op", "send_file")
            .put("path", path)

        if (!targetId.isNullOrEmpty()) {
            command.put("targetId", targetId)
        }
        if (!source.isNullOrEmpty()) {
            command.put("source", source)
        }

        return command.toString()
    }
}
