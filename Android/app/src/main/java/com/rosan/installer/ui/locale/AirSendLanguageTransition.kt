// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.locale

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import com.rosan.installer.core.locale.AirSendLanguageRequest
import com.rosan.installer.core.locale.AirSendLocale

/**
 * Switches locale inside the current Compose tree without recreating its Activity.
 *
 * The old language fades to the stable themed background, resources switch while
 * content is transparent, and the same navigation tree fades back in. This keeps
 * scroll position, navigation state, ViewModels, blur layers, and Miuix animation
 * state alive while avoiding the cost of rendering two complete pages at once.
 */
@Composable
fun AirSendLanguageTransition(
    request: AirSendLanguageRequest,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit
) {
    val context = LocalContext.current
    val hostConfiguration = LocalConfiguration.current
    var displayedLanguage by remember { mutableStateOf(AirSendLocale.appliedLanguage) }
    val contentAlpha = remember { Animatable(1f) }

    LaunchedEffect(request.sequence) {
        val language = request.language
        if (language == displayedLanguage && language == AirSendLocale.appliedLanguage) {
            contentAlpha.snapTo(1f)
            return@LaunchedEffect
        }

        contentAlpha.animateTo(
            targetValue = 0f,
            animationSpec = tween(
                durationMillis = 90,
                easing = FastOutLinearInEasing
            )
        )

        AirSendLocale.apply(context, language)
        displayedLanguage = language

        // Give stringResource() one frame to resolve the new resource set while
        // content is still transparent, so no mixed-language frame is presented.
        withFrameNanos { }

        contentAlpha.animateTo(
            targetValue = 1f,
            animationSpec = tween(
                durationMillis = 190,
                easing = LinearOutSlowInEasing
            )
        )
    }

    val localizedConfiguration = remember(hostConfiguration, displayedLanguage) {
        AirSendLocale.configuration(hostConfiguration, displayedLanguage)
    }
    val localizedResources = remember(context, localizedConfiguration) {
        context.createConfigurationContext(localizedConfiguration).resources
    }

    CompositionLocalProvider(
        LocalConfiguration provides localizedConfiguration,
        LocalResources provides localizedResources
    ) {
        Box(
            modifier = modifier.graphicsLayer {
                alpha = contentAlpha.value
            },
            content = content
        )
    }
}
