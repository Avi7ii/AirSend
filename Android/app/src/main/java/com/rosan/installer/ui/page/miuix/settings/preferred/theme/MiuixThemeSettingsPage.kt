// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2025-2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.miuix.settings.preferred.theme

import android.annotation.SuppressLint
import android.os.Build
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.ui.LocalNavAnimatedContentScope
import com.rosan.installer.R
import com.rosan.installer.domain.settings.model.preferences.PredictiveBackAnimation
import com.rosan.installer.domain.settings.model.preferences.PredictiveBackExitDirection
import com.rosan.installer.ui.navigation.LocalNavigator
import com.rosan.installer.ui.page.main.settings.preferred.theme.ThemeSettingsAction
import com.rosan.installer.ui.page.main.settings.preferred.theme.ThemeSettingsState
import com.rosan.installer.ui.page.main.settings.preferred.theme.ThemeSettingsViewModel
import com.rosan.installer.ui.page.miuix.widgets.MiuixBackButton
import com.rosan.installer.ui.page.miuix.widgets.MiuixSwitchWidget
import com.rosan.installer.ui.theme.getMiuixAppBarColor
import com.rosan.installer.ui.theme.installerMiuixBlurEffect
import com.rosan.installer.domain.settings.model.preferences.theme.PaletteStyle
import com.rosan.installer.domain.settings.model.preferences.theme.ThemeColorSpec
import com.rosan.installer.domain.settings.model.preferences.theme.ThemeMode
import com.rosan.installer.ui.theme.material.RawColor
import com.rosan.installer.ui.theme.material.dynamicColorScheme
import com.rosan.installer.ui.theme.rememberMiuixBlurBackdrop
import com.rosan.installer.ui.util.getDisplayName
import org.koin.androidx.compose.koinViewModel
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.BasicComponentDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.DropdownArrowEndAction
import top.yukonga.miuix.kmp.basic.DropdownDefaults
import top.yukonga.miuix.kmp.basic.DropdownEntry
import top.yukonga.miuix.kmp.basic.DropdownItem
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.MiuixScrollBehavior
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.Slider
import top.yukonga.miuix.kmp.basic.SliderDefaults
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.TabRow
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.blur.layerBackdrop
import top.yukonga.miuix.kmp.popup.OverlayDropdownPopup
import top.yukonga.miuix.kmp.preference.ArrowPreference
import top.yukonga.miuix.kmp.preference.WindowSpinnerPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.utils.overScrollVertical
import top.yukonga.miuix.kmp.utils.scrollEndHaptic

@SuppressLint("RestrictedApi")
@Composable
fun MiuixThemeSettingsPage(
    viewModel: ThemeSettingsViewModel = koinViewModel()
) {
    val navigator = LocalNavigator.current
    val uiState by viewModel.state.collectAsStateWithLifecycle()
    val scrollBehavior = MiuixScrollBehavior()
    val transition = LocalNavAnimatedContentScope.current.transition

    val layoutDirection = LocalLayoutDirection.current
    val horizontalSafeInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal).asPaddingValues()

    val topBarBackdrop = rememberMiuixBlurBackdrop(uiState.useBlur)

    Scaffold(
        topBar = {
            TopAppBar(
                modifier = Modifier.installerMiuixBlurEffect(topBarBackdrop),
                color = topBarBackdrop.getMiuixAppBarColor(),
                title = stringResource(R.string.theme_settings),
                navigationIcon = {
                    MiuixBackButton(onClick = { navigator.pop() })
                },
                scrollBehavior = scrollBehavior
            )
        }
    ) { paddingValues ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .then(topBarBackdrop?.let { Modifier.layerBackdrop(it) } ?: Modifier)
                .scrollEndHaptic()
                .overScrollVertical()
                .nestedScroll(scrollBehavior.nestedScrollConnection),
            contentPadding = PaddingValues(
                start = horizontalSafeInsets.calculateStartPadding(layoutDirection),
                top = paddingValues.calculateTopPadding(),
                end = horizontalSafeInsets.calculateEndPadding(layoutDirection)
            ),
            overscrollEffect = null
        ) {
            item {
                Spacer(modifier = Modifier.height(24.dp))
            }
            item {
                KsuMiuixThemePreviewCard(uiState)
            }
            item {
                Spacer(modifier = Modifier.height(40.dp))
            }
            item {
                KsuMiuixThemeModeTabs(
                    currentThemeMode = uiState.themeMode,
                    onThemeModeChange = { viewModel.dispatch(ThemeSettingsAction.SetThemeMode(it)) }
                )
            }
            item {
                Card(
                    modifier = Modifier
                        .padding(horizontal = 12.dp)
                        .padding(top = 12.dp, bottom = 12.dp)
                ) {
                    MiuixSwitchWidget(
                        title = stringResource(R.string.settings_monet),
                        description = stringResource(R.string.theme_settings_dynamic_color_desc),
                        checked = uiState.useMiuixMonet,
                        onCheckedChange = {
                            viewModel.dispatch(ThemeSettingsAction.SetUseMiuixMonet(it))
                        }
                    )
                    AnimatedVisibility(
                        visible = uiState.useMiuixMonet,
                        enter = fadeIn() + expandVertically(),
                        exit = fadeOut() + shrinkVertically()
                    ) {
                        Column {
                            MiuixKeyColorWidget(
                                colors = uiState.availableColors,
                                currentColor = uiState.seedColor,
                                useDynamicColor = uiState.useDynamicColor,
                                currentPaletteStyle = uiState.paletteStyle,
                                currentColorSpec = uiState.colorSpec,
                                themeMode = uiState.themeMode,
                                onUseDynamicColor = {
                                    viewModel.dispatch(ThemeSettingsAction.SetUseDynamicColor(true))
                                },
                                onColorSelected = {
                                    viewModel.dispatch(ThemeSettingsAction.SetSeedColor(it))
                                }
                            )
                            AnimatedVisibility(
                                visible = !uiState.useDynamicColor || Build.VERSION.SDK_INT < Build.VERSION_CODES.S,
                                enter = fadeIn() + expandVertically(),
                                exit = fadeOut() + shrinkVertically()
                            ) {
                                Column {
                                    MiuixPaletteStyleWidget(
                                        currentPaletteStyle = uiState.paletteStyle,
                                        currentColor = uiState.seedColor,
                                        useDynamicColor = uiState.useDynamicColor,
                                        currentColorSpec = uiState.colorSpec,
                                        themeMode = uiState.themeMode,
                                        onPaletteStyleChange = { newStyle ->
                                            viewModel.dispatch(ThemeSettingsAction.SetPaletteStyle(newStyle))
                                        }
                                    )
                                    MiuixColorSpecWidget(
                                        currentColorSpec = uiState.colorSpec,
                                        currentPaletteStyle = uiState.paletteStyle,
                                        onColorSpecChange = { newSpec ->
                                            viewModel.dispatch(ThemeSettingsAction.SetColorSpec(newSpec))
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            item { SmallTitle(stringResource(R.string.theme_settings_ui_style)) }
            item {
                Card(
                    modifier = Modifier
                        .padding(horizontal = 12.dp)
                        .padding(bottom = 12.dp)
                ) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        MiuixSwitchWidget(
                            title = stringResource(R.string.settings_enable_blur),
                            description = stringResource(R.string.settings_enable_blur_summary),
                            checked = uiState.useBlur,
                            onCheckedChange = { viewModel.dispatch(ThemeSettingsAction.SetUseBlur(it)) }
                        )
                    }
                    MiuixSwitchWidget(
                        title = stringResource(R.string.settings_floating_bottom_bar),
                        description = stringResource(R.string.settings_floating_bottom_bar_summary),
                        checked = uiState.useAppleFloatingBar,
                        onCheckedChange = {
                            viewModel.dispatch(ThemeSettingsAction.SetUseAppleFloatingBar(it))
                        }
                    )
                    var sliderValue by remember(uiState.pageScale) { mutableFloatStateOf(uiState.pageScale) }
                    ArrowPreference(
                        title = stringResource(id = R.string.settings_page_scale),
                        summary = stringResource(id = R.string.settings_page_scale_summary),
                        startAction = {
                            Icon(
                                imageVector = Icons.Rounded.AspectRatio,
                                modifier = Modifier.padding(end = 6.dp),
                                contentDescription = stringResource(id = R.string.settings_page_scale),
                                tint = MiuixTheme.colorScheme.onBackground
                            )
                        },
                        endActions = {
                            Text(
                                text = "${(sliderValue * 100).toInt()}%",
                                color = MiuixTheme.colorScheme.onSurfaceVariantActions,
                            )
                        },
                        bottomAction = {
                            Slider(
                                value = sliderValue,
                                onValueChange = {
                                    sliderValue = it
                                },
                                onValueChangeFinished = {
                                    viewModel.dispatch(ThemeSettingsAction.SetPageScale(sliderValue))
                                },
                                valueRange = 0.8f..1.1f,
                                showKeyPoints = true,
                                keyPoints = listOf(0.8f, 0.9f, 1f, 1.1f),
                                magnetThreshold = 0.01f,
                                hapticEffect = SliderDefaults.SliderHapticEffect.Step,
                            )
                        },
                    )
                }
            }

            // Predictive Back Section
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                item { SmallTitle(stringResource(R.string.theme_settings_predictive_back)) }
                item {
                    Card(
                        modifier = Modifier
                            .padding(horizontal = 12.dp)
                            .padding(bottom = 12.dp)
                    ) {
                        MiuixPredictiveBackAnimationWidget(
                            currentAnimation = uiState.predictiveBackAnimation,
                            onAnimationChange = { newAnim ->
                                // Hey Google
                                // Why you keep playing the animation even we are already play completed?
                                // This is very dirty, We are using RestrictedApi, but we don't have other choice
                                transition.setPlaytimeAfterInitialAndTargetStateEstablished(
                                    transition.targetState,
                                    transition.targetState,
                                    transition.playTimeNanos
                                )

                                viewModel.dispatch(ThemeSettingsAction.SetPredictiveBackAnimation(newAnim))
                            }
                        )

                        AnimatedVisibility(
                            visible = uiState.predictiveBackAnimation == PredictiveBackAnimation.Scale ||
                                    uiState.predictiveBackAnimation == PredictiveBackAnimation.AOSP,
                            enter = fadeIn() + expandVertically(),
                            exit = fadeOut() + shrinkVertically()
                        ) {
                            MiuixPredictiveBackExitDirectionWidget(
                                currentDirection = uiState.predictiveBackExitDirection,
                                onDirectionChange = {
                                    transition.setPlaytimeAfterInitialAndTargetStateEstablished(
                                        transition.targetState,
                                        transition.targetState,
                                        transition.playTimeNanos
                                    )
                                    viewModel.dispatch(ThemeSettingsAction.SetPredictiveBackExitDirection(it))
                                }
                            )
                        }
                    }
                }
            }

            item { Spacer(Modifier.navigationBarsPadding()) }
        }
    }
}

@Composable
private fun KsuMiuixThemePreviewCard(uiState: ThemeSettingsState) {
    val configuration = LocalConfiguration.current
    val screenRatio = configuration.screenWidthDp.toFloat() / configuration.screenHeightDp.toFloat()
    val isDark = when (uiState.themeMode) {
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
    }
    val seedColor = if (uiState.useDynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        MiuixTheme.colorScheme.primary
    } else {
        uiState.seedColor
    }
    val dynamicScheme = dynamicColorScheme(
        keyColor = seedColor,
        isDark = isDark,
        style = uiState.paletteStyle,
        colorSpec = uiState.colorSpec,
    )

    val bgColor = if (uiState.useMiuixMonet) dynamicScheme.background else MiuixTheme.colorScheme.surface
    val textColor = if (uiState.useMiuixMonet) dynamicScheme.onSurface else MiuixTheme.colorScheme.onBackground
    val accentCardColor = when {
        uiState.useMiuixMonet -> dynamicScheme.secondaryContainer
        isDark -> Color(0xFF1A3825)
        else -> Color(0xFFDFFAE4)
    }
    val cardColor = if (uiState.useMiuixMonet) dynamicScheme.surfaceContainerHighest else MiuixTheme.colorScheme.surfaceVariant
    val navBarColor = if (uiState.useMiuixMonet) dynamicScheme.surfaceContainer else MiuixTheme.colorScheme.surface
    val navSelectedColor = if (uiState.useMiuixMonet) dynamicScheme.primary else MiuixTheme.colorScheme.primary
    val navUnselectedColor = textColor.copy(alpha = 0.45f)

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 12.dp),
        contentAlignment = Alignment.TopCenter
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(0.42f)
                .aspectRatio(screenRatio)
                .clip(RoundedCornerShape(20.dp))
                .background(bgColor)
                .border(1.dp, textColor.copy(alpha = 0.12f), RoundedCornerShape(20.dp))
        ) {
            Column {
                Row(
                    modifier = Modifier
                        .height(48.dp)
                        .fillMaxWidth()
                        .padding(start = 12.dp, top = 24.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = stringResource(id = R.string.app_name),
                        fontSize = 12.sp,
                        color = textColor
                    )
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(65.dp)
                        .padding(horizontal = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .clip(RoundedCornerShape(6.dp))
                            .background(accentCardColor)
                    )
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight(),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .clip(RoundedCornerShape(6.dp))
                                .background(cardColor)
                        )
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .clip(RoundedCornerShape(6.dp))
                                .background(cardColor)
                        )
                    }
                }

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(0.8f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(cardColor)
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(0.1f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(cardColor)
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(0.1f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(cardColor)
                    )
                }
            }

            if (uiState.useAppleFloatingBar) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 8.dp),
                ) {
                    Row(
                        modifier = Modifier
                            .height(28.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(if (uiState.useBlur) navBarColor.copy(alpha = 0.5f) else navBarColor)
                            .border(0.5.dp, textColor.copy(alpha = 0.1f), RoundedCornerShape(14.dp))
                            .padding(horizontal = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        repeat(4) {
                            Box(
                                modifier = Modifier
                                    .size(13.dp)
                                    .clip(RoundedCornerShape(2.dp))
                                    .background(if (it == 0) navSelectedColor else navUnselectedColor)
                            )
                        }
                    }
                }
            } else {
                Column(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(0.5.dp)
                            .background(textColor.copy(alpha = 0.1f))
                    )
                    Row(
                        modifier = Modifier
                            .height(36.dp)
                            .fillMaxWidth()
                            .background(navBarColor)
                            .padding(top = 2.dp, bottom = 8.dp),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        repeat(4) {
                            Box(
                                modifier = Modifier
                                    .size(15.dp)
                                    .clip(RoundedCornerShape(3.dp))
                                    .background(if (it == 0) navSelectedColor else navUnselectedColor)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun KsuMiuixThemeModeTabs(
    currentThemeMode: ThemeMode,
    onThemeModeChange: (ThemeMode) -> Unit
) {
    val items = listOf(
        stringResource(id = R.string.theme_settings_theme_mode_system_short),
        stringResource(id = R.string.theme_settings_theme_mode_light_short),
        stringResource(id = R.string.theme_settings_theme_mode_dark_short),
    )
    val selectedIndex = when (currentThemeMode) {
        ThemeMode.SYSTEM -> 0
        ThemeMode.LIGHT -> 1
        ThemeMode.DARK -> 2
    }

    TabRow(
        tabs = items,
        selectedTabIndex = selectedIndex,
        onTabSelected = { index ->
            val mode = when (index) {
                1 -> ThemeMode.LIGHT
                2 -> ThemeMode.DARK
                else -> ThemeMode.SYSTEM
            }
            onThemeModeChange(mode)
        },
        height = 48.dp,
    )
}

@Composable
private fun MiuixKeyColorWidget(
    colors: List<RawColor>,
    currentColor: Color,
    useDynamicColor: Boolean,
    currentPaletteStyle: PaletteStyle,
    currentColorSpec: ThemeColorSpec,
    themeMode: ThemeMode,
    onUseDynamicColor: () -> Unit,
    onColorSelected: (Color) -> Unit
) {
    val colorItems = listOf(stringResource(R.string.settings_key_color_default)) +
            colors.map { it.getDisplayName() }
    val selectedIndex = if (useDynamicColor) {
        0
    } else {
        colors.indexOfFirst { it.color == currentColor }.takeIf { it >= 0 }?.plus(1) ?: 0
    }
    val isDark = rememberThemeIsDark(themeMode)
    val entries = colorItems.mapIndexed { index, item ->
        val previewColor = if (index == 0) currentColor else colors[index - 1].color
        DropdownItem(
            text = item,
            selected = index == selectedIndex,
            onClick = {
                if (index == 0) {
                    onUseDynamicColor()
                } else {
                    onColorSelected(colors[index - 1].color)
                }
            },
            icon = { modifier ->
                BoxThemeColorDots(
                    modifier = modifier.width(42.dp),
                    seedColor = previewColor,
                    useDynamicColor = index == 0,
                    style = currentPaletteStyle,
                    colorSpec = currentColorSpec,
                    isDark = isDark
                )
            }
        )
    }

    BoxPreviewDropdownPreference(
        title = stringResource(R.string.settings_key_color),
        value = colorItems[selectedIndex],
        entry = DropdownEntry(entries),
        preview = {
            BoxThemeColorDots(
                seedColor = currentColor,
                useDynamicColor = useDynamicColor,
                style = currentPaletteStyle,
                colorSpec = currentColorSpec,
                isDark = isDark
            )
        },
    )
}

@Composable
private fun BoxPreviewDropdownPreference(
    title: String,
    value: String,
    entry: DropdownEntry,
    modifier: Modifier = Modifier,
    preview: (@Composable () -> Unit)? = null,
    enabled: Boolean = true,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isDropdownExpanded = remember { mutableStateOf(false) }
    val isHoldDown = remember { mutableStateOf(false) }
    val hapticFeedback = LocalHapticFeedback.current
    val currentHapticFeedback by rememberUpdatedState(hapticFeedback)
    val itemsNotEmpty = entry.items.isNotEmpty()
    val actualEnabled = enabled && itemsNotEmpty
    val actionColor = if (actualEnabled) {
        MiuixTheme.colorScheme.onSurfaceVariantActions
    } else {
        MiuixTheme.colorScheme.disabledOnSecondaryVariant
    }

    val setExpanded: (Boolean) -> Unit = remember {
        { expanded ->
            if (isDropdownExpanded.value != expanded) {
                isDropdownExpanded.value = expanded
            }
        }
    }
    val handleClick = remember(actualEnabled) {
        {
            if (actualEnabled) {
                setExpanded(!isDropdownExpanded.value)
                if (isDropdownExpanded.value) {
                    isHoldDown.value = true
                    currentHapticFeedback.performHapticFeedback(HapticFeedbackType.ContextClick)
                }
            }
        }
    }

    BasicComponent(
        modifier = modifier,
        interactionSource = interactionSource,
        insideMargin = BasicComponentDefaults.InsideMargin,
        title = title,
        endActions = {
            preview?.invoke()
            Text(
                text = value,
                modifier = Modifier
                    .padding(start = if (preview == null) 0.dp else 8.dp, end = 8.dp)
                    .align(Alignment.CenterVertically)
                    .weight(1f, fill = false),
                fontSize = MiuixTheme.textStyles.body2.fontSize,
                color = actionColor,
                textAlign = TextAlign.End,
            )
            DropdownArrowEndAction(actionColor = actionColor)
            if (itemsNotEmpty) {
                OverlayDropdownPopup(
                    entry,
                    isDropdownExpanded.value,
                    { setExpanded(false) },
                    { isHoldDown.value = false },
                    null,
                    DropdownDefaults.dropdownColors(),
                    true,
                    true,
                )
            }
        },
        onClick = handleClick,
        role = Role.DropdownList,
        holdDownState = isHoldDown.value,
        enabled = actualEnabled,
    )
}

@Composable
private fun BoxThemeColorDots(
    modifier: Modifier = Modifier,
    seedColor: Color,
    useDynamicColor: Boolean,
    style: PaletteStyle,
    colorSpec: ThemeColorSpec,
    isDark: Boolean,
) {
    val keyColor = if (useDynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        colorResource(id = android.R.color.system_accent1_500)
    } else {
        seedColor
    }
    val activeSpec = colorSpec.boxActiveSpec(style)
    val scheme = remember(keyColor, isDark, style, activeSpec) {
        dynamicColorScheme(
            keyColor = keyColor,
            isDark = isDark,
            style = style,
            colorSpec = activeSpec,
        )
    }
    val colors = remember(scheme) {
        listOf(
            scheme.primary,
            scheme.tertiaryContainer,
            scheme.secondaryContainer,
        )
    }

    Row(
        modifier = modifier.width(42.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        colors.forEach { color ->
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(RoundedCornerShape(5.dp))
                    .background(color)
            )
        }
    }
}

@Composable
private fun rememberThemeIsDark(themeMode: ThemeMode): Boolean {
    val systemDark = isSystemInDarkTheme()
    return remember(themeMode, systemDark) {
        when (themeMode) {
            ThemeMode.LIGHT -> false
            ThemeMode.DARK -> true
            ThemeMode.SYSTEM -> systemDark
        }
    }
}

private fun ThemeColorSpec.boxActiveSpec(style: PaletteStyle): ThemeColorSpec =
    if (this == ThemeColorSpec.SPEC_2025 && !style.supportsSpec2025) {
        ThemeColorSpec.SPEC_2021
    } else {
        this
    }

/**
 * WindowSpinnerPreference widget for selecting Predictive Back Animation
 */
@Composable
private fun MiuixPredictiveBackAnimationWidget(
    modifier: Modifier = Modifier,
    currentAnimation: PredictiveBackAnimation,
    onAnimationChange: (PredictiveBackAnimation) -> Unit
) {
    val options = remember { PredictiveBackAnimation.entries }

    // Map entries to their string resources within the Composable context
    val spinnerEntries = options.map { anim ->
        val title = when (anim) {
            PredictiveBackAnimation.None -> stringResource(R.string.theme_settings_predictive_back_animation_none)
            PredictiveBackAnimation.AOSP -> stringResource(R.string.theme_settings_predictive_back_animation_aosp)
            PredictiveBackAnimation.MIUIX -> stringResource(R.string.theme_settings_predictive_back_animation_miuix)
            PredictiveBackAnimation.Scale -> stringResource(R.string.theme_settings_predictive_back_animation_scale)
            PredictiveBackAnimation.Classic -> stringResource(R.string.theme_settings_predictive_back_animation_ksu_classic)
        }
        DropdownItem(title = title)
    }

    val selectedIndex = remember(currentAnimation, options) {
        options.indexOf(currentAnimation).coerceAtLeast(0)
    }

    WindowSpinnerPreference(
        modifier = modifier,
        title = stringResource(id = R.string.theme_settings_predictive_back_animation),
        items = spinnerEntries,
        selectedIndex = selectedIndex,
        onSelectedIndexChange = { newIndex ->
            val newAnim = options[newIndex]
            if (currentAnimation != newAnim) {
                onAnimationChange(newAnim)
            }
        }
    )
}

/**
 * WindowSpinnerPreference widget for selecting Predictive Back Exit Direction
 */
@Composable
private fun MiuixPredictiveBackExitDirectionWidget(
    modifier: Modifier = Modifier,
    currentDirection: PredictiveBackExitDirection,
    onDirectionChange: (PredictiveBackExitDirection) -> Unit
) {
    val options = remember { PredictiveBackExitDirection.entries }

    // Map entries to their string resources within the Composable context
    val spinnerEntries = options.map { dir ->
        val title = when (dir) {
            PredictiveBackExitDirection.FOLLOW_GESTURE -> stringResource(R.string.theme_settings_predictive_back_exit_direction_follow_gesture)
            PredictiveBackExitDirection.ALWAYS_RIGHT -> stringResource(R.string.theme_settings_predictive_back_exit_direction_always_right)
            PredictiveBackExitDirection.ALWAYS_LEFT -> stringResource(R.string.theme_settings_predictive_back_exit_direction_always_left)
        }
        DropdownItem(title = title)
    }

    val selectedIndex = remember(currentDirection, options) {
        options.indexOf(currentDirection).coerceAtLeast(0)
    }

    WindowSpinnerPreference(
        modifier = modifier,
        title = stringResource(id = R.string.theme_settings_predictive_back_exit_direction),
        items = spinnerEntries,
        selectedIndex = selectedIndex,
        onSelectedIndexChange = { newIndex ->
            val newDir = options[newIndex]
            if (currentDirection != newDir) {
                onDirectionChange(newDir)
            }
        }
    )
}

/**
 * Theme Engine selection widget using WindowSpinnerPreference, following the provided pattern.
 * Simplified version without data class and icons.
 *
 * @param currentThemeIsMiuix True if MIUIX theme is selected, false if Google theme is selected.
 * @param onThemeChange Callback when the selection changes. Boolean parameter indicates new selection (true = MIUIX).
 */
@SuppressLint("LocalContextGetResourceValueCall")
@Composable
private fun MiuixThemeEngineWidget(
    modifier: Modifier = Modifier,
    currentThemeIsMiuix: Boolean,
    onThemeChange: (Boolean) -> Unit,
) {
    val context = LocalContext.current

    val themeOptions = remember {
        mapOf(
            true to R.string.theme_settings_miuix_ui, // Key = true -> MIUIX UI string resource
            false to R.string.theme_settings_google_ui // Key = false -> Google UI string resource
        )
    }

    // Convert map entries to List<DropdownItem> for WindowSpinnerPreference.
    // Ensure the order matches the keys: index 0 = true, index 1 = false.
    val spinnerEntries = remember(themeOptions) {
        themeOptions.entries.sortedByDescending { it.key }.map { entry ->
            DropdownItem(
                title = context.getString(entry.value)
            )
        }
    }

    // Determine selected index based on currentThemeIsMiuix state.
    // Index 0 corresponds to true (MIUIX), Index 1 corresponds to false (Google).
    val selectedIndex = remember(currentThemeIsMiuix) {
        if (currentThemeIsMiuix) 0 else 1
    }

    WindowSpinnerPreference(
        modifier = modifier,
        title = stringResource(id = R.string.theme_settings_ui_engine),
        // summary = spinnerEntries[selectedIndex].title,
        items = spinnerEntries,
        selectedIndex = selectedIndex,
        onSelectedIndexChange = { newIndex ->
            // Convert index back to boolean key (0 -> true, 1 -> false)
            val newModeIsMiuix = themeOptions.keys.sortedDescending().elementAt(newIndex)
            if (currentThemeIsMiuix != newModeIsMiuix) {
                onThemeChange(newModeIsMiuix)
            }
        }
    )
}

/**
 * A WindowSpinnerPreference widget for selecting the application's theme mode (Light, Dark, or System).
 *
 * @param modifier The modifier to be applied to the WindowSpinnerPreference.
 * @param currentThemeMode The currently selected ThemeMode.
 * @param onThemeModeChange A callback that is invoked when the theme mode selection changes.
 */
@SuppressLint("LocalContextGetResourceValueCall")
@Composable
fun MiuixThemeModeWidget(
    modifier: Modifier = Modifier,
    currentThemeMode: ThemeMode,
    onThemeModeChange: (ThemeMode) -> Unit,
) {
    val context = LocalContext.current

    // Map of ThemeMode enum to its corresponding string resource ID.
    val themeModeOptions = remember {
        // The order in the map definition determines the order in the spinner.
        mapOf(
            ThemeMode.LIGHT to R.string.theme_settings_theme_mode_light,
            ThemeMode.DARK to R.string.theme_settings_theme_mode_dark,
            ThemeMode.SYSTEM to R.string.theme_settings_theme_mode_system
        )
    }

    // Convert the map of options to a list of DropdownItem for the WindowSpinnerPreference component.
    // The order of items in the list is important for index mapping.
    val spinnerEntries = remember(themeModeOptions) {
        themeModeOptions.entries.map { entry ->
            DropdownItem(title = context.getString(entry.value))
        }
    }

    // Calculate the selected index based on the current theme mode.
    // It finds the index of the currentThemeMode in the ordered list of keys.
    val selectedIndex = remember(currentThemeMode, themeModeOptions) {
        themeModeOptions.keys.indexOf(currentThemeMode).coerceAtLeast(0)
    }

    WindowSpinnerPreference(
        modifier = modifier,
        title = stringResource(id = R.string.theme_settings_theme_mode),
        items = spinnerEntries,
        selectedIndex = selectedIndex,
        onSelectedIndexChange = { newIndex ->
            // Retrieve the new ThemeMode based on the selected index.
            val newMode = themeModeOptions.keys.elementAt(newIndex)
            // Invoke the callback only if the mode has actually changed.
            if (currentThemeMode != newMode) {
                onThemeModeChange(newMode)
            }
        }
    )
}

/**
 * WindowSpinnerPreference widget for selecting the Palette Style.
 */
@Composable
fun MiuixPaletteStyleWidget(
    modifier: Modifier = Modifier,
    currentPaletteStyle: PaletteStyle,
    currentColor: Color,
    useDynamicColor: Boolean,
    currentColorSpec: ThemeColorSpec,
    themeMode: ThemeMode,
    onPaletteStyleChange: (PaletteStyle) -> Unit
) {
    val options = remember { PaletteStyle.entries }
    val selectedIndex = remember(currentPaletteStyle, options) {
        options.indexOf(currentPaletteStyle).coerceAtLeast(0)
    }
    val isDark = rememberThemeIsDark(themeMode)
    val entries = options.mapIndexed { index, style ->
        DropdownItem(
            text = style.displayName,
            selected = index == selectedIndex,
            onClick = {
                if (currentPaletteStyle != style) {
                    onPaletteStyleChange(style)
                }
            },
            icon = { modifier ->
                BoxThemeColorDots(
                    modifier = modifier.width(42.dp),
                    seedColor = currentColor,
                    useDynamicColor = useDynamicColor,
                    style = style,
                    colorSpec = currentColorSpec,
                    isDark = isDark
                )
            }
        )
    }

    BoxPreviewDropdownPreference(
        modifier = modifier,
        title = stringResource(id = R.string.settings_color_style),
        value = currentPaletteStyle.displayName,
        entry = DropdownEntry(entries),
        preview = {
            BoxThemeColorDots(
                seedColor = currentColor,
                useDynamicColor = useDynamicColor,
                style = currentPaletteStyle,
                colorSpec = currentColorSpec,
                isDark = isDark
            )
        }
    )
}

/**
 * WindowSpinnerPreference widget for selecting the Theme Color Spec.
 * Includes fallback logic to gracefully handle styles that do not support SPEC_2025.
 */
@Composable
fun MiuixColorSpecWidget(
    modifier: Modifier = Modifier,
    currentColorSpec: ThemeColorSpec,
    currentPaletteStyle: PaletteStyle,
    onColorSpecChange: (ThemeColorSpec) -> Unit
) {
    val options = remember { ThemeColorSpec.entries }
    val selectedIndex = remember(currentColorSpec, options) {
        options.indexOf(currentColorSpec).coerceAtLeast(0)
    }
    val entries = options.mapIndexed { index, spec ->
        DropdownItem(
            text = spec.displayName,
            selected = index == selectedIndex,
            onClick = {
                if (currentColorSpec != spec) {
                    onColorSpecChange(spec)
                }
            }
        )
    }

    BoxPreviewDropdownPreference(
        modifier = modifier,
        title = stringResource(id = R.string.settings_color_spec),
        value = currentColorSpec.displayName,
        entry = DropdownEntry(entries),
    )
}
