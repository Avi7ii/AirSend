// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2025-2026 InstallerX Revived contributors
package com.rosan.installer.ui.activity

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rosan.installer.domain.settings.model.preferences.ThemeState
import com.rosan.installer.domain.settings.provider.ThemeStateProvider
import com.rosan.installer.ui.navigation.InstallerNavContainer
import com.rosan.installer.ui.theme.InstallerTheme
import com.rosan.installer.ui.theme.LocalWindowLayoutInfo
import com.rosan.installer.ui.theme.rememberWindowLayoutInfo
import org.koin.core.component.KoinComponent
import org.koin.core.component.inject
import top.yukonga.miuix.kmp.theme.MiuixTheme

class SettingsActivity : ComponentActivity(), KoinComponent {
    private val themeStateProvider by inject<ThemeStateProvider>()

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        // Enable edge-to-edge mode for immersive experience
        enableEdgeToEdge()

        var isThemeLoaded = false
        // Keep splash screen visible until data is safely loaded
        splashScreen.setKeepOnScreenCondition { !isThemeLoaded }

        super.onCreate(savedInstanceState)
        setContent {
            val uiState by themeStateProvider.themeStateFlow.collectAsStateWithLifecycle(initialValue = ThemeState())
            isThemeLoaded = uiState.isLoaded

            // Prevent heavy navigation setup until state is ready
            if (!isThemeLoaded) return@setContent

            val effectiveUiState = uiState.copy(useMiuix = true)
            val layoutInfo = rememberWindowLayoutInfo()
            val systemDensity = LocalDensity.current
            val density = remember(systemDensity, effectiveUiState.pageScale) {
                Density(
                    systemDensity.density * effectiveUiState.pageScale,
                    systemDensity.fontScale
                )
            }

            CompositionLocalProvider(
                LocalWindowLayoutInfo provides layoutInfo,
                LocalDensity provides density
            ) {
                InstallerTheme(
                    useMiuix = effectiveUiState.useMiuix,
                    themeMode = effectiveUiState.themeMode,
                    paletteStyle = effectiveUiState.paletteStyle,
                    colorSpec = effectiveUiState.colorSpec,
                    useDynamicColor = effectiveUiState.useDynamicColor,
                    useMiuixMonet = effectiveUiState.useMiuixMonet,
                    seedColor = androidx.compose.ui.graphics.Color(effectiveUiState.seedColor)
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(MiuixTheme.colorScheme.surface)
                    ) {
                        InstallerNavContainer(effectiveUiState)
                    }
                }
            }
        }
    }
}
