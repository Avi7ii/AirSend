// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend

import java.nio.file.Files
import java.nio.file.Paths
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendMiuixOnlyTest {
    @Test
    fun settingsActivityAlwaysUsesMiuix() {
        val source = readSource("src/main/java/com/rosan/installer/ui/activity/SettingsActivity.kt")

        assertTrue(source.contains("val effectiveUiState = uiState.copy(useMiuix = true)"))
        assertTrue(source.contains("useMiuix = effectiveUiState.useMiuix"))
        assertTrue(source.contains("InstallerNavContainer(effectiveUiState)"))
    }

    @Test
    fun miuixThemePageKeepsColorControlsWithoutUiEngineSwitch() {
        val source = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/preferred/theme/MiuixThemeSettingsPage.kt"
        )
        val pageBody = source.substringAfter("fun MiuixThemeSettingsPage(")
            .substringBefore("private fun KsuMiuixThemePreviewCard(")

        assertFalse(pageBody.contains("MiuixThemeEngineWidget("))
        assertTrue(pageBody.contains("ThemeSettingsAction.SetUseMiuixMonet"))
        assertTrue(pageBody.contains("ThemeSettingsAction.SetSeedColor"))
        assertTrue(pageBody.contains("ThemeSettingsAction.SetPageScale"))
    }

    private fun readSource(relativePath: String): String {
        val userDir = Paths.get(System.getProperty("user.dir"))
        val appDir = if (Files.exists(userDir.resolve("src/main"))) userDir else userDir.resolve("app")
        return Files.readString(appDir.resolve(relativePath))
    }
}
