// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.domain.device.provider

interface AppInfoProvider {
    /**
     * Retrieves the application label for a given package name.
     *
     * @param packageName The package name to query.
     * @return The application label if found, or null otherwise.
     */
    suspend fun getAppLabel(packageName: String): String?
}
