// Copyright 2026, Kyant0/AndroidLiquidGlass contributors
// Copyright 2026, InstallerX Revived contributors
// SPDX-License-Identifier: Apache-2.0

package com.rosan.installer.ui.library

// Adapted from AndroidLiquidGlass' LiquidToggle example:
// https://github.com/Kyant0/AndroidLiquidGlass

import androidx.compose.foundation.background
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.util.fastCoerceIn
import androidx.compose.ui.util.lerp
import com.rosan.installer.ui.animation.DampedDragAnimation
import com.rosan.installer.ui.library.liquid.InnerShadow
import com.rosan.installer.ui.library.liquid.innerShadow
import com.rosan.installer.ui.library.liquid.lens
import com.rosan.installer.ui.library.liquid.rememberCombinedBackdrop
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import top.yukonga.miuix.kmp.blur.Backdrop
import top.yukonga.miuix.kmp.blur.blur
import top.yukonga.miuix.kmp.blur.drawBackdrop
import top.yukonga.miuix.kmp.blur.highlight.Highlight
import top.yukonga.miuix.kmp.blur.layerBackdrop
import top.yukonga.miuix.kmp.blur.rememberLayerBackdrop
import top.yukonga.miuix.kmp.theme.MiuixTheme

@Composable
fun LiquidToggle(
    selected: () -> Boolean,
    onSelect: (Boolean) -> Unit,
    backdrop: Backdrop? = null,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    checkedTrackColor: Color = MiuixTheme.colorScheme.primary,
    uncheckedTrackColor: Color = MiuixTheme.colorScheme.onSurface.copy(alpha = 0.18f),
    thumbColor: Color = Color.White
) {
    val density = LocalDensity.current
    val isLtr = LocalLayoutDirection.current == LayoutDirection.Ltr
    val dragWidth = with(density) { ToggleDragWidth.toPx() }
    val glassOvershootPx = with(density) { ToggleGlassOvershoot.toPx() }
    val animationScope = rememberCoroutineScope()
    val glassOvershoot = remember { Animatable(0f) }
    var didDrag by remember { mutableStateOf(false) }
    var fraction by remember { mutableFloatStateOf(if (selected()) 1f else 0f) }

    fun launchGlassOvershoot(settledFraction: Float) {
        val outwardDirection = when {
            isLtr && settledFraction == 1f -> 1f
            isLtr -> -1f
            settledFraction == 1f -> -1f
            else -> 1f
        }
        animationScope.launch {
            glassOvershoot.stop()
            glassOvershoot.snapTo(0f)
            delay(45)
            glassOvershoot.animateTo(
                targetValue = outwardDirection * glassOvershootPx,
                animationSpec = tween(
                    durationMillis = 75,
                    easing = FastOutSlowInEasing
                )
            )
            glassOvershoot.animateTo(
                targetValue = 0f,
                animationSpec = spring(
                    dampingRatio = 0.82f,
                    stiffness = 900f,
                    visibilityThreshold = 0.1f
                )
            )
        }
    }

    val dampedDragAnimation = remember(animationScope, enabled, isLtr, dragWidth) {
        DampedDragAnimation(
            animationScope = animationScope,
            initialValue = fraction,
            valueRange = 0f..1f,
            visibilityThreshold = 0.001f,
            initialScale = 1f,
            pressedScale = 1.7f,
            canDrag = { enabled },
            onDragStarted = {
                animationScope.launch { glassOvershoot.snapTo(0f) }
            },
            onDragStopped = {
                if (enabled) {
                    val settledFraction: Float
                    if (didDrag) {
                        settledFraction = if (targetValue >= 0.5f) 1f else 0f
                        didDrag = false
                    } else {
                        settledFraction = if (selected()) 0f else 1f
                    }
                    fraction = settledFraction
                    onSelect(fraction == 1f)
                    launchGlassOvershoot(settledFraction)
                }
            },
            onDrag = { _, dragAmount ->
                if (!didDrag) didDrag = dragAmount.x != 0f
                val delta = dragAmount.x / dragWidth
                fraction = if (isLtr) {
                    (fraction + delta).fastCoerceIn(0f, 1f)
                } else {
                    (fraction - delta).fastCoerceIn(0f, 1f)
                }
            }
        )
    }

    LaunchedEffect(dampedDragAnimation) {
        snapshotFlow { fraction }.collectLatest(dampedDragAnimation::updateValue)
    }
    LaunchedEffect(selected) {
        snapshotFlow { selected() }.collectLatest { isSelected ->
            val target = if (isSelected) 1f else 0f
            if (target != fraction) {
                fraction = target
                dampedDragAnimation.animateToValue(target)
                launchGlassOvershoot(target)
            }
        }
    }

    val trackBackdrop = rememberLayerBackdrop()
    val sampledBackdrop = if (backdrop != null) {
        rememberCombinedBackdrop(backdrop, trackBackdrop)
    } else {
        trackBackdrop
    }
    val isDark = com.rosan.installer.ui.theme.InstallerTheme.isDark
    val highlight = if (isDark) {
        Highlight.GlassStrokeBigDark
    } else {
        Highlight.GlassStrokeBigLight
    }

    Box(
        modifier = modifier
            .alpha(if (enabled) 1f else 0.38f)
            .semantics {
                role = Role.Switch
                toggleableState = if (selected()) ToggleableState.On else ToggleableState.Off
                if (!enabled) disabled()
            },
        contentAlignment = Alignment.CenterStart
    ) {
        Box(
            modifier = Modifier
                .layerBackdrop(trackBackdrop)
                .size(ToggleTrackWidth, ToggleTrackHeight),
            contentAlignment = Alignment.CenterStart
        ) {
            Box(
                Modifier
                    .clip(CircleShape)
                    .drawBehind {
                        drawRect(lerp(uncheckedTrackColor, checkedTrackColor, dampedDragAnimation.value))
                    }
                    .size(ToggleTrackWidth, ToggleTrackHeight)
            )

            Box(
                Modifier
                    .graphicsLayer {
                        val padding = TogglePadding.toPx()
                        translationX = toggleTranslationX(
                            isLtr = isLtr,
                            padding = padding,
                            dragWidth = dragWidth,
                            fraction = dampedDragAnimation.value
                        )
                    }
                    .dropShadow(
                        shape = CircleShape,
                        shadow = Shadow(
                            radius = 4.dp,
                            color = Color.Black,
                            alpha = 0.1f
                        )
                    )
                    .background(thumbColor, CircleShape)
                    .size(ToggleThumbWidth, ToggleThumbHeight)
            )
        }

        Box(
            Modifier
                .graphicsLayer {
                    val padding = TogglePadding.toPx() + ToggleGlassInset.toPx()
                    translationX = toggleTranslationX(
                        isLtr = isLtr,
                        padding = padding,
                        dragWidth = dragWidth,
                        fraction = dampedDragAnimation.value
                    ) + glassOvershoot.value
                }
                .then(dampedDragAnimation.modifier)
                .drawBackdrop(
                    backdrop = sampledBackdrop,
                    shape = { CircleShape },
                    effects = {
                        val progress = dampedDragAnimation.pressProgress
                        blur(0.2.dp.toPx())
                        lens(
                            refractionHeight = lerp(1f, 6f, progress).dp.toPx(),
                            refractionAmount = lerp(2f, 11f, progress).dp.toPx(),
                            depthEffect = true,
                            chromaticAberration = lerp(0.15f, 0.4f, progress)
                        )
                    },
                    highlight = {
                        highlight.copy(alpha = lerp(0.04f, 0.58f, dampedDragAnimation.pressProgress))
                    },
                    layerBlock = {
                        scaleX = dampedDragAnimation.scaleX
                        scaleY = dampedDragAnimation.scaleY
                        val velocity = dampedDragAnimation.velocity / 50f
                        scaleX /= 1f - (velocity * 0.75f).fastCoerceIn(-0.2f, 0.2f)
                        scaleY *= 1f - (velocity * 0.25f).fastCoerceIn(-0.2f, 0.2f)
                    },
                    onDrawSurface = {
                        val progress = dampedDragAnimation.pressProgress
                        drawRect(Color.White.copy(alpha = lerp(0.008f, 0.018f, progress)))
                    }
                )
                .innerShadow(shape = CircleShape) {
                    val progress = dampedDragAnimation.pressProgress
                    InnerShadow(
                        radius = 5.dp * progress,
                        color = Color.Black.copy(alpha = 0.16f),
                        alpha = progress
                    )
                }
                .size(ToggleGlassWidth, ToggleGlassHeight)
        )
    }
}

private fun toggleTranslationX(
    isLtr: Boolean,
    padding: Float,
    dragWidth: Float,
    fraction: Float
): Float = if (isLtr) {
    lerp(padding, padding + dragWidth, fraction)
} else {
    lerp(-padding, -(padding + dragWidth), fraction)
}

private val ToggleTrackWidth = 60.dp
private val ToggleTrackHeight = 30.dp
private val ToggleThumbWidth = 32.dp
private val ToggleThumbHeight = 24.dp
private val ToggleGlassWidth = 30.dp
private val ToggleGlassHeight = 20.dp
private val ToggleGlassInset = 1.dp
private val ToggleGlassOvershoot = 6.dp
private val TogglePadding = 3.dp
private val ToggleDragWidth = ToggleTrackWidth - ToggleThumbWidth - TogglePadding * 2
