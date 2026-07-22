package com.rosan.installer.ui.page.airsend

import com.rosan.installer.ui.page.airsend.runtime.AirSendAuthorizationMode
import com.rosan.installer.ui.page.airsend.runtime.AirSendPeer
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeState
import org.junit.Assert.assertEquals
import org.junit.Test

class AirSendHomeStatusTest {
    @Test
    fun `healthy runtime without peers is neutral`() {
        val status = healthyState().homeStatus()

        assertEquals(AirSendHomeStatusKind.NoNearbyDevices, status.kind)
        assertEquals(AirSendHomeStatusTone.Neutral, status.tone)
    }

    @Test
    fun `healthy runtime with an online peer is ready`() {
        val status = healthyState().copy(
            peers = listOf(AirSendPeer(id = "mac", alias = "Mac", deviceModel = "Mac"))
        ).homeStatus()

        assertEquals(AirSendHomeStatusKind.Ready, status.kind)
        assertEquals(AirSendHomeStatusTone.Ready, status.tone)
        assertEquals(1, status.descriptionCount)
    }

    @Test
    fun `root failures are specific and critical`() {
        val missingRoot = healthyState().copy(
            authorizationMode = AirSendAuthorizationMode.Root,
            rootAvailable = false
        ).homeStatus()
        val inactiveModule = healthyState().copy(
            authorizationMode = AirSendAuthorizationMode.Root,
            rootAvailable = true,
            moduleInstalled = true,
            moduleEnabled = false
        ).homeStatus()
        assertEquals(AirSendHomeStatusKind.RootPermissionMissing, missingRoot.kind)
        assertEquals(AirSendHomeStatusKind.LsposedInactive, inactiveModule.kind)
    }

    @Test
    fun `daemon and permission failures name the blocking subsystem`() {
        val daemonOffline = healthyState().copy(daemonReachable = false).homeStatus()
        val mediaPermission = healthyState().copy(storagePermissionGranted = false).homeStatus()

        assertEquals(AirSendHomeStatusKind.DaemonOffline, daemonOffline.kind)
        assertEquals(AirSendHomeStatusKind.MediaPermissionMissing, mediaPermission.kind)
    }

    private fun healthyState() = AirSendRuntimeState(
        serviceRunning = true,
        daemonReachable = true,
        appVersion = "5.0.1",
        appVersionCode = 501,
        notificationPermissionGranted = true,
        storagePermissionGranted = true,
        tlsReady = true,
        storageReady = true
    )
}
