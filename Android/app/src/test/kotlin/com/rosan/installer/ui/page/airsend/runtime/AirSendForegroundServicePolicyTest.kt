// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendForegroundServicePolicyTest {
    @Test
    fun rootModuleAllowsNotificationlessRuntime() {
        assertTrue(
            AirSendForegroundServicePolicy.canRunWithoutAppService(
                RootDaemonSnapshot(
                    rootAvailable = true,
                    moduleInstalled = true,
                    moduleEnabled = true,
                    daemonProcessRunning = true
                )
            )
        )
    }

    @Test
    fun noRootRuntimeMustKeepTheAppForegroundService() {
        assertFalse(
            AirSendForegroundServicePolicy.canRunWithoutAppService(RootDaemonSnapshot())
        )
    }

    @Test
    fun hiddenNotificationStopsOnlyTheRootBackedAppService() {
        assertTrue(
            AirSendForegroundServicePolicy.shouldStopAppService(
                showNotification = false,
                daemonIpcReachable = true,
                bundledDaemonRunning = false
            )
        )
        assertFalse(
            AirSendForegroundServicePolicy.shouldStopAppService(
                showNotification = false,
                daemonIpcReachable = true,
                bundledDaemonRunning = true
            )
        )
        assertFalse(
            AirSendForegroundServicePolicy.shouldStopAppService(
                showNotification = true,
                daemonIpcReachable = true,
                bundledDaemonRunning = false
            )
        )
    }
}
