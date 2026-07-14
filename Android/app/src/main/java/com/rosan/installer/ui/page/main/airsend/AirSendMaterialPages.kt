// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)

package com.rosan.installer.ui.page.main.airsend

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.plus
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rosan.installer.R
import com.rosan.installer.ui.icons.AppIcons
import com.rosan.installer.ui.library.FloatingBottomBar
import com.rosan.installer.ui.library.FloatingBottomBarDefaults
import com.rosan.installer.ui.library.FloatingBottomBarItem
import com.rosan.installer.ui.library.FloatingBottomBarMode
import com.rosan.installer.ui.navigation.LocalNavigator
import com.rosan.installer.ui.navigation.Navigator
import com.rosan.installer.ui.navigation.Route
import com.rosan.installer.ui.page.airsend.AirSendActivityLayout
import com.rosan.installer.ui.page.airsend.AirSendContentIcon
import com.rosan.installer.ui.page.airsend.AirSendContentId
import com.rosan.installer.ui.page.airsend.AirSendContentItem
import com.rosan.installer.ui.page.airsend.AirSendNavigationTarget
import com.rosan.installer.ui.page.airsend.AirSendPageContent
import com.rosan.installer.ui.page.airsend.AirSendSection
import com.rosan.installer.ui.page.airsend.AirSendStatusPlacement
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeAction
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeEvent
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeState
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeViewModel
import com.rosan.installer.ui.page.main.widget.card.AnimatedFluidBackground
import com.rosan.installer.ui.page.main.widget.setting.BaseWidget
import com.rosan.installer.ui.page.main.widget.setting.NavigationItemWidget
import com.rosan.installer.ui.page.main.widget.setting.SegmentedColumn
import com.rosan.installer.ui.page.main.widget.setting.SwitchWidget
import com.rosan.installer.ui.theme.getMaterial3AppBarColor
import com.rosan.installer.ui.theme.installerMaterial3BlurEffect
import com.rosan.installer.ui.theme.rememberMaterial3BlurBackdrop
import top.yukonga.miuix.kmp.blur.layerBackdrop
import top.yukonga.miuix.kmp.blur.rememberLayerBackdrop
import kotlinx.coroutines.launch
import org.koin.androidx.compose.koinViewModel

@Composable
fun AirSendHomePage(
    useBlur: Boolean,
    title: String,
    outerPadding: PaddingValues
) {
    val navigator = LocalNavigator.current
    val viewModel: AirSendRuntimeViewModel = koinViewModel()
    val runtimeState by viewModel.state.collectAsStateWithLifecycle()
    AirSendRuntimeEvents(viewModel)

    AirSendMaterialPage(
        useBlur = useBlur,
        title = title,
        outerPadding = outerPadding
    ) {
        if (AirSendPageContent.home.statusPlacement == AirSendStatusPlacement.TopCard) {
            item {
                AirSendStatusCard(useBlur = useBlur, runtimeState = runtimeState)
            }
        }
        airSendMaterialSections(AirSendPageContent.home.sections, navigator, runtimeState, viewModel::dispatch)
    }
}

@Composable
fun AirSendDevicesPage(
    useBlur: Boolean,
    title: String,
    outerPadding: PaddingValues
) {
    val viewModel: AirSendRuntimeViewModel = koinViewModel()
    val runtimeState by viewModel.state.collectAsStateWithLifecycle()
    AirSendRuntimeEvents(viewModel)

    AirSendMaterialPage(
        useBlur = useBlur,
        title = title,
        outerPadding = outerPadding
    ) {
        airSendMaterialDevices(runtimeState, viewModel::dispatch)
    }
}

@Composable
fun AirSendActivityPage(
    useBlur: Boolean,
    title: String,
    outerPadding: PaddingValues
) {
    val viewModel: AirSendRuntimeViewModel = koinViewModel()
    val runtimeState by viewModel.state.collectAsStateWithLifecycle()
    AirSendRuntimeEvents(viewModel)
    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isNotEmpty()) {
            viewModel.dispatch(AirSendRuntimeAction.SendFiles(uris))
        }
    }
    val pagerState = rememberPagerState(initialPage = 0, pageCount = { 2 })
    val coroutineScope = rememberCoroutineScope()
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val backdrop = rememberMaterial3BlurBackdrop(useBlur)
    val navigator = LocalNavigator.current

    LaunchedEffect(pagerState.currentPage) {
        selectedTab = pagerState.currentPage
    }

    Scaffold(
        modifier = Modifier
            .nestedScroll(scrollBehavior.nestedScrollConnection)
            .fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
        topBar = {
            LargeFlexibleTopAppBar(
                modifier = Modifier.installerMaterial3BlurEffect(backdrop),
                title = {
                    Text(
                        text = title,
                        modifier = Modifier.padding(start = 12.dp)
                    )
                },
                scrollBehavior = scrollBehavior,
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = backdrop.getMaterial3AppBarColor(),
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                    scrolledContainerColor = backdrop.getMaterial3AppBarColor()
                )
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .then(backdrop?.let { Modifier.layerBackdrop(it) } ?: Modifier)
                .padding(top = paddingValues.calculateTopPadding())
        ) {
            AirSendActivityTabBar(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                selectedIndex = selectedTab,
                onSelected = { page ->
                    selectedTab = page
                    coroutineScope.launch {
                        pagerState.animateScrollToPage(page)
                    }
                },
                useBlur = useBlur
            )

            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize()
            ) { page ->
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = 16.dp,
                        top = 4.dp,
                        end = 16.dp,
                        bottom = paddingValues.calculateBottomPadding() + outerPadding.calculateBottomPadding() + 16.dp
                    ),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    val activityLayout = if (page == 0) {
                        AirSendPageContent.activitySend
                    } else {
                        AirSendPageContent.activityReceive
                    }
                    airSendMaterialActivity(
                        layout = activityLayout,
                        selectedTab = page,
                        navigator = navigator,
                        runtimeState = runtimeState,
                        onAction = viewModel::dispatch,
                        onPickFiles = { filePicker.launch(arrayOf("*/*")) }
                    )
                }
            }
        }
    }
}

@Composable
fun AirSendSettingsPage(
    useBlur: Boolean,
    title: String,
    outerPadding: PaddingValues
) {
    val navigator = LocalNavigator.current
    val viewModel: AirSendRuntimeViewModel = koinViewModel()
    val runtimeState by viewModel.state.collectAsStateWithLifecycle()
    AirSendRuntimeEvents(viewModel)

    AirSendMaterialPage(
        useBlur = useBlur,
        title = title,
        outerPadding = outerPadding
    ) {
        airSendMaterialSections(AirSendPageContent.settings.sections, navigator, runtimeState, viewModel::dispatch)
    }
}

@Composable
private fun AirSendMaterialPage(
    useBlur: Boolean,
    title: String,
    outerPadding: PaddingValues,
    content: LazyListScope.() -> Unit
) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val backdrop = rememberMaterial3BlurBackdrop(useBlur)

    Scaffold(
        modifier = Modifier
            .nestedScroll(scrollBehavior.nestedScrollConnection)
            .fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
        topBar = {
            LargeFlexibleTopAppBar(
                modifier = Modifier.installerMaterial3BlurEffect(backdrop),
                title = {
                    Text(
                        text = title,
                        modifier = Modifier.padding(start = 12.dp)
                    )
                },
                scrollBehavior = scrollBehavior,
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = backdrop.getMaterial3AppBarColor(),
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                    scrolledContainerColor = backdrop.getMaterial3AppBarColor()
                )
            )
        }
    ) { paddingValues ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .then(backdrop?.let { Modifier.layerBackdrop(it) } ?: Modifier),
            contentPadding = PaddingValues(16.dp) + paddingValues + outerPadding,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = content
        )
    }
}

@Composable
private fun AirSendStatusCard(useBlur: Boolean, runtimeState: AirSendRuntimeState) {
    val containerColor = MaterialTheme.colorScheme.primaryContainer
    val contentColor = MaterialTheme.colorScheme.onPrimaryContainer
    val healthy = runtimeState.backgroundServiceRunning && runtimeState.daemonReachable

    ElevatedCard(
        colors = CardDefaults.cardColors(
            containerColor = if (useBlur) containerColor.copy(alpha = 0.15f) else containerColor,
            contentColor = contentColor
        ),
        elevation = if (useBlur) {
            CardDefaults.elevatedCardElevation(
                defaultElevation = 0.dp,
                pressedElevation = 0.dp,
                focusedElevation = 0.dp,
                hoveredElevation = 0.dp,
                draggedElevation = 0.dp
            )
        } else {
            CardDefaults.elevatedCardElevation()
        }
    ) {
        Box(modifier = Modifier.fillMaxWidth()) {
            AnimatedFluidBackground(
                baseColor = containerColor,
                enabled = useBlur,
                modifier = Modifier.matchParentSize()
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = AppIcons.Active,
                    contentDescription = null,
                    tint = contentColor,
                    modifier = Modifier
                        .size(28.dp)
                        .padding(horizontal = 4.dp)
                )

                Column(
                    modifier = Modifier.padding(start = 20.dp)
                ) {
                    Text(
                        text = stringResource(
                            if (healthy) R.string.airsend_status_running else R.string.airsend_status_attention
                        ),
                        style = MaterialTheme.typography.titleMediumEmphasized,
                        color = contentColor,
                    )
                    Text(
                        text = if (healthy) {
                            stringResource(R.string.airsend_status_running_desc, runtimeState.peers.size)
                        } else {
                            stringResource(R.string.airsend_status_attention_desc)
                        },
                        style = MaterialTheme.typography.bodySmallEmphasized,
                        color = contentColor,
                    )
                }
            }
        }
    }
}

private fun LazyListScope.airSendMaterialSections(
    sections: List<AirSendSection>,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: (() -> Unit)? = null
) {
    sections.forEach { section ->
        item(key = section.id) {
            AirSendMaterialSection(section, navigator, runtimeState, onAction, onPickFiles)
        }
    }
}

private fun LazyListScope.airSendMaterialActivity(
    layout: AirSendActivityLayout,
    selectedTab: Int,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: () -> Unit
) {
    item(key = "activity-empty-$selectedTab") {
        AirSendActivityEmptyCard(
            icon = layout.emptyIcon.asMaterialIcon(),
            iconColor = MaterialTheme.colorScheme.primary,
            title = stringResource(layout.emptyTitleRes),
            description = stringResource(layout.emptyDescriptionRes)
        )
    }
    airSendMaterialSections(layout.sections, navigator, runtimeState, onAction, onPickFiles)
}

private fun LazyListScope.airSendMaterialDevices(
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit
) {
    item(key = "airsend-online-devices") {
        SegmentedColumn(
            title = stringResource(R.string.airsend_online_devices),
            contentPadding = PaddingValues(top = 4.dp, bottom = 8.dp)
        ) {
            if (runtimeState.peers.isEmpty()) {
                item(key = "airsend-no-peers") {
                    BaseWidget(
                        icon = AppIcons.Android,
                        title = stringResource(R.string.airsend_no_devices),
                        description = airSendNoDeviceDescription(runtimeState)
                    )
                }
            } else {
                runtimeState.peers.forEach { peer ->
                    item(key = peer.id) {
                        BaseWidget(
                            icon = AppIcons.Android,
                            title = peer.alias,
                            description = peer.deviceModel,
                            selected = true
                        )
                    }
                }
            }
            item(key = "airsend-refresh-peers") {
                BaseWidget(
                    icon = AppIcons.Search,
                    title = stringResource(R.string.airsend_discover_again),
                    description = stringResource(R.string.airsend_discover_again_desc),
                    onClick = { onAction(AirSendRuntimeAction.Refresh) }
                )
            }
        }
    }
}

@Composable
private fun AirSendMaterialSection(
    section: AirSendSection,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: (() -> Unit)?
) {
    SegmentedColumn(
        title = stringResource(section.titleRes),
        contentPadding = PaddingValues(top = 4.dp, bottom = 8.dp)
    ) {
        section.items.forEach { contentItem ->
            item(key = contentItem.id) {
                AirSendMaterialContentItem(contentItem, navigator, runtimeState, onAction, onPickFiles)
            }
        }
    }
}

@Composable
private fun AirSendMaterialContentItem(
    item: AirSendContentItem,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: (() -> Unit)?
) {
    val title = stringResource(item.titleRes)
    val description = airSendMaterialDescription(item, runtimeState)
    val icon = item.icon.asMaterialIcon()
    val target = item.navigationTarget

    when {
        item.id == AirSendContentId.Startup -> {
            SwitchWidget(
                icon = icon,
                title = title,
                description = description,
                checked = runtimeState.bootStartEnabled,
                onCheckedChange = { onAction(AirSendRuntimeAction.SetBootStartEnabled(it)) }
            )
        }
        item.id == AirSendContentId.RestartService -> {
            BaseWidget(
                icon = icon,
                title = title,
                description = description,
                onClick = { onAction(AirSendRuntimeAction.RestartService) }
            )
        }
        item.id == AirSendContentId.RestartWholeService -> {
            BaseWidget(
                icon = icon,
                title = title,
                description = description,
                onClick = { onAction(AirSendRuntimeAction.RestartWholeService) }
            )
        }
        item.id == AirSendContentId.ServiceNotification -> {
            SwitchWidget(
                icon = icon,
                title = title,
                description = description,
                enabled = runtimeState.canDisableServiceNotification,
                checked = runtimeState.serviceNotificationEnabled,
                onCheckedChange = {
                    onAction(AirSendRuntimeAction.SetServiceNotificationEnabled(it))
                }
            )
        }
        item.id == AirSendContentId.ClipboardSync || item.id == AirSendContentId.ScreenshotSync -> {
            SwitchWidget(
                icon = icon,
                title = title,
                description = description,
                checked = if (item.id == AirSendContentId.ClipboardSync) {
                    runtimeState.clipboardSyncEnabled
                } else {
                    runtimeState.screenshotSyncEnabled
                },
                enabled = runtimeState.daemonReachable,
                onCheckedChange = { enabled ->
                    onAction(
                        if (item.id == AirSendContentId.ClipboardSync) {
                            AirSendRuntimeAction.SetClipboardSyncEnabled(enabled)
                        } else {
                            AirSendRuntimeAction.SetScreenshotSyncEnabled(enabled)
                        }
                    )
                }
            )
        }
        item.id == AirSendContentId.DiscoverAgain || item.id == AirSendContentId.NetworkDiscovery -> {
            BaseWidget(
                icon = icon,
                title = title,
                description = description,
                selected = runtimeState.daemonReachable,
                onClick = { onAction(AirSendRuntimeAction.Refresh) }
            )
        }
        item.id == AirSendContentId.SelectedFiles -> {
            BaseWidget(
                icon = icon,
                title = stringResource(R.string.airsend_pick_files),
                description = description,
                enabled = runtimeState.daemonReachable,
                onClick = onPickFiles
            )
        }
        item.id == AirSendContentId.SendClipboard || item.id == AirSendContentId.ClipboardPush -> {
            BaseWidget(
                icon = icon,
                title = title,
                description = description,
                enabled = runtimeState.daemonReachable,
                onClick = { onAction(AirSendRuntimeAction.SendClipboardText()) }
            )
        }
        item.id == AirSendContentId.LspModule -> {
            NavigationItemWidget(
                icon = icon,
                title = title,
                description = description,
                onClick = { navigator.push(Route.Priv) }
            )
        }
        item.id == AirSendContentId.OpenPermissions -> {
            NavigationItemWidget(
                icon = icon,
                title = title,
                description = description,
                onClick = { navigator.push(Route.Priv) }
            )
        }
        item.id == AirSendContentId.ExportLogs -> {
            NavigationItemWidget(
                icon = icon,
                title = title,
                description = description,
                onClick = { navigator.push(Route.About) }
            )
        }
        target != null -> {
        NavigationItemWidget(
            icon = icon,
            title = title,
            description = description,
            onClick = { navigator.push(target.asRoute()) }
        )
        }
        item.id in airSendUnavailableActions -> {
            BaseWidget(
                icon = icon,
                title = title,
                description = stringResource(R.string.airsend_runtime_unavailable),
                enabled = false
            )
        }
        else -> {
            BaseWidget(
                icon = icon,
                title = title,
                description = description,
                selected = item.selected || item.id.isSelectedBy(runtimeState)
            )
        }
    }
}

@Composable
private fun AirSendRuntimeEvents(viewModel: AirSendRuntimeViewModel) {
    val context = LocalContext.current
    val resources = LocalResources.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            val message = when (event) {
                is AirSendRuntimeEvent.ShowMessage -> resources.getString(event.messageRes)
                is AirSendRuntimeEvent.ShowRawMessage -> event.message
            }
            Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
        }
    }
}

@Composable
private fun airSendMaterialDescription(
    item: AirSendContentItem,
    runtimeState: AirSendRuntimeState
): String =
    when (item.id) {
        AirSendContentId.BackgroundService -> stringResource(
            if (runtimeState.backgroundServiceRunning) R.string.airsend_state_running else R.string.airsend_state_stopped
        )
        AirSendContentId.Daemon -> if (runtimeState.daemonReachable) {
            stringResource(R.string.airsend_state_reachable)
        } else {
            runtimeState.lastError?.let { stringResource(R.string.airsend_daemon_error, it) }
                ?: stringResource(R.string.airsend_state_unreachable)
        }
        AirSendContentId.PermissionCheck,
        AirSendContentId.OpenPermissions -> {
            val notification = stringResource(
                if (runtimeState.notificationPermissionGranted) {
                    R.string.airsend_permission_granted
                } else {
                    R.string.airsend_permission_denied
                }
            )
            val storage = stringResource(
                if (runtimeState.storagePermissionGranted) {
                    R.string.airsend_permission_granted
                } else {
                    R.string.airsend_permission_denied
                }
            )
            "${stringResource(R.string.notification_settings)}: $notification · ${stringResource(R.string.config_display_size)}: $storage"
        }
        AirSendContentId.NearbyTargets -> stringResource(
            R.string.airsend_peer_count,
            runtimeState.peers.count { it.online }
        )
        AirSendContentId.SavedDevices -> stringResource(R.string.airsend_peer_count, runtimeState.peers.size)
        AirSendContentId.ClipboardSync -> if (runtimeState.daemonReachable) {
            stringResource(item.descriptionRes)
        } else {
            stringResource(R.string.airsend_state_unreachable)
        }
        AirSendContentId.ScreenshotSync -> if (runtimeState.daemonReachable) {
            if (runtimeState.screenshotSyncEnabled) {
                stringResource(R.string.airsend_sync_enabled_desc)
            } else {
                stringResource(R.string.airsend_sync_disabled_desc)
            }
        } else {
            stringResource(R.string.airsend_state_unreachable)
        }
        AirSendContentId.ServiceNotification -> when {
            !runtimeState.canDisableServiceNotification -> stringResource(
                R.string.airsend_service_notification_required_desc
            )
            runtimeState.serviceNotificationEnabled -> stringResource(
                R.string.airsend_service_notification_enabled_desc
            )
            else -> stringResource(R.string.airsend_service_notification_disabled_desc)
        }
        else -> stringResource(item.descriptionRes)
    }

@Composable
private fun airSendNoDeviceDescription(runtimeState: AirSendRuntimeState): String =
    if (!runtimeState.daemonReachable && runtimeState.lastError != null) {
        stringResource(R.string.airsend_daemon_error, runtimeState.lastError)
    } else {
        stringResource(R.string.airsend_no_devices_desc)
    }

private val airSendUnavailableActions = setOf(
    AirSendContentId.AddManual,
    AirSendContentId.PairTrust,
    AirSendContentId.ReceiveRequests,
    AirSendContentId.QuickSave,
    AirSendContentId.SaveLocation,
    AirSendContentId.TrustedDevices
)

private fun AirSendContentId.isSelectedBy(runtimeState: AirSendRuntimeState): Boolean =
    when (this) {
        AirSendContentId.BackgroundService -> runtimeState.backgroundServiceRunning
        AirSendContentId.Daemon -> runtimeState.daemonReachable
        AirSendContentId.ClipboardSync -> runtimeState.daemonReachable
        else -> false
    }

private fun AirSendNavigationTarget.asRoute(): Route =
    when (this) {
        AirSendNavigationTarget.Theme -> Route.Theme
        AirSendNavigationTarget.Permissions -> Route.Priv
        AirSendNavigationTarget.About -> Route.About
    }

@Composable
private fun AirSendContentIcon.asMaterialIcon(): ImageVector =
    when (this) {
        AirSendContentIcon.AirSend -> ImageVector.vectorResource(R.drawable.ic_airsend_monochrome)
        AirSendContentIcon.Active -> AppIcons.Active
        AirSendContentIcon.Lsposed -> AppIcons.LSPosed
        AirSendContentIcon.Terminal -> AppIcons.Terminal
        AirSendContentIcon.Share -> AppIcons.Share
        AirSendContentIcon.History -> AppIcons.History
        AirSendContentIcon.Retry -> AppIcons.Retry
        AirSendContentIcon.Permission -> AppIcons.Permission
        AirSendContentIcon.Android -> AppIcons.Android
        AirSendContentIcon.Search -> AppIcons.Search
        AirSendContentIcon.Add -> AppIcons.Add
        AirSendContentIcon.Save -> AppIcons.Save
        AirSendContentIcon.Download -> AppIcons.Download
        AirSendContentIcon.Theme -> AppIcons.Theme
        AirSendContentIcon.Launcher -> AppIcons.Launcher
        AirSendContentIcon.Security -> AppIcons.DisableAdbVerify
        AirSendContentIcon.BugReport -> AppIcons.BugReport
        AirSendContentIcon.Info -> AppIcons.Info
    }

@Composable
private fun AirSendActivityTabBar(
    modifier: Modifier = Modifier,
    selectedIndex: Int,
    onSelected: (Int) -> Unit,
    useBlur: Boolean
) {
    val tabBackdrop = rememberLayerBackdrop()
    val mode = if (useBlur) FloatingBottomBarMode.Blur else FloatingBottomBarMode.None
    val selectedIndexState = rememberUpdatedState(selectedIndex)
    val selectedIndexProvider = remember {
        { selectedIndexState.value }
    }

    Box(
        modifier = modifier,
        contentAlignment = Alignment.Center
    ) {
        FloatingBottomBar(
            modifier = Modifier,
            selectedIndex = selectedIndexProvider,
            onSelected = onSelected,
            backdrop = tabBackdrop,
            tabsCount = 2,
            mode = mode,
            colors = FloatingBottomBarDefaults.colors(
                containerColor = MaterialTheme.colorScheme.surfaceContainer,
                indicatorColor = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onSurface
            )
        ) {
            FloatingBottomBarItem(
                onClick = { onSelected(0) },
                modifier = Modifier.defaultMinSize(minWidth = 112.dp)
            ) {
                Icon(
                    imageVector = AppIcons.ArrowUp,
                    contentDescription = stringResource(R.string.airsend_activity_send)
                )
                Text(
                    text = stringResource(R.string.airsend_activity_send),
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Visible
                )
            }
            FloatingBottomBarItem(
                onClick = { onSelected(1) },
                modifier = Modifier.defaultMinSize(minWidth = 112.dp)
            ) {
                Icon(
                    imageVector = AppIcons.Download,
                    contentDescription = stringResource(R.string.airsend_activity_receive)
                )
                Text(
                    text = stringResource(R.string.airsend_activity_receive),
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Visible
                )
            }
        }
    }
}

@Composable
private fun AirSendActivityEmptyCard(
    icon: ImageVector,
    iconColor: Color,
    title: String,
    description: String
) {
    ElevatedCard(
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceBright
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconColor,
                modifier = Modifier.size(36.dp)
            )
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = description,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun AirSendActivityMetaGroup(
    firstTitle: String,
    firstDesc: String,
    secondTitle: String,
    secondDesc: String
) {
    SegmentedColumn(contentPadding = PaddingValues(0.dp)) {
        item {
            BaseWidget(
                iconPlaceholder = false,
                title = firstTitle,
                description = firstDesc
            )
        }
        item {
            BaseWidget(
                iconPlaceholder = false,
                title = secondTitle,
                description = secondDesc
            )
        }
    }
    Spacer(modifier = Modifier.height(4.dp))
}
