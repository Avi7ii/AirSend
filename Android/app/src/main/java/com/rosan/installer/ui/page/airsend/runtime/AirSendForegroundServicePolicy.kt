// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

internal object AirSendForegroundServicePolicy {
    fun canRunWithoutAppService(root: RootDaemonSnapshot): Boolean =
        root.rootAvailable && root.moduleInstalled && root.moduleEnabled

    fun shouldStopAppService(
        showNotification: Boolean,
        daemonIpcReachable: Boolean,
        bundledDaemonRunning: Boolean
    ): Boolean =
        !showNotification && daemonIpcReachable && !bundledDaemonRunning
}
