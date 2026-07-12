// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.miuix.airsend

import android.annotation.SuppressLint
import android.widget.Toast
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
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
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalContext
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
import com.rosan.installer.ui.library.FloatingBottomBarItem
import com.rosan.installer.ui.library.FloatingBottomBarMode
import com.rosan.installer.ui.navigation.LocalNavigator
import com.rosan.installer.ui.navigation.Navigator
import com.rosan.installer.ui.navigation.Route
import com.rosan.installer.ui.page.airsend.AirSendActivityLayout
import com.rosan.installer.ui.page.airsend.AirSendContentIcon
import com.rosan.installer.ui.page.airsend.AirSendContentId
import com.rosan.installer.ui.page.airsend.AirSendContentItem
import com.rosan.installer.ui.page.airsend.AirSendDeviceKind
import com.rosan.installer.ui.page.airsend.AirSendNavigationTarget
import com.rosan.installer.ui.page.airsend.AirSendPageContent
import com.rosan.installer.ui.page.airsend.AirSendSection
import com.rosan.installer.ui.page.airsend.AirSendStatusPlacement
import com.rosan.installer.ui.page.airsend.deviceKind
import com.rosan.installer.ui.page.airsend.deviceSubtitle
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeAction
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeEvent
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeState
import com.rosan.installer.ui.page.airsend.runtime.AirSendTransferSnapshot
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeViewModel
import com.rosan.installer.ui.page.miuix.widgets.MiuixSwitchWidget
import com.rosan.installer.ui.page.miuix.widgets.MiuixNavigationItemWidget
import com.rosan.installer.ui.theme.InstallerTheme
import com.rosan.installer.ui.theme.getMiuixAppBarColor
import com.rosan.installer.ui.theme.installerMiuixBlurEffect
import com.rosan.installer.ui.theme.miuixHomeStatusCardColorActivated
import com.rosan.installer.ui.theme.rememberMiuixBlurBackdrop
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.CardDefaults
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.LinearProgressIndicator
import top.yukonga.miuix.kmp.basic.MiuixScrollBehavior
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.blur.layerBackdrop
import top.yukonga.miuix.kmp.blur.rememberLayerBackdrop
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.theme.MiuixTheme.isDynamicColor
import top.yukonga.miuix.kmp.utils.PressFeedbackType
import top.yukonga.miuix.kmp.utils.overScrollVertical
import top.yukonga.miuix.kmp.utils.scrollEndHaptic
import kotlinx.coroutines.launch
import org.koin.androidx.compose.koinViewModel

@Composable
fun MiuixAirSendHomePage(
    enableBlur: Boolean,
    title: String,
    outerPadding: PaddingValues
) {
    val navigator = LocalNavigator.current
    val viewModel: AirSendRuntimeViewModel = koinViewModel()
    val runtimeState by viewModel.state.collectAsStateWithLifecycle()
    MiuixAirSendRuntimeEvents(viewModel)

    MiuixAirSendPage(
        enableBlur = enableBlur,
        title = title,
        outerPadding = outerPadding
    ) {
        if (AirSendPageContent.home.statusPlacement == AirSendStatusPlacement.TopCard) {
            item {
                MiuixAirSendStatusCard(runtimeState)
            }
        }
        airSendMiuixSections(AirSendPageContent.home.sections, navigator, runtimeState, viewModel::dispatch)
    }
}

@Composable
fun MiuixAirSendDevicesPage(
    enableBlur: Boolean,
    title: String,
    outerPadding: PaddingValues
) {
    val viewModel: AirSendRuntimeViewModel = koinViewModel()
    val runtimeState by viewModel.state.collectAsStateWithLifecycle()
    MiuixAirSendRuntimeEvents(viewModel)

    MiuixAirSendPage(
        enableBlur = enableBlur,
        title = title,
        outerPadding = outerPadding
    ) {
        airSendMiuixDevices(runtimeState, viewModel::dispatch)
    }
}

@Composable
fun MiuixAirSendActivityPage(
    enableBlur: Boolean,
    title: String,
    outerPadding: PaddingValues,
    floatingBottomBarMode: FloatingBottomBarMode
) {
    val viewModel: AirSendRuntimeViewModel = koinViewModel()
    val runtimeState by viewModel.state.collectAsStateWithLifecycle()
    MiuixAirSendRuntimeEvents(viewModel)
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
    val scrollBehavior = MiuixScrollBehavior()
    val layoutDirection = LocalLayoutDirection.current
    val backdrop = rememberMiuixBlurBackdrop(enableBlur)
    val navigator = LocalNavigator.current

    LaunchedEffect(pagerState.currentPage) {
        selectedTab = pagerState.currentPage
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                modifier = Modifier.installerMiuixBlurEffect(backdrop),
                color = backdrop.getMiuixAppBarColor(),
                title = title,
                scrollBehavior = scrollBehavior
            )
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .then(backdrop?.let { Modifier.layerBackdrop(it) } ?: Modifier)
                .padding(
                    start = innerPadding.calculateStartPadding(layoutDirection),
                    top = innerPadding.calculateTopPadding(),
                    end = innerPadding.calculateEndPadding(layoutDirection)
                )
        ) {
            MiuixAirSendActivityTabBar(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                selectedIndex = selectedTab,
                onSelected = { page ->
                    selectedTab = page
                    coroutineScope.launch {
                        pagerState.animateScrollToPage(page)
                    }
                },
                mode = if (enableBlur) floatingBottomBarMode else FloatingBottomBarMode.None
            )

            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize(),
                overscrollEffect = null
            ) { page ->
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .scrollEndHaptic()
                        .overScrollVertical()
                        .nestedScroll(scrollBehavior.nestedScrollConnection),
                    contentPadding = PaddingValues(
                        start = 12.dp,
                        top = 4.dp,
                        end = 12.dp,
                        bottom = innerPadding.calculateBottomPadding() + outerPadding.calculateBottomPadding() + 12.dp
                    ),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    overscrollEffect = null
                ) {
                    val activityLayout = if (page == 0) {
                        AirSendPageContent.activitySend
                    } else {
                        AirSendPageContent.activityReceive
                    }
                    airSendMiuixActivity(
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
fun MiuixAirSendSettingsPage(
    enableBlur: Boolean,
    title: String,
    outerPadding: PaddingValues
) {
    val navigator = LocalNavigator.current
    val viewModel: AirSendRuntimeViewModel = koinViewModel()
    val runtimeState by viewModel.state.collectAsStateWithLifecycle()
    MiuixAirSendRuntimeEvents(viewModel)

    MiuixAirSendPage(
        enableBlur = enableBlur,
        title = title,
        outerPadding = outerPadding
    ) {
        airSendMiuixSections(AirSendPageContent.settings.sections, navigator, runtimeState, viewModel::dispatch)
    }
}

@Composable
private fun MiuixAirSendPage(
    enableBlur: Boolean,
    title: String,
    outerPadding: PaddingValues,
    content: LazyListScope.() -> Unit
) {
    val scrollBehavior = MiuixScrollBehavior()
    val layoutDirection = LocalLayoutDirection.current
    val backdrop = rememberMiuixBlurBackdrop(enableBlur)

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                modifier = Modifier.installerMiuixBlurEffect(backdrop),
                color = backdrop.getMiuixAppBarColor(),
                title = title,
                scrollBehavior = scrollBehavior
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .then(backdrop?.let { Modifier.layerBackdrop(it) } ?: Modifier)
                .scrollEndHaptic()
                .overScrollVertical()
                .nestedScroll(scrollBehavior.nestedScrollConnection),
            contentPadding = PaddingValues(
                start = innerPadding.calculateStartPadding(layoutDirection),
                top = innerPadding.calculateTopPadding() + 12.dp,
                end = innerPadding.calculateEndPadding(layoutDirection),
                bottom = outerPadding.calculateBottomPadding() + 12.dp
            ),
            overscrollEffect = null,
            content = content
        )
    }
}

@Composable
private fun MiuixAirSendStatusCard(runtimeState: AirSendRuntimeState) {
    val containerColor = when {
        isDynamicColor -> MiuixTheme.colorScheme.secondaryContainer
        InstallerTheme.isDark -> Color(0xFF1A3825)
        else -> Color(0xFFDFFAE4)
    }
    val textContentColor =
        if (isDynamicColor) MiuixTheme.colorScheme.onSecondaryContainer else MiuixTheme.colorScheme.onSurface
    val descTextColor = textContentColor.copy(alpha = 0.8f)
    val healthy = runtimeState.serviceRunning && runtimeState.daemonReachable

    Card(
        modifier = Modifier
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .fillMaxWidth(),
        colors = CardDefaults.defaultColors(color = containerColor),
        showIndication = true,
        pressFeedbackType = PressFeedbackType.Tilt
    ) {
        Box(modifier = Modifier.fillMaxWidth()) {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .offset(50.dp, 38.dp),
                contentAlignment = Alignment.BottomEnd
            ) {
                Icon(
                    modifier = Modifier.size(170.dp),
                    imageVector = AppIcons.Active,
                    tint = if (isDynamicColor) MiuixTheme.colorScheme.primary.copy(alpha = 0.8f) else miuixHomeStatusCardColorActivated,
                    contentDescription = null
                )
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(all = 16.dp)
            ) {
                Text(
                    modifier = Modifier.fillMaxWidth(),
                    text = stringResource(
                        if (healthy) R.string.airsend_status_running else R.string.airsend_status_attention
                    ),
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = textContentColor
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    modifier = Modifier.fillMaxWidth(),
                    text = if (healthy) {
                        stringResource(R.string.airsend_status_running_desc, runtimeState.peers.size)
                    } else {
                        stringResource(R.string.airsend_status_attention_desc)
                    },
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = descTextColor
                )
                Spacer(Modifier.height(36.dp))
                Text(
                    modifier = Modifier.fillMaxWidth(),
                    text = stringResource(R.string.airsend_background_service),
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = descTextColor
                )
            }
        }
    }
}

private fun LazyListScope.airSendMiuixSections(
    sections: List<AirSendSection>,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: (() -> Unit)? = null
) {
    sections.forEach { section ->
        item(key = section.id) {
            MiuixAirSendSection(section, navigator, runtimeState, onAction, onPickFiles)
        }
    }
}

private fun LazyListScope.airSendMiuixActivity(
    layout: AirSendActivityLayout,
    selectedTab: Int,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: () -> Unit
) {
    val direction = if (selectedTab == 0) "outgoing" else "incoming"
    val transfers = runtimeState.transfers.filter { it.direction == direction }
    if (transfers.isEmpty()) {
        item(key = "activity-empty-$selectedTab") {
            MiuixAirSendActivityEmptyCard(
                icon = layout.emptyIcon.asMiuixIcon(),
                tint = MiuixTheme.colorScheme.primary,
                title = stringResource(layout.emptyTitleRes),
                description = stringResource(layout.emptyDescriptionRes)
            )
        }
    } else {
        item(key = "activity-title-$selectedTab") {
            SmallTitle(stringResource(R.string.airsend_activity_history))
        }
        items(
            count = transfers.size,
            key = { index -> "activity-transfer-${transfers[index].id}" }
        ) { index ->
            MiuixAirSendTransferCard(transfers[index], onAction)
        }
    }
    airSendMiuixSections(layout.sections, navigator, runtimeState, onAction, onPickFiles)
}

@Composable
private fun MiuixAirSendTransferCard(
    transfer: AirSendTransferSnapshot,
    onAction: (AirSendRuntimeAction) -> Unit
) {
    val context = LocalContext.current
    val title = transfer.files.singleOrNull()?.name
        ?: stringResource(R.string.airsend_transfer_files_count, transfer.files.size)
    val status = transferStatusLabel(transfer.status)
    val transferred = Formatter.formatFileSize(context, transfer.transferredBytes)
    val total = Formatter.formatFileSize(context, transfer.totalBytes)
    val isActive = !transfer.isTerminal

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 14.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = transferStatusIcon(transfer.status),
                    contentDescription = null,
                    modifier = Modifier.size(28.dp),
                    tint = transferStatusColor(transfer.status)
                )
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = title,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = stringResource(
                            R.string.airsend_transfer_peer_status,
                            transfer.peerAlias,
                            status
                        ),
                        fontSize = 13.sp,
                        color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                when {
                    isActive -> IconButton(
                        onClick = {
                            onAction(AirSendRuntimeAction.CancelTransfer(transfer.id))
                        }
                    ) {
                        Icon(
                            imageVector = AppIcons.Close,
                            contentDescription = stringResource(R.string.airsend_cancel_transfer),
                            tint = MiuixTheme.colorScheme.onSurfaceVariantActions
                        )
                    }
                    transfer.retryable -> IconButton(
                        onClick = {
                            onAction(AirSendRuntimeAction.RetryTransfer(transfer.id))
                        }
                    ) {
                        Icon(
                            imageVector = AppIcons.Retry,
                            contentDescription = stringResource(R.string.airsend_retry_transfer),
                            tint = MiuixTheme.colorScheme.primary
                        )
                    }
                }
            }

            if (isActive) {
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(
                    progress = if (transfer.status in setOf("queued", "preparing")) {
                        null
                    } else {
                        transfer.progress
                    }
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.airsend_transfer_bytes, transferred, total),
                fontSize = 12.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary
            )
            transfer.errorMessage?.takeIf { it.isNotBlank() }?.let { error ->
                Spacer(Modifier.height(4.dp))
                Text(
                    text = error,
                    fontSize = 12.sp,
                    color = MiuixTheme.colorScheme.error
                )
            }
        }
    }
}

@Composable
private fun transferStatusLabel(status: String): String = stringResource(
    when (status) {
        "queued" -> R.string.airsend_transfer_status_queued
        "awaiting_acceptance" -> R.string.airsend_transfer_status_waiting
        "preparing" -> R.string.airsend_transfer_status_preparing
        "transferring" -> R.string.airsend_transfer_status_transferring
        "paused" -> R.string.airsend_transfer_status_paused
        "completed" -> R.string.airsend_transfer_status_completed
        "failed" -> R.string.airsend_transfer_status_failed
        "cancelled" -> R.string.airsend_transfer_status_cancelled
        "declined" -> R.string.airsend_transfer_status_declined
        else -> R.string.airsend_transfer_status_unknown
    }
)

private fun transferStatusIcon(status: String): ImageVector = when (status) {
    "completed" -> AppIcons.Active
    "failed", "declined" -> AppIcons.Info
    "cancelled" -> AppIcons.Close
    else -> AppIcons.ArrowUp
}

@Composable
private fun transferStatusColor(status: String): Color = when (status) {
    "failed", "declined" -> MiuixTheme.colorScheme.error
    "cancelled" -> MiuixTheme.colorScheme.onSurfaceVariantActions
    else -> MiuixTheme.colorScheme.primary
}

private fun LazyListScope.airSendMiuixDevices(
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit
) {
    item(key = "airsend-current-target") {
        val selectedPeer = runtimeState.peers.firstOrNull {
            it.id == runtimeState.preferredTargetId
        }
        SmallTitle(stringResource(R.string.airsend_current_target))
        Card(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            BasicComponent(
                title = selectedPeer?.alias ?: stringResource(R.string.airsend_broadcast_mode),
                summary = selectedPeer?.deviceSubtitle()
                    ?: stringResource(R.string.airsend_broadcast_mode_desc),
                startAction = {
                    Icon(
                        imageVector = selectedPeer?.deviceKind()?.asMiuixIcon() ?: AppIcons.Share,
                        contentDescription = null,
                        modifier = Modifier.size(28.dp),
                        tint = MiuixTheme.colorScheme.primary
                    )
                },
                endActions = if (selectedPeer == null) null else {
                    {
                        Icon(
                            imageVector = AppIcons.Active,
                            contentDescription = stringResource(R.string.airsend_current_target),
                            modifier = Modifier.size(22.dp),
                            tint = MiuixTheme.colorScheme.primary
                        )
                    }
                }
            )
        }
    }
    item(key = "airsend-online-devices") {
        SmallTitle(stringResource(R.string.airsend_online_devices))
        Card(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            if (runtimeState.peers.isEmpty()) {
                BasicComponent(
                    title = stringResource(R.string.airsend_no_devices),
                    summary = miuixAirSendNoDeviceDescription(runtimeState),
                    startAction = {
                        Icon(
                            imageVector = AppIcons.DeviceOther,
                            contentDescription = null,
                            modifier = Modifier.size(28.dp),
                            tint = MiuixTheme.colorScheme.onSurfaceVariantActions
                        )
                    }
                )
            } else {
                runtimeState.peers.forEach { peer ->
                    BasicComponent(
                        title = peer.alias,
                        summary = peer.deviceSubtitle(),
                        startAction = {
                            Icon(
                                imageVector = peer.deviceKind().asMiuixIcon(),
                                contentDescription = null,
                                modifier = Modifier.size(28.dp),
                                tint = MiuixTheme.colorScheme.primary
                            )
                        },
                        endActions = if (!peer.selected) null else {
                            {
                                Icon(
                                    imageVector = AppIcons.Active,
                                    contentDescription = stringResource(R.string.airsend_current_target),
                                    modifier = Modifier.size(22.dp),
                                    tint = MiuixTheme.colorScheme.primary
                                )
                            }
                        },
                        onClickLabel = stringResource(R.string.airsend_select_target),
                        onClick = { onAction(AirSendRuntimeAction.SelectPeer(peer.id)) }
                    )
                }
            }
            BasicComponent(
                title = stringResource(R.string.airsend_discover_again),
                summary = stringResource(R.string.airsend_discover_again_desc),
                startAction = {
                    Icon(
                        imageVector = AppIcons.Search,
                        contentDescription = null,
                        modifier = Modifier.size(28.dp),
                        tint = MiuixTheme.colorScheme.primary
                    )
                },
                onClick = { onAction(AirSendRuntimeAction.Refresh) }
            )
        }
    }
}

@Composable
private fun MiuixAirSendSection(
    section: AirSendSection,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: (() -> Unit)?
) {
    SmallTitle(stringResource(section.titleRes))
    Card(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
        section.items.forEach { item ->
            MiuixAirSendContentItem(item, navigator, runtimeState, onAction, onPickFiles)
        }
    }
}

@Composable
private fun MiuixAirSendContentItem(
    item: AirSendContentItem,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: (() -> Unit)?
) {
    val title = stringResource(item.titleRes)
    val description = miuixAirSendDescription(item, runtimeState)
    val target = item.navigationTarget

    when {
        item.id == AirSendContentId.Startup -> {
            MiuixSwitchWidget(
                title = title,
                description = description,
                checked = runtimeState.bootStartEnabled,
                onCheckedChange = { onAction(AirSendRuntimeAction.SetBootStartEnabled(it)) }
            )
        }
        item.id == AirSendContentId.RestartService -> {
            BasicComponent(
                title = title,
                summary = description,
                onClick = { onAction(AirSendRuntimeAction.RestartService) }
            )
        }
        item.id == AirSendContentId.DiscoverAgain || item.id == AirSendContentId.NetworkDiscovery -> {
            BasicComponent(
                title = title,
                summary = description,
                onClick = { onAction(AirSendRuntimeAction.Refresh) }
            )
        }
        item.id == AirSendContentId.SendFile || item.id == AirSendContentId.SelectedFiles -> {
            BasicComponent(
                title = if (item.id == AirSendContentId.SelectedFiles) {
                    stringResource(R.string.airsend_pick_files)
                } else {
                    title
                },
                summary = description,
                enabled = runtimeState.daemonReachable && runtimeState.preferredTargetId != null,
                onClick = onPickFiles
            )
        }
        item.id == AirSendContentId.SendClipboard || item.id == AirSendContentId.ClipboardPush -> {
            BasicComponent(
                title = title,
                summary = description,
                enabled = runtimeState.daemonReachable && runtimeState.preferredTargetId != null,
                onClick = { onAction(AirSendRuntimeAction.SendClipboardText()) }
            )
        }
        item.id == AirSendContentId.LspModule -> {
            MiuixNavigationItemWidget(
                icon = item.icon.asMiuixIcon(),
                title = title,
                description = description,
                onClick = { navigator.push(Route.Priv) }
            )
        }
        item.id == AirSendContentId.ExportLogs -> {
            MiuixNavigationItemWidget(
                icon = item.icon.asMiuixIcon(),
                title = title,
                description = description,
                onClick = { navigator.push(Route.About) }
            )
        }
        target != null -> {
            MiuixNavigationItemWidget(
                icon = item.icon.asMiuixIcon(),
                title = title,
                description = description,
                onClick = { navigator.push(target.asRoute()) }
            )
        }
        item.id in miuixAirSendUnavailableActions -> {
            BasicComponent(
                title = title,
                summary = stringResource(R.string.airsend_runtime_unavailable),
                enabled = false
            )
        }
        else -> {
            BasicComponent(
                title = title,
                summary = description
            )
        }
    }
}

@Composable
@SuppressLint("LocalContextGetResourceValueCall")
private fun MiuixAirSendRuntimeEvents(viewModel: AirSendRuntimeViewModel) {
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            val message = when (event) {
                is AirSendRuntimeEvent.ShowMessage -> context.getString(event.messageRes)
                is AirSendRuntimeEvent.ShowRawMessage -> event.message
            }
            Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
        }
    }
}

@Composable
private fun miuixAirSendDescription(
    item: AirSendContentItem,
    runtimeState: AirSendRuntimeState
): String =
    when (item.id) {
        AirSendContentId.BackgroundService -> stringResource(
            if (runtimeState.serviceRunning) R.string.airsend_state_running else R.string.airsend_state_stopped
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
        AirSendContentId.NearbyTargets,
        AirSendContentId.SavedDevices -> stringResource(R.string.airsend_peer_count, runtimeState.peers.size)
        AirSendContentId.SendFile,
        AirSendContentId.SelectedFiles,
        AirSendContentId.SendClipboard,
        AirSendContentId.ClipboardPush -> runtimeState.peers
            .firstOrNull { it.id == runtimeState.preferredTargetId }
            ?.let { stringResource(R.string.airsend_send_to_peer, it.alias) }
            ?: stringResource(R.string.airsend_select_target_before_sending)
        AirSendContentId.SendMode -> runtimeState.peers
            .firstOrNull { it.id == runtimeState.preferredTargetId }
            ?.let { stringResource(R.string.airsend_single_target_mode, it.alias) }
            ?: stringResource(R.string.airsend_select_target_before_sending)
        AirSendContentId.ClipboardSync -> if (runtimeState.daemonReachable) {
            stringResource(item.descriptionRes)
        } else {
            stringResource(R.string.airsend_state_unreachable)
        }
        else -> stringResource(item.descriptionRes)
    }

@Composable
private fun miuixAirSendNoDeviceDescription(runtimeState: AirSendRuntimeState): String =
    if (!runtimeState.daemonReachable && runtimeState.lastError != null) {
        stringResource(R.string.airsend_daemon_error, runtimeState.lastError)
    } else {
        stringResource(R.string.airsend_no_devices_desc)
    }

private val miuixAirSendUnavailableActions = setOf(
    AirSendContentId.AddManual,
    AirSendContentId.PairTrust,
    AirSendContentId.ReceiveRequests,
    AirSendContentId.QuickSave,
    AirSendContentId.SaveLocation,
    AirSendContentId.TrustedDevices
)

private fun AirSendNavigationTarget.asRoute(): Route =
    when (this) {
        AirSendNavigationTarget.Theme -> Route.Theme
        AirSendNavigationTarget.Permissions -> Route.Priv
        AirSendNavigationTarget.About -> Route.About
    }

@Composable
private fun AirSendContentIcon.asMiuixIcon(): ImageVector =
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

private fun AirSendDeviceKind.asMiuixIcon(): ImageVector = when (this) {
    AirSendDeviceKind.Phone -> AppIcons.DevicePhone
    AirSendDeviceKind.Tablet -> AppIcons.DeviceTablet
    AirSendDeviceKind.Laptop -> AppIcons.DeviceLaptop
    AirSendDeviceKind.Desktop -> AppIcons.DeviceDesktop
    AirSendDeviceKind.Tv -> AppIcons.DeviceTv
    AirSendDeviceKind.Watch -> AppIcons.DeviceWatch
    AirSendDeviceKind.Other -> AppIcons.DeviceOther
}

@Composable
private fun MiuixAirSendActivityTabBar(
    modifier: Modifier = Modifier,
    selectedIndex: Int,
    onSelected: (Int) -> Unit,
    mode: FloatingBottomBarMode
) {
    val tabBackdrop = rememberLayerBackdrop()
    val selectedIndexState = rememberUpdatedState(selectedIndex)
    val selectedIndexProvider = remember {
        { selectedIndexState.value }
    }

    Box(
        modifier = modifier,
        contentAlignment = Alignment.Center
    ) {
        FloatingBottomBar(
            modifier = Modifier.clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = {},
            ),
            selectedIndex = selectedIndexProvider,
            onSelected = onSelected,
            backdrop = tabBackdrop,
            tabsCount = 2,
            mode = mode
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
private fun MiuixAirSendActivityEmptyCard(
    icon: ImageVector,
    tint: Color,
    title: String,
    description: String
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        insideMargin = PaddingValues(24.dp)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(36.dp)
            )
            Text(
                text = title,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = description,
                fontSize = 14.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary
            )
        }
    }
}

@Composable
private fun MiuixAirSendActivityMetaCard(
    firstTitle: String,
    firstDesc: String,
    secondTitle: String,
    secondDesc: String
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        BasicComponent(
            title = firstTitle,
            summary = firstDesc
        )
        BasicComponent(
            title = secondTitle,
            summary = secondDesc
        )
    }
    Spacer(modifier = Modifier.height(4.dp))
}
