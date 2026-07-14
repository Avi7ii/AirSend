// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend

import com.rosan.installer.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendPageContentTest {
    @Test
    fun homeLayoutKeepsDashboardAndServiceActionsOnly() {
        val sectionIds = AirSendPageContent.home.sections.map { it.id }
        val ids = AirSendPageContent.home.sections.itemIds()

        assertEquals(AirSendStatusPlacement.TopCard, AirSendPageContent.home.statusPlacement)
        assertTrue(ids.contains(AirSendContentId.BackgroundService))
        assertTrue(ids.contains(AirSendContentId.ScreenshotSync))
        assertTrue(ids.contains(AirSendContentId.RestartService))
        assertTrue(ids.contains(AirSendContentId.RestartWholeService))
        assertTrue(ids.contains(AirSendContentId.PermissionCheck))
        assertFalse(sectionIds.contains(AirSendSectionId.Recent))
        assertFalse(ids.contains(AirSendContentId.ClipboardPush))
        assertFalse(ids.contains(AirSendContentId.ReceiveSwitch))
        assertFalse(ids.contains(AirSendContentId.EmptyRecent))
    }

    @Test
    fun devicesLayoutKeepsDiscoveryWithoutActivityActions() {
        val sectionIds = AirSendPageContent.devices.sections.map { it.id }
        val ids = AirSendPageContent.devices.sections.itemIds()

        assertTrue(ids.contains(AirSendContentId.NoTarget))
        assertTrue(ids.contains(AirSendContentId.DiscoverAgain))
        assertTrue(ids.contains(AirSendContentId.AddManual))
        assertFalse(sectionIds.contains(AirSendSectionId.DeviceCapabilities))
        assertFalse(ids.contains(AirSendContentId.SendClipboard))
        assertFalse(ids.contains(AirSendContentId.PairTrust))
    }

    @Test
    fun activityLayoutHasSeparateSendAndReceiveQueues() {
        val sendSectionIds = AirSendPageContent.activitySend.sections.map { it.id }
        val receiveSectionIds = AirSendPageContent.activityReceive.sections.map { it.id }
        val sendIds = AirSendPageContent.activitySend.sections.itemIds()
        val receiveIds = AirSendPageContent.activityReceive.sections.itemIds()

        assertTrue(sendIds.contains(AirSendContentId.SelectedFiles))
        assertTrue(sendIds.contains(AirSendContentId.NearbyTargets))
        assertTrue(sendIds.contains(AirSendContentId.SendClipboard))
        assertEquals(3, sendIds.size)
        assertTrue(receiveIds.contains(AirSendContentId.ReceiveRequests))
        assertTrue(receiveIds.contains(AirSendContentId.QuickSave))
        assertFalse(sendSectionIds.contains(AirSendSectionId.History))
        assertFalse(receiveSectionIds.contains(AirSendSectionId.History))
        assertFalse(sendIds.contains(AirSendContentId.SentHistory))
        assertFalse(receiveIds.contains(AirSendContentId.ReceivedHistory))
    }

    @Test
    fun settingsLayoutKeepsAppearanceTransferNetworkPermissionAndDiagnosticsGroups() {
        val sectionIds = AirSendPageContent.settings.sections.map { it.id }
        val itemIds = AirSendPageContent.settings.sections.itemIds()

        assertEquals(
            listOf(
                AirSendSectionId.Appearance,
                AirSendSectionId.Transfer,
                AirSendSectionId.Receive,
                AirSendSectionId.Network,
                AirSendSectionId.Permissions,
                AirSendSectionId.Diagnostics,
            ),
            sectionIds
        )
        assertTrue(itemIds.contains(AirSendContentId.Theme))
        assertTrue(itemIds.contains(AirSendContentId.ClipboardSync))
        assertTrue(itemIds.contains(AirSendContentId.ServiceNotification))
        assertTrue(itemIds.contains(AirSendContentId.HistoryRetention))
        assertTrue(itemIds.contains(AirSendContentId.SaveLocation))
        assertTrue(itemIds.contains(AirSendContentId.NetworkDiscovery))
        assertTrue(itemIds.contains(AirSendContentId.OpenPermissions))
        assertTrue(itemIds.contains(AirSendContentId.ExportLogs))
    }

    @Test
    fun settingsAboutEntryUsesAirSendAsTheVisibleTitle() {
        val about = AirSendPageContent.settings.sections.item(AirSendContentId.About)

        assertEquals(AirSendContentIcon.AirSend, about.icon)
        assertEquals(R.string.app_name, about.titleRes)
        assertEquals(R.string.about, about.descriptionRes)
    }

    private fun List<AirSendSection>.itemIds(): List<AirSendContentId> =
        flatMap { section -> section.items.map { it.id } }

    private fun List<AirSendSection>.item(id: AirSendContentId): AirSendContentItem =
        flatMap { section -> section.items }.first { it.id == id }
}
