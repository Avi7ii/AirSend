// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.animation.predictiveback

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.scene.Scene
import androidx.navigation3.ui.defaultPredictivePopTransitionSpec
import androidx.navigationevent.NavigationEventTransitionState

class MiuixPredictiveBackAnimation : PredictiveBackAnimationHandler {

    override suspend fun onBackPressed(
        transitionState: NavigationEventTransitionState?,
        currentPageKey: NavKey?
    ) {
        // Deliberately empty. Predictive back gesture progress is natively handled
        // and synchronized by the Compose transition engine.
    }

    @Composable
    override fun Modifier.predictiveBackAnimationDecorator(
        transitionState: NavigationEventTransitionState?,
        contentPageKey: Any,
        currentPageKey: NavKey?,
    ): Modifier {
        // NavDisplay automatically handles dimming and corner clipping internally
        // through NavDisplayTransitionEffects, so we return unmodified this.
        return this
    }

    override fun AnimatedContentTransitionScope<Scene<NavKey>>.onPredictivePopTransitionSpec(
        swipeEdge: Int
    ): ContentTransform = defaultPredictivePopTransitionSpec<NavKey>().invoke(this, swipeEdge)

    override fun AnimatedContentTransitionScope<Scene<NavKey>>.onPopTransitionSpec(): ContentTransform =
        ContentTransform(
            targetContentEnter = slideInHorizontally(
                animationSpec = tween(240, easing = FastOutSlowInEasing),
                initialOffsetX = { -it / 12 }
            ) + fadeIn(animationSpec = tween(180)),
            initialContentExit = slideOutHorizontally(
                animationSpec = tween(240, easing = FastOutSlowInEasing),
                targetOffsetX = { it / 24 }
            ) + fadeOut(animationSpec = tween(140)),
            sizeTransform = null
        )

    override fun AnimatedContentTransitionScope<Scene<NavKey>>.onTransitionSpec(): ContentTransform =
        ContentTransform(
            targetContentEnter = slideInHorizontally(
                animationSpec = tween(240, easing = FastOutSlowInEasing),
                initialOffsetX = { it / 12 }
            ) + fadeIn(animationSpec = tween(180)),
            initialContentExit = slideOutHorizontally(
                animationSpec = tween(240, easing = FastOutSlowInEasing),
                targetOffsetX = { -it / 24 }
            ) + fadeOut(animationSpec = tween(140)),
            sizeTransform = null
        )
}
