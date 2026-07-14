// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2025-2026 InstallerX Revived contributors
package com.rosan.installer.ui.activity

import android.content.Intent
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import com.rosan.installer.domain.settings.repository.AppSettingsRepository
import com.rosan.installer.domain.settings.repository.BooleanSetting
import com.rosan.installer.domain.settings.model.preferences.ThemeState
import com.rosan.installer.domain.settings.provider.ThemeStateProvider
import com.rosan.installer.ui.navigation.InstallerNavContainer
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeRepository
import com.rosan.installer.ui.page.airsend.runtime.AirSendForegroundServicePolicy
import com.rosan.installer.ui.page.airsend.runtime.AndroidRuntimeReaderImpl
import com.rosan.installer.ui.page.airsend.AirSendShareTargetDialog
import com.rosan.installer.ui.theme.InstallerTheme
import com.rosan.installer.ui.theme.LocalWindowLayoutInfo
import com.rosan.installer.ui.theme.rememberWindowLayoutInfo
import org.koin.core.component.KoinComponent
import org.koin.core.component.inject
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import top.yukonga.miuix.kmp.theme.MiuixTheme

class SettingsActivity : ComponentActivity(), KoinComponent {
    private val themeStateProvider by inject<ThemeStateProvider>()
    private val airSendRepository by inject<AirSendRuntimeRepository>()
    private val appSettingsRepository by inject<AppSettingsRepository>()
    private val pendingShareIntent = mutableStateOf<Intent?>(null)
    private val pendingSharePreferredTargetId = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        // Enable edge-to-edge mode for immersive experience
        enableEdgeToEdge()

        var isThemeLoaded = false
        // Keep splash screen visible until data is safely loaded
        splashScreen.setKeepOnScreenCondition { !isThemeLoaded }

        super.onCreate(savedInstanceState)
        val runtimeReader = AndroidRuntimeReaderImpl(this)
        lifecycleScope.launch {
            // One event-driven refresh also republishes Direct Share targets after an update.
            airSendRepository.refresh(showIndicator = false)
        }
        if (runtimeReader.snapshot().bootStartEnabled) {
            lifecycleScope.launch {
                val showNotification = appSettingsRepository
                    .getBoolean(BooleanSetting.AirSendShowServiceNotification, false)
                    .first()
                val root = runtimeReader.rootDaemonSnapshot()
                if (showNotification ||
                    !AirSendForegroundServicePolicy.canRunWithoutAppService(root)
                ) {
                    runtimeReader.startService()
                }
            }
        }
        acceptShareIntent(intent)
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
                        pendingShareIntent.value?.let { shareIntent ->
                            AirSendShareTargetDialog(
                                shareIntent = shareIntent,
                                preferredTargetId = pendingSharePreferredTargetId.value,
                                repository = airSendRepository,
                                onDismiss = {
                                    pendingShareIntent.value = null
                                    pendingSharePreferredTargetId.value = null
                                    finish()
                                },
                                onSent = {
                                    pendingShareIntent.value = null
                                    pendingSharePreferredTargetId.value = null
                                    finish()
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptShareIntent(intent)
    }

    private fun acceptShareIntent(intent: Intent?) {
        val accepted = intent?.takeIf {
            it.getBooleanExtra(EXTRA_AIRSEND_SHARE, false) &&
                it.action in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)
        }
        pendingShareIntent.value = accepted
        pendingSharePreferredTargetId.value = accepted
            ?.getStringExtra(EXTRA_AIRSEND_PREFERRED_TARGET_ID)
            ?.takeIf(String::isNotBlank)
    }

    companion object {
        const val EXTRA_AIRSEND_SHARE = "com.airsend.extra.SHARE_TARGET"
        const val EXTRA_AIRSEND_PREFERRED_TARGET_ID = "com.airsend.extra.PREFERRED_TARGET_ID"
    }
}
