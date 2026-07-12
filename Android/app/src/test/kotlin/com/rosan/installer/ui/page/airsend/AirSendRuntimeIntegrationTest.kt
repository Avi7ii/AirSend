// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendRuntimeIntegrationTest {
    @Test
    fun runtimeLayerExposesRealAirSendOperations() {
        val state = readSource("src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeState.kt")
        val repository = readSource("src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeRepository.kt")
        val repositoryImpl = readSource("src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeRepositoryImpl.kt")
        val androidRuntime = readSource("src/main/java/com/rosan/installer/ui/page/airsend/runtime/AndroidRuntimeReader.kt")
        val ipcClient = readSource("src/main/java/com/rosan/installer/ui/page/airsend/runtime/LocalSocketAirSendIpcClient.kt")
        val viewModel = readSource("src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeViewModel.kt")

        assertTrue(state.contains("data class AirSendPeer"))
        assertTrue(state.contains("val peers: List<AirSendPeer>"))
        assertTrue(state.contains("val daemonReachable: Boolean"))
        assertTrue(state.contains("val bootStartEnabled: Boolean"))
        assertTrue(state.contains("val notificationPermissionGranted: Boolean"))

        assertTrue(repository.contains("val state: StateFlow<AirSendRuntimeState>"))
        assertTrue(repository.contains("suspend fun refresh()"))
        assertTrue(repository.contains("fun restartService()"))
        assertTrue(repository.contains("fun setBootStartEnabled(enabled: Boolean)"))
        assertTrue(repository.contains("suspend fun sendText(text: String, targetId: String? = null)"))

        assertTrue(androidRuntime.contains("AirSendService::class.java"))
        assertTrue(androidRuntime.contains("BootReceiver::class.java"))
        assertTrue(androidRuntime.contains("PackageManager.COMPONENT_ENABLED_STATE_ENABLED"))
        assertTrue(repositoryImpl.contains("ipcClient.request(\"hello\")"))
        assertTrue(repositoryImpl.contains("ipcClient.request(\"get_state\")"))
        assertTrue(repositoryImpl.contains("ipcClient.request(\"get_peers\")"))
        assertTrue(repositoryImpl.contains("op = \"send_files\""))
        assertTrue(repositoryImpl.contains("JsonArray(paths.map(::JsonPrimitive))"))
        assertTrue(repositoryImpl.contains("op = \"cancel_transfer\""))
        assertTrue(repositoryImpl.contains("op = \"retry_transfer\""))
        assertTrue(repositoryImpl.contains("AirSendIpcException") || ipcClient.contains("AirSendIpcException"))
        assertFalse(repositoryImpl.contains("LocalSocket"))
        assertFalse(repositoryImpl.contains("org.json.JSONArray"))

        assertTrue(viewModel.contains("class AirSendRuntimeViewModel"))
        assertTrue(viewModel.contains("AirSendRuntimeRepository"))
        assertTrue(viewModel.contains("RestartService"))
        assertTrue(viewModel.contains("SetBootStartEnabled"))
        assertTrue(viewModel.contains("SendClipboardText"))
    }

    @Test
    fun airSendPagesAreDrivenByRuntimeStateInsteadOfStaticShells() {
        val material = readSource("src/main/java/com/rosan/installer/ui/page/main/airsend/AirSendMaterialPages.kt")
        val miuix = readSource("src/main/java/com/rosan/installer/ui/page/miuix/airsend/AirSendMiuixPages.kt")
        val viewModelModule = readSource("src/main/java/com/rosan/installer/di/ViewModelModule.kt")
        val settingsModule = readSource("src/main/java/com/rosan/installer/di/SettingsModule.kt")

        listOf(material, miuix).forEach { source ->
            assertTrue(source.contains("AirSendRuntimeViewModel"))
            assertTrue(source.contains("collectAsStateWithLifecycle()"))
            assertTrue(source.contains("runtimeState.peers"))
            assertTrue(source.contains("AirSendRuntimeAction.RestartService"))
            assertTrue(source.contains("AirSendRuntimeAction.Refresh"))
            assertTrue(source.contains("AirSendRuntimeAction.SetBootStartEnabled"))
            assertTrue(source.contains("AirSendRuntimeAction.SendClipboardText"))
            assertTrue(source.contains("SwitchWidget") || source.contains("MiuixSwitchWidget"))
        }

        assertTrue(viewModelModule.contains("viewModelOf(::AirSendRuntimeViewModel)"))
        assertTrue(settingsModule.contains("single<AirSendIpcClient>"))
        assertTrue(settingsModule.contains("single<AndroidRuntimeReader>"))
        assertTrue(settingsModule.contains("single<AirSendRuntimeRepository>"))
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
