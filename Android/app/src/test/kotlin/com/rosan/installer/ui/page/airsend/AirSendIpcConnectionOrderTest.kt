// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend

import java.nio.file.Files
import java.nio.file.Paths
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendIpcConnectionOrderTest {
    @Test
    fun localSocketConnectsBeforeApplyingReadTimeout() {
        val userDir = Paths.get(System.getProperty("user.dir"))
        val appDir = if (Files.exists(userDir.resolve("src/main"))) userDir else userDir.resolve("app")
        val source = Files.readString(
            appDir.resolve(
                "src/main/java/com/rosan/installer/ui/page/airsend/runtime/LocalSocketAirSendIpcClient.kt"
            )
        )
        val connectFunction = source.substringAfter("private fun connect(")
            .substringBefore("private fun writeRequest(")

        assertTrue(
            "LocalSocket must be connected before setting soTimeout",
            connectFunction.indexOf("socket.connect(") < connectFunction.indexOf("socket.soTimeout")
        )
    }
}
