// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlin.io.path.name
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendAboutBrandingTest {
    @Test
    fun aboutResourcesUseAirSendBranding() {
        val base = readSource("src/main/res/values/strings.xml")
        val simplifiedChinese = readSource("src/main/res/values-zh-rCN/strings.xml")
        val traditionalChinese = readSource("src/main/res/values-zh-rTW/strings.xml")

        assertTrue(base.contains("""<string name="app_name" translatable="false">AirSend</string>"""))
        assertTrue(base.contains("""<string name="about_detail">About AirSend</string>"""))
        assertTrue(simplifiedChinese.contains("""<string name="about_detail">关于 AirSend</string>"""))
        assertTrue(traditionalChinese.contains("""<string name="about_detail">關於 AirSend</string>"""))
        assertFalse(base.aboutBlock().contains("InstallerX Revived"))
        assertFalse(simplifiedChinese.aboutBlock().contains("InstallerX Revived"))
        assertFalse(traditionalChinese.aboutBlock().contains("InstallerX Revived"))
    }

    @Test
    fun aboutPagesOpenAirSendLinksOnly() {
        val materialAbout = readSource(
            "src/main/java/com/rosan/installer/ui/page/main/settings/preferred/about/AboutPage.kt"
        )
        val miuixAbout = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/preferred/about/MiuixAboutPage.kt"
        )
        val aboutSources = materialAbout + "\n" + miuixAbout

        assertTrue(aboutSources.contains("https://github.com/Avi7ii/AirSend"))
        assertTrue(aboutSources.contains("https://github.com/Avi7ii/AirSend/releases/latest"))
        assertFalse(aboutSources.contains("wxxsfxyzm"))
        assertFalse(aboutSources.contains("installerx_revived"))
    }

    @Test
    fun userFacingBrandEntryPointsUseAirSendOnly() {
        val sources = listOf(
            "src/main/java/com/rosan/installer/ui/page/miuix/widgets/MiuixDialog.kt",
            "src/main/java/com/rosan/installer/ui/page/main/settings/home/HomePage.kt",
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/home/MiuixHomePage.kt",
            "src/main/java/com/rosan/installer/data/updater/repository/OnlineUpdateRepositoryImpl.kt",
            "src/main/java/com/rosan/installer/ui/page/main/settings/preferred/PreferredViewModel.kt",
            "src/main/java/com/rosan/installer/core/env/AppConfig.kt",
        ).joinToString("\n") { readSource(it) }

        assertTrue(sources.contains("https://github.com/Avi7ii/AirSend"))
        assertTrue(sources.contains("REPO_OWNER = \"Avi7ii\""))
        assertTrue(sources.contains("REPO_NAME = \"AirSend\""))
        assertTrue(sources.contains("OFFICIAL_PACKAGE_NAME = \"com.airsend\""))
        assertTrue(sources.contains("AirSend-backup-"))
        assertTrue(sources.contains(".airsend-backup.json"))
        assertFalse(sources.contains("wxxsfxyzm"))
        assertFalse(sources.contains("InstallerX-Revived"))
        assertFalse(sources.contains("installerx_revived"))
        assertFalse(sources.contains(".installerx-backup.json"))
    }

    @Test
    fun everyLocalizedAboutResourceUsesAirSendBranding() {
        stringResourceFiles().forEach { file ->
            val source = Files.readString(file)
            val aboutText = source.aboutRelatedStrings()

            assertFalse("${file.parent.name}/strings.xml still mentions InstallerX", aboutText.contains("InstallerX"))
            assertFalse("${file.parent.name}/strings.xml still mentions Revived", aboutText.contains("Revived"))
        }
    }

    @Test
    fun aboutHeadersUseAirSendMonochromeIcon() {
        val materialStatusCard = readSource(
            "src/main/java/com/rosan/installer/ui/page/main/widget/card/StatusCard.kt"
        )
        val miuixAbout = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/preferred/about/MiuixAboutPage.kt"
        )

        assertTrue(materialStatusCard.contains("R.drawable.ic_airsend_monochrome"))
        assertTrue(miuixAbout.contains("R.drawable.ic_airsend_monochrome"))
        assertFalse(miuixAbout.contains("bitmap = uiState.appIcon"))
        assertTrue(miuixAbout.contains("R.string.airsend_version_info_format"))
        assertFalse(miuixAbout.contains("R.string.app_version_info_format"))
    }

    private fun readSource(relativePath: String): String =
        Files.readString(appDir().resolve(relativePath))

    private fun appDir(): Path {
        val userDir = Paths.get(System.getProperty("user.dir"))
        return if (Files.exists(userDir.resolve("src/main/res/values/strings.xml"))) {
            userDir
        } else {
            userDir.resolve("app")
        }
    }

    private fun stringResourceFiles(): List<Path> =
        Files.walk(appDir().resolve("src/main/res")).use { paths ->
            paths
                .filter { path -> path.fileName.toString() == "strings.xml" }
                .filter { path -> path.parent.fileName.toString().startsWith("values") }
                .toList()
        }

    private fun String.aboutBlock(): String =
        substringAfter("""<string name="about"""")
            .substringBefore("""<string name="backup_settings"""")

    private fun String.aboutRelatedStrings(): String =
        lines()
            .filter { line ->
                aboutStringNames.any { name -> line.contains("""name="$name"""") }
            }
            .joinToString("\n")

    private val aboutStringNames = listOf(
        "about_detail",
        "get_update_detail",
        "get_update_directly_desc",
        "get_source_code",
        "get_source_code_detail",
        "uninstall_title",
        "uninstall_content",
        "discuss",
        "home_learn_more_airsend_title",
        "home_learn_more_airsend_desc",
        "backup_settings_validation_invalid_file",
        "installer_running",
        "exception_initiator_not_visible",
        "lab_module_flashing_show_art_desc",
    )
}
