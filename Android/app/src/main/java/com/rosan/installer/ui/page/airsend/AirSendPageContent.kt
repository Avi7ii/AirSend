// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend

import androidx.annotation.StringRes
import com.rosan.installer.R

enum class AirSendStatusPlacement {
    TopCard,
    None
}

enum class AirSendSectionId {
    Health,
    QuickActions,
    Recent,
    CurrentTarget,
    Discovery,
    DeviceCapabilities,
    DeviceTroubleshooting,
    TransferQueue,
    SendOptions,
    ReceiveOptions,
    History,
    Appearance,
    Transfer,
    Receive,
    Network,
    Permissions,
    Diagnostics
}

enum class AirSendContentId {
    BackgroundService,
    LspModule,
    Daemon,
    ClipboardSync,
    ScreenshotSync,
    ServiceNotification,
    HistoryRetention,
    ClipboardPush,
    ReceiveSwitch,
    RestartService,
    RestartWholeService,
    PermissionCheck,
    EmptyRecent,
    NoTarget,
    NoDevices,
    SavedDevices,
    DiscoverAgain,
    AddManual,
    SendClipboard,
    PairTrust,
    SameNetwork,
    SelectedFiles,
    NearbyTargets,
    SentHistory,
    ReceiveRequests,
    QuickSave,
    SaveLocation,
    ReceivedHistory,
    Language,
    Theme,
    Startup,
    NetworkDiscovery,
    TrustedDevices,
    Transport,
    RuntimeDiagnostics,
    OpenPermissions,
    ExportLogs,
    About
}

enum class AirSendContentIcon {
    AirSend,
    Active,
    Lsposed,
    Terminal,
    Share,
    History,
    Retry,
    Permission,
    Android,
    Search,
    Add,
    Save,
    Download,
    Language,
    Theme,
    Launcher,
    Security,
    BugReport,
    Info
}

enum class AirSendNavigationTarget {
    Theme,
    Permissions,
    About
}

data class AirSendPageLayout(
    val statusPlacement: AirSendStatusPlacement = AirSendStatusPlacement.None,
    val sections: List<AirSendSection>
)

data class AirSendActivityLayout(
    @StringRes val emptyTitleRes: Int,
    @StringRes val emptyDescriptionRes: Int,
    val emptyIcon: AirSendContentIcon,
    val sections: List<AirSendSection>
)

data class AirSendSection(
    val id: AirSendSectionId,
    @StringRes val titleRes: Int,
    val items: List<AirSendContentItem>
)

data class AirSendContentItem(
    val id: AirSendContentId,
    val icon: AirSendContentIcon,
    @StringRes val titleRes: Int,
    @StringRes val descriptionRes: Int,
    val selected: Boolean = false,
    val navigationTarget: AirSendNavigationTarget? = null
)

object AirSendPageContent {
    val home = AirSendPageLayout(
        statusPlacement = AirSendStatusPlacement.TopCard,
        sections = listOf(
            section(
                AirSendSectionId.Health,
                R.string.airsend_sync_health,
                item(
                    AirSendContentId.BackgroundService,
                    AirSendContentIcon.Active,
                    R.string.airsend_background_service,
                    R.string.airsend_background_service_desc
                ),
                item(
                    AirSendContentId.LspModule,
                    AirSendContentIcon.Lsposed,
                    R.string.airsend_lsp_module,
                    R.string.airsend_lsp_module_desc
                ),
                item(
                    AirSendContentId.Daemon,
                    AirSendContentIcon.Terminal,
                    R.string.airsend_daemon,
                    R.string.airsend_daemon_desc
                ),
                item(
                    AirSendContentId.ClipboardSync,
                    AirSendContentIcon.Share,
                    R.string.airsend_clipboard_sync,
                    R.string.airsend_clipboard_sync_desc
                ),
                item(
                    AirSendContentId.ScreenshotSync,
                    AirSendContentIcon.Share,
                    R.string.airsend_screenshot_sync,
                    R.string.airsend_screenshot_sync_desc
                )
            ),
            section(
                AirSendSectionId.QuickActions,
                R.string.airsend_quick_actions,
                item(
                    AirSendContentId.RestartService,
                    AirSendContentIcon.Retry,
                    R.string.airsend_restart_service,
                    R.string.airsend_restart_service_desc
                ),
                item(
                    AirSendContentId.RestartWholeService,
                    AirSendContentIcon.Retry,
                    R.string.airsend_restart_whole_service,
                    R.string.airsend_restart_whole_service_desc
                ),
                item(
                    AirSendContentId.PermissionCheck,
                    AirSendContentIcon.Permission,
                    R.string.airsend_permission_check,
                    R.string.airsend_permission_check_desc,
                    navigationTarget = AirSendNavigationTarget.Permissions
                )
            )
        )
    )

    val devices = AirSendPageLayout(
        sections = listOf(
            section(
                AirSendSectionId.CurrentTarget,
                R.string.airsend_current_target,
                item(
                    AirSendContentId.NoTarget,
                    AirSendContentIcon.Android,
                    R.string.airsend_no_target,
                    R.string.airsend_no_target_desc
                )
            ),
            section(
                AirSendSectionId.Discovery,
                R.string.airsend_discovery,
                item(
                    AirSendContentId.NoDevices,
                    AirSendContentIcon.Android,
                    R.string.airsend_no_devices,
                    R.string.airsend_no_devices_desc
                ),
                item(
                    AirSendContentId.SavedDevices,
                    AirSendContentIcon.Save,
                    R.string.airsend_saved_devices,
                    R.string.airsend_saved_devices_desc
                ),
                item(
                    AirSendContentId.DiscoverAgain,
                    AirSendContentIcon.Search,
                    R.string.airsend_discover_again,
                    R.string.airsend_discover_again_desc
                ),
                item(
                    AirSendContentId.AddManual,
                    AirSendContentIcon.Add,
                    R.string.airsend_add_manual,
                    R.string.airsend_add_manual_desc
                )
            ),
            section(
                AirSendSectionId.DeviceTroubleshooting,
                R.string.airsend_device_troubleshooting,
                item(
                    AirSendContentId.SameNetwork,
                    AirSendContentIcon.Info,
                    R.string.airsend_same_network,
                    R.string.airsend_same_network_desc
                )
            )
        )
    )

    val activitySend = AirSendActivityLayout(
        emptyTitleRes = R.string.airsend_empty_sent,
        emptyDescriptionRes = R.string.airsend_empty_sent_desc,
        emptyIcon = AirSendContentIcon.History,
        sections = listOf(
            section(
                AirSendSectionId.TransferQueue,
                R.string.airsend_transfer_queue,
                item(
                    AirSendContentId.SelectedFiles,
                    AirSendContentIcon.Share,
                    R.string.airsend_selected_files,
                    R.string.airsend_selected_files_desc
                ),
                item(
                    AirSendContentId.NearbyTargets,
                    AirSendContentIcon.Android,
                    R.string.airsend_nearby_targets,
                    R.string.airsend_nearby_targets_desc
                )
            ),
            section(
                AirSendSectionId.SendOptions,
                R.string.airsend_send_options,
                item(
                    AirSendContentId.SendClipboard,
                    AirSendContentIcon.Share,
                    R.string.airsend_send_clipboard,
                    R.string.airsend_send_clipboard_desc
                )
            )
        )
    )

    val activityReceive = AirSendActivityLayout(
        emptyTitleRes = R.string.airsend_empty_received,
        emptyDescriptionRes = R.string.airsend_empty_received_desc,
        emptyIcon = AirSendContentIcon.Download,
        sections = listOf(
            section(
                AirSendSectionId.TransferQueue,
                R.string.airsend_transfer_queue,
                item(
                    AirSendContentId.ReceiveRequests,
                    AirSendContentIcon.Download,
                    R.string.airsend_receive_requests,
                    R.string.airsend_receive_requests_desc
                )
            ),
            section(
                AirSendSectionId.ReceiveOptions,
                R.string.airsend_receive_options,
                item(
                    AirSendContentId.QuickSave,
                    AirSendContentIcon.Save,
                    R.string.airsend_quick_save,
                    R.string.airsend_quick_save_desc
                ),
                item(
                    AirSendContentId.SaveLocation,
                    AirSendContentIcon.Save,
                    R.string.airsend_save_location,
                    R.string.airsend_save_location_desc
                )
            )
        )
    )

    val settings = AirSendPageLayout(
        sections = listOf(
            section(
                AirSendSectionId.Appearance,
                R.string.airsend_settings_appearance,
                item(
                    AirSendContentId.Language,
                    AirSendContentIcon.Language,
                    R.string.airsend_language,
                    R.string.airsend_language_desc
                ),
                item(
                    AirSendContentId.Theme,
                    AirSendContentIcon.Theme,
                    R.string.theme_settings,
                    R.string.airsend_theme_desc,
                    navigationTarget = AirSendNavigationTarget.Theme
                )
            ),
            section(
                AirSendSectionId.Transfer,
                R.string.airsend_settings_transfer,
                item(
                    AirSendContentId.Startup,
                    AirSendContentIcon.Launcher,
                    R.string.airsend_startup,
                    R.string.airsend_startup_desc
                ),
                item(
                    AirSendContentId.ClipboardSync,
                    AirSendContentIcon.Share,
                    R.string.airsend_clipboard_sync,
                    R.string.airsend_clipboard_sync_desc
                ),
                item(
                    AirSendContentId.ScreenshotSync,
                    AirSendContentIcon.Share,
                    R.string.airsend_screenshot_sync,
                    R.string.airsend_screenshot_sync_desc
                ),
                item(
                    AirSendContentId.ServiceNotification,
                    AirSendContentIcon.Info,
                    R.string.airsend_service_notification,
                    R.string.airsend_service_notification_desc
                ),
                item(
                    AirSendContentId.HistoryRetention,
                    AirSendContentIcon.History,
                    R.string.airsend_history_limit,
                    R.string.airsend_history_limit_desc
                )
            ),
            section(
                AirSendSectionId.Receive,
                R.string.airsend_settings_receive,
                item(
                    AirSendContentId.ReceiveSwitch,
                    AirSendContentIcon.Download,
                    R.string.airsend_receive_switch,
                    R.string.airsend_receive_switch_desc
                ),
                item(
                    AirSendContentId.QuickSave,
                    AirSendContentIcon.Save,
                    R.string.airsend_quick_save,
                    R.string.airsend_quick_save_desc
                ),
                item(
                    AirSendContentId.SaveLocation,
                    AirSendContentIcon.Save,
                    R.string.airsend_save_location,
                    R.string.airsend_save_location_desc
                )
            ),
            section(
                AirSendSectionId.Network,
                R.string.airsend_settings_network,
                item(
                    AirSendContentId.NetworkDiscovery,
                    AirSendContentIcon.Search,
                    R.string.airsend_network_discovery,
                    R.string.airsend_network_discovery_desc
                ),
                item(
                    AirSendContentId.TrustedDevices,
                    AirSendContentIcon.Security,
                    R.string.airsend_trusted_devices,
                    R.string.airsend_trusted_devices_desc
                ),
                item(
                    AirSendContentId.Transport,
                    AirSendContentIcon.Security,
                    R.string.airsend_transport_preference,
                    R.string.airsend_transport_preference_desc
                )
            ),
            section(
                AirSendSectionId.Permissions,
                R.string.airsend_settings_permissions,
                item(
                    AirSendContentId.OpenPermissions,
                    AirSendContentIcon.Permission,
                    R.string.airsend_open_permissions,
                    R.string.airsend_open_permissions_desc,
                    navigationTarget = AirSendNavigationTarget.Permissions
                )
            ),
            section(
                AirSendSectionId.Diagnostics,
                R.string.airsend_settings_diagnostics,
                item(
                    AirSendContentId.RuntimeDiagnostics,
                    AirSendContentIcon.Info,
                    R.string.airsend_runtime_diagnostics,
                    R.string.airsend_runtime_diagnostics_desc
                ),
                item(
                    AirSendContentId.ExportLogs,
                    AirSendContentIcon.BugReport,
                    R.string.airsend_logs,
                    R.string.airsend_logs_desc
                ),
                item(
                    AirSendContentId.About,
                    AirSendContentIcon.AirSend,
                    R.string.app_name,
                    R.string.about,
                    navigationTarget = AirSendNavigationTarget.About
                )
            )
        )
    )

    private fun section(
        id: AirSendSectionId,
        @StringRes titleRes: Int,
        vararg items: AirSendContentItem
    ) = AirSendSection(id, titleRes, items.toList())

    private fun item(
        id: AirSendContentId,
        icon: AirSendContentIcon,
        @StringRes titleRes: Int,
        @StringRes descriptionRes: Int,
        selected: Boolean = false,
        navigationTarget: AirSendNavigationTarget? = null
    ) = AirSendContentItem(
        id = id,
        icon = icon,
        titleRes = titleRes,
        descriptionRes = descriptionRes,
        selected = selected,
        navigationTarget = navigationTarget
    )
}
