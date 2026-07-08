// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.animation.predictiveback

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.scene.Scene
import androidx.navigation3.ui.defaultPopTransitionSpec
import androidx.navigation3.ui.defaultTransitionSpec
import androidx.navigationevent.NavigationEventTransitionState
import com.rosan.installer.ui.navigation.LocalNavigator

class NoPredictiveBackAnimation : PredictiveBackAnimationHandler {
    override suspend fun onBackPressed(
        transitionState: NavigationEventTransitionState?,
        currentPageKey: NavKey?
    ) {
        // Ignore predictive back gesture progress completely.
    }

    @Composable
    override fun Modifier.predictiveBackAnimationDecorator(
        transitionState: NavigationEventTransitionState?,
        contentPageKey: Any,
        currentPageKey: NavKey?,
    ): Modifier {
        val navigator = LocalNavigator.current

        // Determine if there are pages to pop.
        val canPop = navigator.backStack.size > 1

        // Only intercept the back button when we can actually pop.
        // If enabled is false, the system handles the back press (e.g., exits the Activity).
        // Using BackHandler here completely intercepts the system predictive back dispatch,
        // preventing the predictive gesture from starting.
        BackHandler(enabled = canPop) {
            navigator.pop()
        }

        return this
    }

    override fun AnimatedContentTransitionScope<Scene<NavKey>>.onPredictivePopTransitionSpec(
        swipeEdge: Int
    ): ContentTransform = ContentTransform(
        // Keep predictive pop transition empty since it's disabled by BackHandler anyway.
        targetContentEnter = EnterTransition.None,
        initialContentExit = ExitTransition.None,
        sizeTransform = null
    )

    override fun AnimatedContentTransitionScope<Scene<NavKey>>.onPopTransitionSpec(): ContentTransform =
        // Sync with the default pop transition used in Miuix implementation
        defaultPopTransitionSpec<NavKey>().invoke(this)

    override fun AnimatedContentTransitionScope<Scene<NavKey>>.onTransitionSpec(): ContentTransform =
        // Sync with the default push transition used in Miuix implementation
        defaultTransitionSpec<NavKey>().invoke(this)
}
