// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendPrivilegeAuthorizerTest {
    @Test
    fun privilegePagesKeepRealPrivilegeAuthorizersWithoutPackageManagerOption() {
        val materialPrivPage = readSource(
            "src/main/java/com/rosan/installer/ui/page/main/settings/home/priv/PrivPage.kt"
        )
        val miuixPrivPage = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/home/priv/MiuixPrivPage.kt"
        )

        listOf(materialPrivPage, miuixPrivPage).forEach { source ->
            assertTrue(source.contains("globalAuthorizer == Authorizer.Root"))
            assertTrue(source.contains("globalAuthorizer == Authorizer.Shizuku"))
            assertTrue(source.contains("globalAuthorizer == Authorizer.Dhizuku"))
            assertTrue(source.contains("globalAuthorizer == Authorizer.Customize"))
            assertFalse(source.contains("Authorizer.None"))
            assertFalse(source.contains("working_status_system_installer"))
            assertFalse(source.contains("working_status_system_installer_desc"))
        }
    }

    @Test
    fun homeActiveAuthorizerUsesSelectedAuthorizerInsteadOfSystemPackageManager() {
        val materialHome = readSource(
            "src/main/java/com/rosan/installer/ui/page/main/settings/home/HomePage.kt"
        )
        val miuixHome = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/home/MiuixHomePage.kt"
        )
        val homeSources = materialHome + "\n" + miuixHome

        assertFalse(homeSources.contains("uiState.isSystemApp -> stringResource(R.string.working_status_system_installer)"))
        assertTrue(homeSources.contains("uiState.globalAuthorizer == Authorizer.Root"))
        assertTrue(homeSources.contains("uiState.globalAuthorizer == Authorizer.Shizuku"))
        assertTrue(homeSources.contains("uiState.globalAuthorizer == Authorizer.Dhizuku"))
        assertTrue(homeSources.contains("else -> stringResource(uiState.globalAuthorizer.displayNameRes)"))
    }

    @Test
    fun availableAuthorizerCountDoesNotTreatSystemPackageManagerAsPrivilege() {
        val viewModel = readSource(
            "src/main/java/com/rosan/installer/ui/page/main/settings/home/HomePageViewModel.kt"
        )

        assertTrue(viewModel.contains("if (shizukuAvailable && caps.shizukuAuthorized) availableCount++"))
        assertTrue(viewModel.contains("if (caps.dhizukuAvailable && caps.dhizukuAuthorized) availableCount++"))
        assertTrue(viewModel.contains("if (caps.rootMode != RootMode.None) availableCount++"))
        assertFalse(viewModel.contains("if (capabilityProvider.isSystemApp) availableCount++"))
        assertTrue(viewModel.contains("requireShizukuPermissionGranted"))
        assertTrue(viewModel.contains("requireDhizukuPermissionGranted"))
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
}
