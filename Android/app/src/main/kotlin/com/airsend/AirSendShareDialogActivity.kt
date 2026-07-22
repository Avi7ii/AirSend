package com.airsend

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import com.rosan.installer.domain.settings.model.preferences.ThemeState
import com.rosan.installer.core.locale.AirSendLocale
import com.rosan.installer.domain.settings.provider.ThemeStateProvider
import com.rosan.installer.ui.page.airsend.AirSendShareTargetDialog
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeRepository
import com.rosan.installer.ui.theme.InstallerTheme
import com.rosan.installer.ui.theme.LocalWindowLayoutInfo
import com.rosan.installer.ui.theme.isPhoneDevice
import com.rosan.installer.ui.theme.rememberWindowLayoutInfo
import com.rosan.installer.ui.util.requestPortraitOrientationOnPhoneSafely
import kotlinx.coroutines.launch
import org.koin.core.component.KoinComponent
import org.koin.core.component.inject

/** Material share dialog hosted outside ColorOS's special share-target task. */
class AirSendShareDialogActivity : ComponentActivity(), KoinComponent {
    companion object {
        const val ACTION_SHOW_SHARE_DIALOG = "com.airsend.action.SHOW_SHARE_DIALOG"
        const val EXTRA_ORIGINAL_ACTION = "com.airsend.extra.ORIGINAL_SHARE_ACTION"
    }

    private val themeStateProvider by inject<ThemeStateProvider>()
    private val airSendRepository by inject<AirSendRuntimeRepository>()

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AirSendLocale.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showShareDialog(intent)
    }

    private fun showShareDialog(dialogIntent: Intent?) {
        val originalAction = dialogIntent?.getStringExtra(EXTRA_ORIGINAL_ACTION)
        if (dialogIntent == null || originalAction == null) {
            finishShareTask()
            return
        }

        val shareIntent = Intent(dialogIntent).apply {
            action = originalAction
            removeExtra(EXTRA_ORIGINAL_ACTION)
        }
        val preferredTargetId = shareIntent
            .getStringExtra("android.intent.extra.shortcut.ID")
            ?.removePrefix("peer_")
            ?.takeIf(String::isNotBlank)
            ?: shareIntent.getStringExtra(ShareTargetActivity.EXTRA_TARGET_ID)
                ?.takeIf(String::isNotBlank)

        lifecycleScope.launch {
            airSendRepository.refresh(showIndicator = false)
        }

        setContent {
            val uiState by themeStateProvider.themeStateFlow.collectAsStateWithLifecycle(
                initialValue = ThemeState()
            )
            if (!uiState.isLoaded) return@setContent

            val context = LocalContext.current
            val isPhone = context.isPhoneDevice
            LaunchedEffect(context, isPhone) {
                (context as? android.app.Activity)
                    ?.requestPortraitOrientationOnPhoneSafely(isPhone)
            }

            val layoutInfo = rememberWindowLayoutInfo()
            val systemDensity = LocalDensity.current
            val density = androidx.compose.runtime.remember(systemDensity, uiState.pageScale) {
                Density(
                    systemDensity.density * uiState.pageScale,
                    systemDensity.fontScale
                )
            }

            androidx.compose.runtime.CompositionLocalProvider(
                LocalWindowLayoutInfo provides layoutInfo,
                LocalDensity provides density
            ) {
                InstallerTheme(
                    useMiuix = false,
                    themeMode = uiState.themeMode,
                    paletteStyle = uiState.paletteStyle,
                    colorSpec = uiState.colorSpec,
                    useDynamicColor = uiState.useDynamicColor,
                    useMiuixMonet = uiState.useMiuixMonet,
                    seedColor = androidx.compose.ui.graphics.Color(uiState.seedColor)
                ) {
                    AirSendShareTargetDialog(
                        shareIntent = shareIntent,
                        preferredTargetId = preferredTargetId,
                        repository = airSendRepository,
                        onDismiss = ::finishShareTask,
                        onSent = ::finishShareTask
                    )
                }
            }
        }
    }

    private fun finishShareTask() {
        finishAndRemoveTask()
        overridePendingTransition(0, 0)
    }
}
