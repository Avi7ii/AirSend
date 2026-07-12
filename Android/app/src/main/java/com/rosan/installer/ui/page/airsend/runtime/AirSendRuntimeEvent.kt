// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import androidx.annotation.StringRes

sealed interface AirSendRuntimeEvent {
    data class ShowMessage(@StringRes val messageRes: Int) : AirSendRuntimeEvent
    data class ShowRawMessage(val message: String) : AirSendRuntimeEvent
}
