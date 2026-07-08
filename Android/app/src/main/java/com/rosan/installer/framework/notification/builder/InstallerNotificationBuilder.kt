// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2025-2026 InstallerX Revived contributors
package com.rosan.installer.framework.notification.builder

import android.app.Notification

/**
 * Strategy interface for all installer notification builders.
 */
interface InstallerNotificationBuilder {
    /**
     * Builds the notification based on the provided layered payload.
     *
     * @param payload The consistent snapshot of the current state, settings, and animation context.
     * @return The constructed Notification, or null if no notification should be shown for this state.
     */
    suspend fun build(payload: NotificationPayload): Notification?
}
