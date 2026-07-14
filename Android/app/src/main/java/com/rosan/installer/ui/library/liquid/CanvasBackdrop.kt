// Copyright 2026, Kyant0/AndroidLiquidGlass contributors
// Copyright 2026, InstallerX Revived contributors
// SPDX-License-Identifier: Apache-2.0

package com.rosan.installer.ui.library.liquid

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.GraphicsLayerScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.unit.Density
import top.yukonga.miuix.kmp.blur.Backdrop

@Composable
fun rememberCanvasBackdrop(onDraw: DrawScope.() -> Unit): Backdrop =
    remember(onDraw) { CanvasBackdrop(onDraw) }

@Immutable
private class CanvasBackdrop(
    val onDraw: DrawScope.() -> Unit
) : Backdrop {
    override val isCoordinatesDependent: Boolean = false

    override fun DrawScope.drawBackdrop(
        density: Density,
        coordinates: LayoutCoordinates?,
        layerBlock: (GraphicsLayerScope.() -> Unit)?,
        downscaleFactor: Int
    ) {
        onDraw()
    }
}
