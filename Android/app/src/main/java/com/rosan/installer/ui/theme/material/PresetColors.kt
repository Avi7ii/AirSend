// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2025-2026 InstallerX Revived contributors
package com.rosan.installer.ui.theme.material

import androidx.compose.ui.graphics.Color

data class RawColor(val key: String, val color: Color)

val PresetColors = listOf(
    RawColor("red", Color(0xFFF44336)),
    RawColor("pink", Color(0xFFE91E63)),
    RawColor("purple", Color(0xFF9C27B0)),
    RawColor("deep_purple", Color(0xFF673AB7)),
    RawColor("indigo", Color(0xFF3F51B5)),
    RawColor("blue", Color(0xFF2196F3)),
    RawColor("cyan", Color(0xFF00BCD4)),
    RawColor("teal", Color(0xFF009688)),
    RawColor("green", Color(0xFF4FAF50)),
    RawColor("yellow", Color(0xFFFFEB3B)),
    RawColor("amber", Color(0xFFFFC107)),
    RawColor("orange", Color(0xFFFF9800)),
    RawColor("brown", Color(0xFF795548)),
    RawColor("blue_grey", Color(0xFF607D8F)),
    RawColor("sakura", Color(0xFFFF9CA8))
)
