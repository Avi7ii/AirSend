// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2025-2026 InstallerX Revived contributors
@file:OptIn(ExperimentalMaterial3Api::class)

package com.rosan.installer.ui.page.main.settings.preferred.theme

import android.annotation.SuppressLint
import android.os.Build
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.add
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Colorize
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Style
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.ui.LocalNavAnimatedContentScope
import com.rosan.installer.R
import com.rosan.installer.domain.settings.model.preferences.PredictiveBackAnimation
import com.rosan.installer.domain.settings.model.preferences.PredictiveBackExitDirection
import com.rosan.installer.domain.settings.model.preferences.theme.PaletteStyle
import com.rosan.installer.domain.settings.model.preferences.theme.ThemeColorSpec
import com.rosan.installer.domain.settings.model.preferences.theme.ThemeMode
import com.rosan.installer.ui.icons.AppIcons
import com.rosan.installer.ui.navigation.LocalNavigator
import com.rosan.installer.ui.page.main.widget.setting.BaseWidget
import com.rosan.installer.ui.page.main.widget.setting.ExpressiveBackButton
import com.rosan.installer.ui.page.main.widget.setting.RadioButtonWidget
import com.rosan.installer.ui.page.main.widget.setting.SegmentedColumn
import com.rosan.installer.ui.page.main.widget.setting.SwitchWidget
import com.rosan.installer.ui.theme.getMaterial3AppBarColor
import com.rosan.installer.ui.theme.installerMaterial3BlurEffect
import com.rosan.installer.ui.theme.material.dynamicColorScheme
import com.rosan.installer.ui.theme.rememberMaterial3BlurBackdrop
import org.koin.androidx.compose.koinViewModel
import top.yukonga.miuix.kmp.blur.layerBackdrop

@SuppressLint("RestrictedApi")
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ThemeSettingsPage(
    viewModel: ThemeSettingsViewModel = koinViewModel()
) {
    val navigator = LocalNavigator.current
    val uiState by viewModel.state.collectAsStateWithLifecycle()
    val topAppBarState = rememberTopAppBarState(-154f, -154f) // from debugger
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior(topAppBarState)

    var showHideLauncherIconDialog by remember { mutableStateOf(false) }
    var showPaletteDialog by remember { mutableStateOf(false) }
    var showThemeModeDialog by remember { mutableStateOf(false) }
    var showPredictiveBackAnimationDialog by remember { mutableStateOf(false) }
    var showPredictiveBackExitDirectionDialog by remember { mutableStateOf(false) }
    val transition = LocalNavAnimatedContentScope.current.transition

    if (showPredictiveBackAnimationDialog) {
        PredictiveBackAnimationDialog(
            currentAnimation = uiState.predictiveBackAnimation,
            onDismiss = { showPredictiveBackAnimationDialog = false },
            onSelect = { animation ->
                // Hey Google
                // Why you keep playing the animation even we are already play completed?

                // This is very dirty, We are using RestrictedApi, but we don't have other choice
                transition.setPlaytimeAfterInitialAndTargetStateEstablished(
                    transition.targetState,
                    transition.targetState,
                    transition.playTimeNanos
                )

                viewModel.dispatch(ThemeSettingsAction.SetPredictiveBackAnimation(animation))
                showPredictiveBackAnimationDialog = false
            }
        )
    }

    if (showPredictiveBackExitDirectionDialog) {
        PredictiveBackExitDirectionDialog(
            currentDirection = uiState.predictiveBackExitDirection,
            onDismiss = { showPredictiveBackExitDirectionDialog = false },
            onSelect = { direction ->
                viewModel.dispatch(ThemeSettingsAction.SetPredictiveBackExitDirection(direction))
                showPredictiveBackExitDirectionDialog = false
            }
        )
    }

    if (showPaletteDialog) {
        PaletteStyleDialog(
            currentStyle = uiState.paletteStyle,
            onDismiss = { showPaletteDialog = false },
            onSelect = { style ->
                viewModel.dispatch(ThemeSettingsAction.SetPaletteStyle(style))
                showPaletteDialog = false
            }
        )
    }

    if (showThemeModeDialog) {
        ThemeModeDialog(
            currentMode = uiState.themeMode,
            onDismiss = { showThemeModeDialog = false },
            onSelect = { mode ->
                viewModel.dispatch(ThemeSettingsAction.SetThemeMode(mode))
                showThemeModeDialog = false
            }
        )
    }

    val backdrop = rememberMaterial3BlurBackdrop(uiState.useBlur)

    Scaffold(
        modifier = Modifier
            .nestedScroll(scrollBehavior.nestedScrollConnection)
            .fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
        topBar = {
            LargeFlexibleTopAppBar(
                modifier = Modifier.installerMaterial3BlurEffect(backdrop),
                windowInsets = TopAppBarDefaults.windowInsets.add(WindowInsets(left = 12.dp)),
                title = {
                    Text(stringResource(R.string.theme_settings))
                },
                navigationIcon = {
                    Row {
                        ExpressiveBackButton { navigator.pop() }
                        Spacer(modifier = Modifier.size(16.dp))
                    }
                },
                scrollBehavior = scrollBehavior,
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = backdrop.getMaterial3AppBarColor(),
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                    scrolledContainerColor = backdrop.getMaterial3AppBarColor()
                )
            )
        },
    ) { paddingValues ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .then(backdrop?.let { Modifier.layerBackdrop(it) } ?: Modifier),
            contentPadding = paddingValues
        ) {
            item {
                Spacer(modifier = Modifier.height(12.dp))
            }

            item {
                KsuThemePreviewCard(uiState)
            }

            item {
                val previewIsDark = when (uiState.themeMode) {
                    ThemeMode.LIGHT -> false
                    ThemeMode.DARK -> true
                    ThemeMode.SYSTEM -> isSystemInDarkTheme()
                }
                LazyRow(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 8.dp),
                    contentPadding = PaddingValues(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    item {
                        ColorButtonMaterial(
                            color = Color.Unspecified,
                            isSelected = uiState.useDynamicColor,
                            isDark = previewIsDark,
                            paletteStyle = uiState.paletteStyle,
                            colorSpec = uiState.colorSpec,
                            onClick = {
                                viewModel.dispatch(ThemeSettingsAction.SetUseDynamicColor(true))
                            }
                        )
                    }
                    items(uiState.availableColors, key = { it.key }) { rawColor ->
                        ColorButtonMaterial(
                            color = rawColor.color,
                            isSelected = !uiState.useDynamicColor && uiState.seedColor == rawColor.color,
                            isDark = previewIsDark,
                            paletteStyle = uiState.paletteStyle,
                            colorSpec = uiState.colorSpec,
                            onClick = {
                                viewModel.dispatch(ThemeSettingsAction.SetSeedColor(rawColor.color))
                            }
                        )
                    }
                }
            }

            item {
                SegmentedColumn(
                    title = stringResource(R.string.settings_monet)
                ) {
                    item {
                        BaseWidget(
                            icon = Icons.Rounded.Home,
                            title = stringResource(R.string.theme_settings_theme_mode),
                            description = when (uiState.themeMode) {
                                ThemeMode.LIGHT -> stringResource(R.string.theme_settings_theme_mode_light)
                                ThemeMode.DARK -> stringResource(R.string.theme_settings_theme_mode_dark)
                                ThemeMode.SYSTEM -> stringResource(R.string.theme_settings_theme_mode_system)
                            },
                            onClick = { showThemeModeDialog = true }
                        )
                    }
                    item {
                        BaseWidget(
                            icon = Icons.Rounded.Style,
                            title = stringResource(R.string.settings_color_style),
                            description = uiState.paletteStyle.displayName,
                            onClick = { showPaletteDialog = true }
                        )
                    }
                    item { ColorSpecSelector(viewModel) }
                }
            }

            item {
                SegmentedColumn(
                    title = stringResource(R.string.theme_settings_ui_style)
                ) {
                    item {
                        val selected = !uiState.showMiuixUI
                        val onClick = {
                            if (uiState.showMiuixUI) {
                                viewModel.dispatch(ThemeSettingsAction.ChangeUseMiuix(false))
                            }
                        }
                        RadioButtonWidget(
                            title = stringResource(R.string.theme_settings_google_ui),
                            description = stringResource(R.string.theme_settings_google_ui_desc),
                            iconPlaceholder = false,
                            selected = selected,
                            onClick = onClick
                        )
                    }
                    item {
                        val selected = uiState.showMiuixUI
                        val onClick = {
                            if (!uiState.showMiuixUI) {
                                viewModel.dispatch(ThemeSettingsAction.ChangeUseMiuix(true))
                            }
                        }
                        RadioButtonWidget(
                            title = stringResource(R.string.theme_settings_miuix_ui),
                            description = stringResource(R.string.theme_settings_miuix_ui_desc),
                            iconPlaceholder = false,
                            selected = selected,
                            onClick = onClick
                        )
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        item {
                            SwitchWidget(
                                icon = AppIcons.Blur,
                                title = stringResource(R.string.settings_enable_blur),
                                description = stringResource(R.string.settings_enable_blur_summary),
                                checked = uiState.useBlur,
                                onCheckedChange = { viewModel.dispatch(ThemeSettingsAction.SetUseBlur(it)) }
                            )
                        }
                    }
                    item {
                        SwitchWidget(
                            iconPlaceholder = false,
                            title = stringResource(R.string.settings_floating_bottom_bar),
                            description = stringResource(R.string.settings_floating_bottom_bar_summary),
                            checked = uiState.useAppleFloatingBar,
                            onCheckedChange = {
                                viewModel.dispatch(ThemeSettingsAction.SetUseAppleFloatingBar(it))
                            }
                        )
                    }
                    item {
                        var sliderValue by remember(uiState.pageScale) { mutableFloatStateOf(uiState.pageScale) }

                        Column(
                            modifier = Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    Icons.Rounded.AspectRatio,
                                    contentDescription = stringResource(id = R.string.settings_page_scale),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                Spacer(modifier = Modifier.width(12.dp))
                                Column(
                                    modifier = Modifier.weight(1f)
                                ) {
                                    Text(
                                        text = stringResource(R.string.settings_page_scale),
                                        style = MaterialTheme.typography.titleMedium,
                                        color = MaterialTheme.colorScheme.onSurface
                                    )
                                    Text(
                                        text = stringResource(id = R.string.settings_page_scale_summary),
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                Text(
                                    text = "${(sliderValue * 100).toInt()}%",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }

                            Slider(
                                value = sliderValue,
                                onValueChange = { sliderValue = it },
                                onValueChangeFinished = { viewModel.dispatch(ThemeSettingsAction.SetPageScale(sliderValue)) },
                                valueRange = 0.8f..1.1f,
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }
                }
            }

            // --- Group 4: Predictive Back ---
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                item {
                    SegmentedColumn(
                        title = stringResource(R.string.theme_settings_predictive_back)
                    ) {
                        item { PredictiveBackAnimationWidget(uiState) { showPredictiveBackAnimationDialog = true } }
                        item(
                            animatedVisibility = uiState.predictiveBackAnimation == PredictiveBackAnimation.Scale ||
                                    uiState.predictiveBackAnimation == PredictiveBackAnimation.AOSP
                        ) {
                            PredictiveBackAnimationDirectionWidget(uiState) { showPredictiveBackExitDirectionDialog = true }
                        }
                    }
                }
            }

        }
    }
}

@Composable
private fun KsuThemePreviewCard(uiState: ThemeSettingsState) {
    val configuration = LocalConfiguration.current
    val screenRatio = configuration.screenWidthDp.toFloat() / configuration.screenHeightDp.toFloat()
    val isDark = when (uiState.themeMode) {
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
    }
    val colorScheme = if (uiState.useDynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        MaterialTheme.colorScheme
    } else {
        dynamicColorScheme(
            keyColor = uiState.seedColor,
            isDark = isDark,
            style = uiState.paletteStyle,
            colorSpec = uiState.colorSpec
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 16.dp),
        contentAlignment = Alignment.TopCenter
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.42f)
                .aspectRatio(screenRatio),
            color = colorScheme.surfaceContainer,
            shape = RoundedCornerShape(20.dp),
            border = BorderStroke(1.dp, colorScheme.outlineVariant)
        ) {
            Column {
                Row(
                    modifier = Modifier
                        .height(48.dp)
                        .fillMaxWidth()
                        .padding(start = 12.dp, top = 16.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = stringResource(id = R.string.app_name),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colorScheme.onSurface
                    )
                }

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Surface(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(40.dp),
                        color = colorScheme.secondaryContainer,
                        shape = RoundedCornerShape(8.dp),
                        content = {}
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Surface(
                            modifier = Modifier
                                .weight(1f)
                                .height(32.dp),
                            color = colorScheme.surfaceBright,
                            shape = RoundedCornerShape(8.dp),
                            content = {}
                        )
                        Surface(
                            modifier = Modifier
                                .weight(1f)
                                .height(32.dp),
                            color = colorScheme.surfaceBright,
                            shape = RoundedCornerShape(8.dp),
                            content = {}
                        )
                    }
                    Surface(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(96.dp),
                        color = colorScheme.surfaceBright,
                        shape = RoundedCornerShape(8.dp),
                        content = {}
                    )
                }

                Surface(
                    color = colorScheme.surfaceContainer,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .height(40.dp)
                            .fillMaxWidth()
                            .padding(horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(Icons.Rounded.Home, null, tint = colorScheme.primary)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ColorButtonMaterial(
    color: Color,
    isSelected: Boolean,
    isDark: Boolean,
    paletteStyle: PaletteStyle = PaletteStyle.TonalSpot,
    colorSpec: ThemeColorSpec = ThemeColorSpec.SPEC_2025,
    onClick: () -> Unit
) {
    val haptic = LocalHapticFeedback.current
    val colorScheme = if (color == Color.Unspecified) {
        MaterialTheme.colorScheme
    } else {
        dynamicColorScheme(
            keyColor = color,
            isDark = isDark,
            style = paletteStyle,
            colorSpec = colorSpec,
        )
    }

    Surface(
        onClick = {
            haptic.performHapticFeedback(HapticFeedbackType.VirtualKey)
            onClick()
        },
        shape = RoundedCornerShape(20.dp),
        color = colorScheme.surfaceContainer,
        modifier = Modifier.size(72.dp)
    ) {
        Box(contentAlignment = Alignment.Center) {
            Canvas(modifier = Modifier.size(48.dp)) {
                drawArc(
                    color = colorScheme.primaryContainer,
                    startAngle = 180f,
                    sweepAngle = 180f,
                    useCenter = true
                )
                drawArc(
                    color = colorScheme.tertiaryContainer,
                    startAngle = 0f,
                    sweepAngle = 180f,
                    useCenter = true
                )
            }

            val scale by animateFloatAsState(targetValue = if (isSelected) 1.1f else 1.0f)
            Box(
                modifier = Modifier.graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                },
                contentAlignment = Alignment.Center
            ) {
                AnimatedVisibility(
                    visible = isSelected,
                    enter = fadeIn() + scaleIn(initialScale = 0.8f),
                    exit = fadeOut() + scaleOut(targetScale = 0.8f)
                ) {
                    Box(
                        modifier = Modifier
                            .size(56.dp)
                            .border(2.dp, colorScheme.primary, CircleShape),
                        contentAlignment = Alignment.Center
                    ) {
                        Box(
                            modifier = Modifier
                                .size(24.dp)
                                .clip(CircleShape)
                                .background(colorScheme.primary, CircleShape)
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Check,
                                contentDescription = null,
                                tint = colorScheme.onPrimary,
                                modifier = Modifier
                                    .align(Alignment.Center)
                                    .size(16.dp)
                            )
                        }
                    }
                }
                AnimatedVisibility(
                    visible = !isSelected,
                    enter = fadeIn() + scaleIn(initialScale = 0.8f),
                    exit = fadeOut() + scaleOut(targetScale = 0.8f)
                ) {
                    Box(
                        modifier = Modifier
                            .size(20.dp)
                            .background(colorScheme.primary, CircleShape)
                    )
                }
            }
        }
    }
}

@Composable
fun PaletteStyleDialog(
    currentStyle: PaletteStyle,
    onDismiss: () -> Unit,
    onSelect: (PaletteStyle) -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.theme_settings_palette_style_desc)) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                PaletteStyle.entries.forEach { style ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(style) }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(
                            selected = (style == currentStyle),
                            onClick = { onSelect(style) }
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(style.displayName)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.close))
            }
        }
    )
}

@Composable
fun PredictiveBackAnimationDialog(
    currentAnimation: PredictiveBackAnimation,
    onDismiss: () -> Unit,
    onSelect: (PredictiveBackAnimation) -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.theme_settings_predictive_back_animation_desc)) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                PredictiveBackAnimation.entries.forEach { animation ->
                    val animationText = when (animation) {
                        PredictiveBackAnimation.None -> stringResource(R.string.theme_settings_predictive_back_animation_none)
                        PredictiveBackAnimation.AOSP -> stringResource(R.string.theme_settings_predictive_back_animation_aosp)
                        PredictiveBackAnimation.MIUIX -> stringResource(R.string.theme_settings_predictive_back_animation_miuix)
                        PredictiveBackAnimation.Scale -> stringResource(R.string.theme_settings_predictive_back_animation_scale)
                        PredictiveBackAnimation.Classic -> stringResource(R.string.theme_settings_predictive_back_animation_ksu_classic)
                    }
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(animation) }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(
                            selected = (animation == currentAnimation),
                            onClick = { onSelect(animation) }
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(animationText)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.close))
            }
        }
    )
}

@Composable
fun PredictiveBackExitDirectionDialog(
    currentDirection: PredictiveBackExitDirection,
    onDismiss: () -> Unit,
    onSelect: (PredictiveBackExitDirection) -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.theme_settings_predictive_back_exit_direction_desc)) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                PredictiveBackExitDirection.entries.forEach { direction ->
                    val directionText = when (direction) {
                        PredictiveBackExitDirection.FOLLOW_GESTURE -> stringResource(R.string.theme_settings_predictive_back_exit_direction_follow_gesture)
                        PredictiveBackExitDirection.ALWAYS_RIGHT -> stringResource(R.string.theme_settings_predictive_back_exit_direction_always_right)
                        PredictiveBackExitDirection.ALWAYS_LEFT -> stringResource(R.string.theme_settings_predictive_back_exit_direction_always_left)
                    }
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(direction) }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(
                            selected = (direction == currentDirection),
                            onClick = { onSelect(direction) }
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(directionText)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.close))
            }
        }
    )
}

@Composable
fun ThemeModeDialog(
    currentMode: ThemeMode,
    onDismiss: () -> Unit,
    onSelect: (ThemeMode) -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.theme_settings_theme_mode_desc)) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                ThemeMode.entries.forEach { mode ->
                    val modeText = when (mode) {
                        ThemeMode.LIGHT -> stringResource(R.string.theme_settings_theme_mode_light)
                        ThemeMode.DARK -> stringResource(R.string.theme_settings_theme_mode_dark)
                        ThemeMode.SYSTEM -> stringResource(R.string.theme_settings_theme_mode_system)
                    }
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(mode) }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(
                            selected = (mode == currentMode),
                            onClick = { onSelect(mode) }
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(modeText)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.close))
            }
        }
    )
}
