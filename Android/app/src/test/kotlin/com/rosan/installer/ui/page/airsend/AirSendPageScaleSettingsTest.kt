// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendPageScaleSettingsTest {
    @Test
    fun pageScaleIsPersistedLikeKernelSU() {
        val dataStore = readSource("src/main/java/com/rosan/installer/data/settings/local/datastore/AppDataStore.kt")
        val repository = readSource("src/main/java/com/rosan/installer/data/settings/repository/AppSettingsRepositoryImpl.kt")
        val contract = readSource("src/main/java/com/rosan/installer/domain/settings/repository/AppSettingsRepository.kt")
        val updateUseCase = readSource("src/main/java/com/rosan/installer/domain/settings/usecase/settings/UpdateSettingUseCase.kt")

        assertTrue(dataStore.contains("floatPreferencesKey"))
        assertTrue(dataStore.contains("FLOAT"))
        assertTrue(dataStore.contains("UI_PAGE_SCALE"))
        assertTrue(dataStore.contains("""floatPreferencesKey("page_scale")"""))
        assertTrue(dataStore.contains("putFloat("))
        assertTrue(dataStore.contains("getFloat("))

        assertTrue(contract.contains("enum class FloatSetting"))
        assertTrue(contract.contains("UiPageScale"))
        assertTrue(contract.contains("suspend fun putFloat(setting: FloatSetting, value: Float)"))
        assertTrue(contract.contains("fun getFloat(setting: FloatSetting, default: Float = 0f): Flow<Float>"))
        assertTrue(updateUseCase.contains("operator fun invoke(setting: FloatSetting, value: Float)"))

        assertTrue(repository.contains("pageScale ="))
        assertTrue(repository.contains("prefs[AppDataStore.UI_PAGE_SCALE]"))
        assertTrue(repository.contains("coerceIn(0.8f, 1.1f)"))
        assertTrue(repository.contains("FloatSetting.UiPageScale -> AppDataStore.UI_PAGE_SCALE"))
    }

    @Test
    fun pageScaleFlowsIntoThemeStateAndDensity() {
        val preferences = readSource("src/main/java/com/rosan/installer/domain/settings/model/preferences/AppPreferences.kt")
        val themeState = readSource("src/main/java/com/rosan/installer/domain/settings/model/preferences/ThemeState.kt")
        val provider = readSource("src/main/java/com/rosan/installer/data/settings/provider/ThemeStateProviderImpl.kt")
        val settingsActivity = readSource("src/main/java/com/rosan/installer/ui/activity/SettingsActivity.kt")
        val installerActivityContent = readSource("src/main/java/com/rosan/installer/ui/activity/InstallerActivityContent.kt")

        assertTrue(preferences.contains("val pageScale: Float"))
        assertTrue(themeState.contains("val pageScale: Float = 1.0f"))
        assertTrue(provider.contains("pageScale = prefs.pageScale"))

        assertTrue(settingsActivity.contains("LocalDensity"))
        assertTrue(settingsActivity.contains("systemDensity.density * effectiveUiState.pageScale"))
        assertTrue(settingsActivity.contains("LocalDensity provides density"))

        assertTrue(installerActivityContent.contains("LocalDensity"))
        assertTrue(installerActivityContent.contains("systemDensity.density * uiState.pageScale"))
        assertTrue(installerActivityContent.contains("LocalDensity provides density"))
    }

    @Test
    fun themePagesCopyKernelSUPageScaleControls() {
        val strings = readSource("src/main/res/values/strings.xml")
        val simplifiedChinese = readSource("src/main/res/values-zh-rCN/strings.xml")
        val state = readSource("src/main/java/com/rosan/installer/ui/page/main/settings/preferred/theme/ThemeSettingsState.kt")
        val action = readSource("src/main/java/com/rosan/installer/ui/page/main/settings/preferred/theme/ThemeSettingsAction.kt")
        val viewModel = readSource("src/main/java/com/rosan/installer/ui/page/main/settings/preferred/theme/ThemeSettingsViewModel.kt")
        val material = readSource("src/main/java/com/rosan/installer/ui/page/main/settings/preferred/theme/ThemeSettingsPage.kt")
        val miuix = readSource("src/main/java/com/rosan/installer/ui/page/miuix/settings/preferred/theme/MiuixThemeSettingsPage.kt")

        assertTrue(strings.contains("""<string name="settings_page_scale">Page Scale</string>"""))
        assertTrue(strings.contains("""<string name="settings_page_scale_summary">Adjust the global display scale.</string>"""))
        assertTrue(simplifiedChinese.contains("""<string name="settings_page_scale">界面缩放</string>"""))
        assertTrue(simplifiedChinese.contains("""<string name="settings_page_scale_summary">调整全局显示比例</string>"""))

        assertTrue(state.contains("val pageScale: Float = 1.0f"))
        assertTrue(action.contains("data class SetPageScale(val scale: Float)"))
        assertTrue(viewModel.contains("pageScale = prefs.pageScale"))
        assertTrue(viewModel.contains("FloatSetting.UiPageScale"))

        assertTrue(material.contains("mutableFloatStateOf(uiState.pageScale)"))
        assertTrue(material.contains("Icons.Rounded.AspectRatio"))
        assertTrue(material.contains("stringResource(R.string.settings_page_scale)"))
        assertTrue(material.contains("stringResource(id = R.string.settings_page_scale_summary)"))
        assertTrue(material.contains("text = \"${'$'}{(sliderValue * 100).toInt()}%\""))
        assertTrue(material.contains("Slider("))
        assertTrue(material.contains("onValueChangeFinished = { viewModel.dispatch(ThemeSettingsAction.SetPageScale(sliderValue)) }"))
        assertTrue(material.contains("valueRange = 0.8f..1.1f"))

        assertTrue(miuix.contains("mutableFloatStateOf(uiState.pageScale)"))
        assertTrue(miuix.contains("ArrowPreference("))
        assertTrue(miuix.contains("Icons.Rounded.AspectRatio"))
        assertTrue(miuix.contains("stringResource(id = R.string.settings_page_scale)"))
        assertTrue(miuix.contains("stringResource(id = R.string.settings_page_scale_summary)"))
        assertTrue(miuix.contains("text = \"${'$'}{(sliderValue * 100).toInt()}%\""))
        assertTrue(miuix.contains("valueRange = 0.8f..1.1f"))
        assertTrue(miuix.contains("showKeyPoints = true"))
        assertTrue(miuix.contains("keyPoints = listOf(0.8f, 0.9f, 1f, 1.1f)"))
        assertTrue(miuix.contains("magnetThreshold = 0.01f"))
        assertTrue(miuix.contains("hapticEffect = SliderDefaults.SliderHapticEffect.Step"))
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
