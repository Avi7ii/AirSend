// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2023-2026 iamr0s, InstallerX Revived contributors
package com.rosan.installer.ui.navigation

import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.vectorResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rosan.installer.R
import com.rosan.installer.domain.settings.model.preferences.ThemeState
import com.rosan.installer.ui.icons.AppIcons
import com.rosan.installer.ui.page.main.settings.Material3SettingsCompactLayout
import com.rosan.installer.ui.page.main.settings.Material3SettingsWideScreenLayout
import com.rosan.installer.ui.page.main.settings.SettingsSharedViewModel
import com.rosan.installer.ui.theme.LocalWindowLayoutInfo
import com.rosan.installer.ui.theme.rememberMaterial3BlurBackdrop

@Immutable
data class NavigationTab(
    val icon: ImageVector,
    val label: String
)

@Composable
fun Material3MainPageWrapper(
    uiState: ThemeState,
    sharedViewModel: SettingsSharedViewModel
) {
    val sharedState by sharedViewModel.state.collectAsStateWithLifecycle()
    val useBlur = uiState.useBlur
    val useFloatingBottomBar = uiState.useAppleFloatingBar
    val backdrop = rememberMaterial3BlurBackdrop(useBlur)

    val homeLabel = stringResource(id = R.string.airsend_nav_home)
    val homeIcon = ImageVector.vectorResource(R.drawable.ic_airsend_monochrome)
    val devicesLabel = stringResource(R.string.airsend_nav_devices)
    val activityLabel = stringResource(R.string.airsend_nav_activity)
    val settingsLabel = stringResource(R.string.airsend_nav_settings)

    val tabs = remember(homeIcon, homeLabel, devicesLabel, activityLabel, settingsLabel) {
        listOf(
            NavigationTab(
                icon = homeIcon,
                label = homeLabel
            ),
            NavigationTab(
                icon = AppIcons.Android,
                label = devicesLabel
            ),
            NavigationTab(
                icon = AppIcons.History,
                label = activityLabel
            ),
            NavigationTab(
                icon = AppIcons.Settings,
                label = settingsLabel
            )
        )
    }

    val pagerState = rememberPagerState(
        initialPage = sharedState.lastMainPageIndex,
        pageCount = { tabs.size }
    )
    val mainPagerState = rememberMainPagerState(pagerState)
    val currentPage = mainPagerState.pagerState.currentPage
    val settledPage = mainPagerState.pagerState.settledPage
    LaunchedEffect(currentPage) {
        mainPagerState.syncPage()
    }
    LaunchedEffect(settledPage) {
        if (sharedState.lastMainPageIndex != settledPage) {
            sharedViewModel.updateLastMainPageIndex(settledPage)
        }
    }
    MainScreenBackHandler(
        mainPagerState = mainPagerState,
        navController = LocalNavigator.current,
    )

    val layoutInfo = LocalWindowLayoutInfo.current
    val showRail = layoutInfo.showNavigationRail
    val isMedium = layoutInfo.isMediumPortrait

    // Branch statically without layout delay traps
    if (showRail) {
        Material3SettingsWideScreenLayout(
            configCount = 0,
            mainPagerState = mainPagerState,
            tabs = tabs,
            useBlur = useBlur,
            useFloatingBottomBar = useFloatingBottomBar,
            backdrop = backdrop
        )
    } else {
        Material3SettingsCompactLayout(
            configCount = 0,
            mainPagerState = mainPagerState,
            tabs = tabs,
            useBlur = useBlur,
            useFloatingBottomBar = useFloatingBottomBar,
            backdrop = backdrop,
            isMedium = isMedium
        )
    }
}
