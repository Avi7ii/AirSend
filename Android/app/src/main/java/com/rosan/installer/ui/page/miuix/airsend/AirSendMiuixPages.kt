// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.miuix.airsend

import android.Manifest
import android.os.Build
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Velocity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.airbnb.lottie.LottieProperty
import com.airbnb.lottie.compose.LottieAnimation
import com.airbnb.lottie.compose.LottieCompositionSpec
import com.airbnb.lottie.compose.LottieConstants
import com.airbnb.lottie.compose.rememberLottieComposition
import com.airbnb.lottie.compose.rememberLottieDynamicProperties
import com.airbnb.lottie.compose.rememberLottieDynamicProperty
import com.airbnb.lottie.value.ScaleXY
import com.rosan.installer.R
import com.rosan.installer.ui.icons.AppIcons
import com.rosan.installer.ui.library.FloatingBottomBar
import com.rosan.installer.ui.library.FloatingBottomBarItem
import com.rosan.installer.ui.library.FloatingBottomBarMode
import com.rosan.installer.ui.navigation.LocalNavigator
import com.rosan.installer.ui.navigation.Navigator
import com.rosan.installer.ui.navigation.Route
import com.rosan.installer.ui.page.main.installer.components.PositionDialog
import com.rosan.installer.ui.page.main.installer.dialog.DialogButton
import com.rosan.installer.ui.page.main.installer.dialog.dialogButtons
import com.rosan.installer.ui.page.main.installer.dialog.dialogInnerWidget
import com.rosan.installer.ui.page.main.widget.setting.SwitchWidget
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
import com.rosan.installer.ui.page.airsend.runtime.AirSendAuthorizationMode
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeEvent
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeState
import com.rosan.installer.ui.page.airsend.runtime.AirSendTransferSnapshot
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeViewModel
import com.rosan.installer.ui.page.airsend.runtime.AirSendFileKind
import com.rosan.installer.ui.page.airsend.runtime.AirSendContentPreview
import com.rosan.installer.ui.page.airsend.runtime.classifyAirSendFileKind
import com.rosan.installer.ui.page.airsend.runtime.loadAirSendContentPreview
import com.rosan.installer.ui.page.main.settings.history.formatHistoryTime
import com.rosan.installer.ui.page.miuix.widgets.MiuixSwitchWidget
import com.rosan.installer.ui.page.miuix.widgets.MiuixNavigationItemWidget
import com.rosan.installer.ui.theme.InstallerTheme
import com.rosan.installer.ui.theme.InstallerMaterialExpressiveTheme
import com.rosan.installer.ui.theme.getMiuixAppBarColor
import com.rosan.installer.ui.theme.installerMiuixBlurEffect
import com.rosan.installer.ui.theme.miuixHomeStatusCardColorActivated
import com.rosan.installer.ui.theme.miuixHomeStatusCardColorDeactivated
import com.rosan.installer.ui.theme.rememberMiuixBlurBackdrop
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.CardDefaults
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.LinearProgressIndicator
import top.yukonga.miuix.kmp.basic.MiuixScrollBehavior
import top.yukonga.miuix.kmp.basic.PullToRefresh
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.SnackbarHostState
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.ScrollBarColors
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.basic.TextField
import top.yukonga.miuix.kmp.basic.DropdownItem
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.basic.VerticalScrollBar
import top.yukonga.miuix.kmp.basic.rememberPullToRefreshState
import top.yukonga.miuix.kmp.basic.rememberScrollBarAdapter
import top.yukonga.miuix.kmp.blur.LayerBackdrop
import top.yukonga.miuix.kmp.blur.layerBackdrop
import top.yukonga.miuix.kmp.blur.rememberLayerBackdrop
import top.yukonga.miuix.kmp.interfaces.ExperimentalScrollBarApi
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.theme.MiuixTheme.isDynamicColor
import top.yukonga.miuix.kmp.utils.PressFeedbackType
import top.yukonga.miuix.kmp.utils.overScrollVertical
import top.yukonga.miuix.kmp.utils.scrollEndHaptic
import top.yukonga.miuix.kmp.window.WindowDialog
import top.yukonga.miuix.kmp.preference.WindowSpinnerPreference
import kotlinx.coroutines.Job
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
    var showDiagnostics by rememberSaveable { mutableStateOf(false) }
    var permissionRequestInFlight by remember { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) {
        permissionRequestInFlight = false
        viewModel.dispatch(AirSendRuntimeAction.RefreshSilently)
    }

    MiuixAirSendPage(
        enableBlur = enableBlur,
        title = title,
        outerPadding = outerPadding,
        isRefreshing = runtimeState.isRefreshing,
        onRefresh = { viewModel.dispatch(AirSendRuntimeAction.Refresh) }
    ) {
        if (AirSendPageContent.home.statusPlacement == AirSendStatusPlacement.TopCard) {
            item {
                MiuixAirSendStatusCard(
                    runtimeState = runtimeState,
                    onClick = { showDiagnostics = true }
                )
            }
        }
        airSendMiuixSections(
            AirSendPageContent.home.sections,
            navigator,
            runtimeState,
            viewModel::dispatch,
            onRequestPermissions = {
                if (!permissionRequestInFlight) {
                    permissionRequestInFlight = true
                    permissionLauncher.launch(airSendRuntimePermissions())
                }
            }
        )
    }
    if (showDiagnostics) {
        MiuixAirSendDiagnosticsDialog(
            runtimeState = runtimeState,
            onRestartDaemon = {
                showDiagnostics = false
                viewModel.dispatch(AirSendRuntimeAction.RestartDaemon)
            },
            onDismiss = { showDiagnostics = false }
        )
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
    var showAddManualPeer by rememberSaveable { mutableStateOf(false) }

    MiuixAirSendPage(
        enableBlur = enableBlur,
        title = title,
        outerPadding = outerPadding,
        isRefreshing = runtimeState.isRefreshing,
        onRefresh = { viewModel.dispatch(AirSendRuntimeAction.DiscoverNow) }
    ) {
        airSendMiuixDevices(
            runtimeState,
            viewModel::dispatch,
            onAddManualPeer = { showAddManualPeer = true }
        )
    }
    if (showAddManualPeer) {
        MiuixAirSendManualPeerDialog(
            onDismiss = { showAddManualPeer = false },
            onConfirm = { alias, address, port, fingerprint ->
                showAddManualPeer = false
                viewModel.dispatch(
                    AirSendRuntimeAction.AddManualPeer(alias, address, port, fingerprint)
                )
            }
        )
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
    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isNotEmpty()) {
            viewModel.dispatch(AirSendRuntimeAction.SendFiles(uris))
        }
    }
    val downloadLocationPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        uri?.let { viewModel.dispatch(AirSendRuntimeAction.SetDownloadDestination(it)) }
    }
    val mediaLocationPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        uri?.let { viewModel.dispatch(AirSendRuntimeAction.SetMediaDestination(it)) }
    }
    val pagerState = rememberPagerState(initialPage = 0, pageCount = { 2 })
    val coroutineScope = rememberCoroutineScope()
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    val scrollBehavior = MiuixScrollBehavior()
    val historyScrollIsolation = remember { mutableStateOf(false) }
    val activityScrollConnection = remember(scrollBehavior.nestedScrollConnection) {
        val delegate = scrollBehavior.nestedScrollConnection
        object : NestedScrollConnection {
            override fun onPreScroll(
                available: Offset,
                source: NestedScrollSource
            ): Offset = if (historyScrollIsolation.value) {
                Offset.Zero
            } else {
                delegate.onPreScroll(available, source)
            }

            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource
            ): Offset = if (historyScrollIsolation.value) {
                Offset.Zero
            } else {
                delegate.onPostScroll(consumed, available, source)
            }

            override suspend fun onPreFling(available: Velocity): Velocity =
                if (historyScrollIsolation.value) {
                    Velocity.Zero
                } else {
                    delegate.onPreFling(available)
                }

            override suspend fun onPostFling(
                consumed: Velocity,
                available: Velocity
            ): Velocity = if (historyScrollIsolation.value) {
                Velocity.Zero
            } else {
                delegate.onPostFling(consumed, available)
            }
        }
    }
    val layoutDirection = LocalLayoutDirection.current
    val backdrop = rememberMiuixBlurBackdrop(enableBlur)
    val activityTabBackdrop = rememberLayerBackdrop()
    val navigator = LocalNavigator.current
    var showClearHistory by rememberSaveable { mutableStateOf(false) }
    var showTargetPicker by rememberSaveable { mutableStateOf(false) }
    var selectedTransfer by remember { mutableStateOf<AirSendTransferSnapshot?>(null) }
    val selectedDirection = if (selectedTab == 0) "outgoing" else "incoming"
    val clearHistoryTitle = stringResource(
        if (selectedTab == 0) {
            R.string.airsend_clear_sent_history
        } else {
            R.string.airsend_clear_received_history
        }
    )
    val clearHistoryConfirm = stringResource(
        if (selectedTab == 0) {
            R.string.airsend_clear_sent_history_confirm
        } else {
            R.string.airsend_clear_received_history_confirm
        }
    )
    val hasClearableHistory = runtimeState.transfers.any {
        it.direction == selectedDirection && it.isTerminal
    }

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
                actions = {
                    IconButton(
                        enabled = hasClearableHistory,
                        onClick = { showClearHistory = true }
                    ) {
                        Icon(
                            imageVector = AppIcons.Delete,
                            contentDescription = clearHistoryTitle
                        )
                    }
                },
                scrollBehavior = scrollBehavior
            )
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .then(backdrop?.let { Modifier.layerBackdrop(it) } ?: Modifier)
                .padding(
                    start = innerPadding.calculateStartPadding(layoutDirection),
                    top = innerPadding.calculateTopPadding(),
                    end = innerPadding.calculateEndPadding(layoutDirection)
                )
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .layerBackdrop(activityTabBackdrop)
            ) {
                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.fillMaxSize(),
                    overscrollEffect = null
                ) { page ->
                    val pageScrollState = rememberLazyListState()

                    LazyColumn(
                        state = pageScrollState,
                        modifier = Modifier
                            .fillMaxSize()
                            .scrollEndHaptic()
                            .overScrollVertical()
                            .nestedScroll(activityScrollConnection),
                        contentPadding = PaddingValues(
                            start = 12.dp,
                            top = 84.dp,
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
                            onPickFiles = { filePicker.launch(arrayOf("*/*")) },
                            onPickDownloadLocation = { downloadLocationPicker.launch(null) },
                            onPickMediaLocation = { mediaLocationPicker.launch(null) },
                            onPickTarget = { showTargetPicker = true },
                            onHistoryGestureActiveChange = { active ->
                                historyScrollIsolation.value = active
                            },
                            onOpenTransfer = { transfer ->
                                selectedTransfer = transfer
                            }
                        )
                    }
                }
            }

            MiuixAirSendActivityTabBar(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                selectedIndex = selectedTab,
                onSelected = { page ->
                    selectedTab = page
                    coroutineScope.launch {
                        pagerState.animateScrollToPage(page)
                    }
                },
                backdrop = activityTabBackdrop,
                mode = floatingBottomBarMode
            )
        }
    }
    if (showClearHistory) {
        MiuixAirSendConfirmDialog(
            title = clearHistoryTitle,
            message = clearHistoryConfirm,
            onDismiss = { showClearHistory = false },
            onConfirm = {
                showClearHistory = false
                viewModel.dispatch(AirSendRuntimeAction.ClearHistory(selectedDirection))
            }
        )
    }
    if (showTargetPicker) {
        MiuixAirSendTargetDialog(
            runtimeState = runtimeState,
            onDismiss = { showTargetPicker = false },
            onDiscover = { viewModel.dispatch(AirSendRuntimeAction.DiscoverNow) },
            onSelect = { peerId ->
                showTargetPicker = false
                viewModel.dispatch(AirSendRuntimeAction.SelectPeer(peerId))
            }
        )
    }
    selectedTransfer?.let { transfer ->
        MiuixAirSendTransferDetailDialog(
            transfer = transfer,
            useBlur = enableBlur,
            onAction = viewModel::dispatch,
            onDismiss = { selectedTransfer = null }
        )
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
    var permissionRequestInFlight by remember { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) {
        permissionRequestInFlight = false
        viewModel.dispatch(AirSendRuntimeAction.RefreshSilently)
    }
    val downloadLocationPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        uri?.let { viewModel.dispatch(AirSendRuntimeAction.SetDownloadDestination(it)) }
    }
    val mediaLocationPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        uri?.let { viewModel.dispatch(AirSendRuntimeAction.SetMediaDestination(it)) }
    }
    val logExporter = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("text/plain")
    ) { uri ->
        uri?.let { viewModel.dispatch(AirSendRuntimeAction.ExportLogs(it)) }
    }
    var showClearLogs by rememberSaveable { mutableStateOf(false) }
    var showTrustedDevices by rememberSaveable { mutableStateOf(false) }
    var showDiagnostics by rememberSaveable { mutableStateOf(false) }

    MiuixAirSendPage(
        enableBlur = enableBlur,
        title = title,
        outerPadding = outerPadding,
        isRefreshing = runtimeState.isRefreshing,
        onRefresh = { viewModel.dispatch(AirSendRuntimeAction.Refresh) }
    ) {
        airSendMiuixSections(
            sections = AirSendPageContent.settings.sections,
            navigator = navigator,
            runtimeState = runtimeState,
            onAction = viewModel::dispatch,
            onPickDownloadLocation = { downloadLocationPicker.launch(null) },
            onPickMediaLocation = { mediaLocationPicker.launch(null) },
            onExportLogs = { logExporter.launch("AirSend-daemon.log") },
            onClearLogs = { showClearLogs = true },
            onShowTrustedDevices = { showTrustedDevices = true },
            onShowDiagnostics = { showDiagnostics = true },
            onRequestPermissions = {
                if (!permissionRequestInFlight) {
                    permissionRequestInFlight = true
                    permissionLauncher.launch(airSendRuntimePermissions())
                }
            }
        )
    }
    if (showClearLogs) {
        MiuixAirSendConfirmDialog(
            title = stringResource(R.string.airsend_clear_logs),
            message = stringResource(R.string.airsend_clear_logs_confirm),
            onDismiss = { showClearLogs = false },
            onConfirm = {
                showClearLogs = false
                viewModel.dispatch(AirSendRuntimeAction.ClearLogs)
            }
        )
    }
    if (showTrustedDevices) {
        MiuixAirSendTrustedDevicesDialog(
            runtimeState = runtimeState,
            onDismiss = { showTrustedDevices = false },
            onRevoke = { fingerprint ->
                viewModel.dispatch(AirSendRuntimeAction.SetPeerTrusted(fingerprint, false))
            }
        )
    }
    if (showDiagnostics) {
        MiuixAirSendDiagnosticsDialog(
            runtimeState = runtimeState,
            onRestartDaemon = {
                showDiagnostics = false
                viewModel.dispatch(AirSendRuntimeAction.RestartDaemon)
            },
            onDismiss = { showDiagnostics = false }
        )
    }
}

@Composable
private fun MiuixAirSendPage(
    enableBlur: Boolean,
    title: String,
    outerPadding: PaddingValues,
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    content: LazyListScope.() -> Unit
) {
    val scrollBehavior = MiuixScrollBehavior()
    val layoutDirection = LocalLayoutDirection.current
    val backdrop = rememberMiuixBlurBackdrop(enableBlur)
    val pullToRefreshState = rememberPullToRefreshState()
    val refreshTexts = listOf(
        stringResource(R.string.airsend_refresh_pulling),
        stringResource(R.string.airsend_refresh_release),
        stringResource(R.string.airsend_refreshing),
        stringResource(R.string.airsend_refresh_complete)
    )

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
        PullToRefresh(
            isRefreshing = isRefreshing,
            pullToRefreshState = pullToRefreshState,
            onRefresh = onRefresh,
            refreshTexts = refreshTexts,
            contentPadding = PaddingValues(
                start = innerPadding.calculateStartPadding(layoutDirection),
                top = innerPadding.calculateTopPadding() + 12.dp,
                end = innerPadding.calculateEndPadding(layoutDirection)
            ),
        ) {
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
}

@Composable
private fun MiuixAirSendStatusCard(
    runtimeState: AirSendRuntimeState,
    onClick: () -> Unit
) {
    val activationPending = runtimeState.lspActivationPending
    val healthy = runtimeState.backgroundServiceRunning &&
        runtimeState.rootRuntimeHealthy &&
        runtimeState.daemonReachable &&
        runtimeState.tlsReady &&
        runtimeState.storageReady &&
        !activationPending
    val containerColor = when {
        activationPending -> when {
            isDynamicColor -> MiuixTheme.colorScheme.surfaceVariant
            InstallerTheme.isDark -> Color(0xFF2A2A2D)
            else -> Color(0xFFE7E7EA)
        }
        healthy -> when {
            isDynamicColor -> MiuixTheme.colorScheme.secondaryContainer
            InstallerTheme.isDark -> Color(0xFF1A3825)
            else -> Color(0xFFDFFAE4)
        }
        else -> when {
            isDynamicColor -> MiuixTheme.colorScheme.errorContainer
            InstallerTheme.isDark -> Color(0xFF381A1A)
            else -> Color(0xFFFAEEEE)
        }
    }
    val textContentColor = when {
        activationPending -> if (isDynamicColor) {
            MiuixTheme.colorScheme.onSurfaceVariantActions
        } else {
            if (InstallerTheme.isDark) Color(0xFFDADAE0) else Color(0xFF4A4A50)
        }
        healthy -> if (isDynamicColor) {
            MiuixTheme.colorScheme.onSecondaryContainer
        } else {
            MiuixTheme.colorScheme.onSurface
        }
        else -> if (isDynamicColor) {
            MiuixTheme.colorScheme.onErrorContainer
        } else {
            MiuixTheme.colorScheme.onSurface
        }
    }
    val descTextColor = textContentColor.copy(alpha = 0.8f)
    val authorizationLabelRes = when (runtimeState.authorizationMode) {
        AirSendAuthorizationMode.Root -> R.string.airsend_authorization_root
        AirSendAuthorizationMode.Shizuku -> R.string.airsend_authorization_shizuku
        AirSendAuthorizationMode.Dhizuku -> R.string.airsend_authorization_dhizuku
        AirSendAuthorizationMode.AppProcess -> R.string.airsend_authorization_no_root
        AirSendAuthorizationMode.Customize -> R.string.airsend_authorization_customize
    }

    Card(
        modifier = Modifier
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .fillMaxWidth(),
        colors = CardDefaults.defaultColors(color = containerColor),
        showIndication = true,
        pressFeedbackType = PressFeedbackType.Tilt,
        onClick = onClick
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
                    imageVector = when {
                        activationPending -> AppIcons.LSPosed
                        healthy -> AppIcons.Active
                        else -> Icons.Rounded.ErrorOutline
                    },
                    tint = when {
                        activationPending -> textContentColor.copy(alpha = 0.72f)
                        healthy -> if (isDynamicColor) {
                            MiuixTheme.colorScheme.primary.copy(alpha = 0.8f)
                        } else {
                            miuixHomeStatusCardColorActivated
                        }
                        else -> if (isDynamicColor) {
                            MiuixTheme.colorScheme.error.copy(alpha = 0.8f)
                        } else {
                            miuixHomeStatusCardColorDeactivated
                        }
                    },
                    contentDescription = null
                )
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(all = 16.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        modifier = Modifier.weight(1f),
                        text = stringResource(
                            when {
                                activationPending -> R.string.airsend_status_pending
                                healthy -> R.string.airsend_status_ready
                                else -> R.string.airsend_status_attention
                            }
                        ),
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                        color = textContentColor
                    )
                    Text(
                        text = stringResource(authorizationLabelRes),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = descTextColor
                    )
                }
                Spacer(Modifier.height(2.dp))
                Text(
                    modifier = Modifier.fillMaxWidth(),
                    text = when {
                        activationPending -> stringResource(R.string.airsend_status_pending_desc)
                        healthy -> stringResource(
                            R.string.airsend_status_ready_desc,
                            runtimeState.peers.size
                        )
                        else -> stringResource(R.string.airsend_status_attention_desc)
                    },
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = descTextColor
                )
                Spacer(Modifier.height(36.dp))
                Text(
                    modifier = Modifier.fillMaxWidth(),
                    text = stringResource(R.string.airsend_runtime_diagnostics),
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
    onPickFiles: (() -> Unit)? = null,
    onPickDownloadLocation: (() -> Unit)? = null,
    onPickMediaLocation: (() -> Unit)? = null,
    onPickTarget: (() -> Unit)? = null,
    onExportLogs: (() -> Unit)? = null,
    onClearLogs: (() -> Unit)? = null,
    onRequestPermissions: (() -> Unit)? = null,
    onShowTrustedDevices: (() -> Unit)? = null,
    onShowDiagnostics: (() -> Unit)? = null
) {
    sections.forEach { section ->
        item(key = section.id) {
            MiuixAirSendSection(
                section,
                navigator,
                runtimeState,
                onAction,
                onPickFiles,
                onPickDownloadLocation,
                onPickMediaLocation,
                onPickTarget,
                onExportLogs,
                onClearLogs,
                onRequestPermissions,
                onShowTrustedDevices,
                onShowDiagnostics
            )
        }
    }
}

private fun LazyListScope.airSendMiuixActivity(
    layout: AirSendActivityLayout,
    selectedTab: Int,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: () -> Unit,
    onPickDownloadLocation: () -> Unit,
    onPickMediaLocation: () -> Unit,
    onPickTarget: () -> Unit,
    onHistoryGestureActiveChange: (Boolean) -> Unit,
    onOpenTransfer: (AirSendTransferSnapshot) -> Unit
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
        item(key = "activity-history-container-$selectedTab") {
            key(direction) {
                MiuixAirSendHistoryContainer(
                    transfers = transfers,
                    isRefreshing = runtimeState.isRefreshing,
                    onRefresh = { onAction(AirSendRuntimeAction.Refresh) },
                    onGestureActiveChange = onHistoryGestureActiveChange,
                    onOpenTransfer = onOpenTransfer
                )
            }
        }
    }
    airSendMiuixSections(
        layout.sections,
        navigator,
        runtimeState,
        onAction,
        onPickFiles,
        onPickDownloadLocation,
        onPickMediaLocation,
        onPickTarget
    )
}

@OptIn(ExperimentalScrollBarApi::class)
@Composable
private fun MiuixAirSendHistoryContainer(
    transfers: List<AirSendTransferSnapshot>,
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    onGestureActiveChange: (Boolean) -> Unit,
    onOpenTransfer: (AirSendTransferSnapshot) -> Unit
) {
    val pullToRefreshState = rememberPullToRefreshState()
    val historyScrollState = rememberScrollState()
    val historyScrollBarAdapter = rememberScrollBarAdapter(historyScrollState)
    val gestureScope = rememberCoroutineScope()
    val density = LocalDensity.current
    var historyViewportHeightPx by remember { mutableIntStateOf(0) }
    var gestureReleaseJob by remember { mutableStateOf<Job?>(null) }
    val currentOnGestureActiveChange by rememberUpdatedState(onGestureActiveChange)
    DisposableEffect(Unit) {
        onDispose {
            gestureReleaseJob?.cancel()
            currentOnGestureActiveChange(false)
        }
    }
    val historyBoundaryConnection = remember {
        object : NestedScrollConnection {
            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource
            ): Offset {
                val stopAtTop = available.y > 0f
                return if (source == NestedScrollSource.UserInput || stopAtTop) {
                    Offset(0f, available.y)
                } else {
                    Offset.Zero
                }
            }

            override suspend fun onPostFling(
                consumed: Velocity,
                available: Velocity
            ): Velocity = if (available.y > 0f) {
                Velocity(0f, available.y)
            } else {
                Velocity.Zero
            }
        }
    }
    val historyContainerMaxHeight = with(density) {
        (LocalWindowInfo.current.containerSize.height * 9 / 20).toDp()
    }
    val refreshTexts = listOf(
        stringResource(R.string.airsend_refresh_pulling),
        stringResource(R.string.airsend_refresh_release),
        stringResource(R.string.airsend_refreshing),
        stringResource(R.string.airsend_refresh_complete)
    )

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .nestedScroll(historyBoundaryConnection)
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(
                        requireUnconsumed = false,
                        pass = PointerEventPass.Initial
                    )
                    gestureReleaseJob?.cancel()
                    currentOnGestureActiveChange(true)
                    try {
                        while (true) {
                            val event = awaitPointerEvent(pass = PointerEventPass.Final)
                            if (event.changes.none { it.pressed }) break
                        }
                    } finally {
                        gestureReleaseJob?.cancel()
                        gestureReleaseJob = gestureScope.launch {
                            withFrameNanos { }
                            while (historyScrollState.isScrollInProgress) {
                                withFrameNanos { }
                            }
                            currentOnGestureActiveChange(false)
                        }
                    }
                }
            },
        insideMargin = PaddingValues(horizontal = 8.dp, vertical = 10.dp)
    ) {
        PullToRefresh(
            isRefreshing = isRefreshing,
            pullToRefreshState = pullToRefreshState,
            onRefresh = onRefresh,
            refreshTexts = refreshTexts,
            contentPadding = PaddingValues(0.dp)
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = historyContainerMaxHeight)
                    .onSizeChanged { historyViewportHeightPx = it.height }
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(
                            state = historyScrollState,
                            overscrollEffect = null
                        )
                        .padding(end = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    transfers.forEach { transfer ->
                        MiuixAirSendTransferBriefCard(
                            transfer = transfer,
                            onClick = { onOpenTransfer(transfer) }
                        )
                    }
                }
                if (historyViewportHeightPx > 0) {
                    VerticalScrollBar(
                        adapter = historyScrollBarAdapter,
                        modifier = Modifier
                            .align(Alignment.CenterEnd)
                            .height(with(density) { historyViewportHeightPx.toDp() }),
                        colors = ScrollBarColors(
                            thumbColor = MiuixTheme.colorScheme.primary.copy(alpha = 0.48f),
                            trackColor = MiuixTheme.colorScheme.onSurface.copy(alpha = 0.07f)
                        ),
                        thumbWidth = 3.5.dp,
                        cornerRadius = 2.5.dp,
                        thumbMinLength = 32.dp,
                        endPadding = 1.dp,
                        alwaysVisible = true
                    )
                }
            }
        }
    }
}

@Composable
private fun MiuixAirSendTargetDialog(
    runtimeState: AirSendRuntimeState,
    onDismiss: () -> Unit,
    onDiscover: () -> Unit,
    onSelect: (String) -> Unit
) {
    val onlinePeers = runtimeState.peers.filter { it.online }
    WindowDialog(
        show = true,
        onDismissRequest = onDismiss,
        title = stringResource(R.string.airsend_share_choose_target),
        content = {
            Column {
                MiuixAirSendScrollableDialogCard {
                    if (onlinePeers.isEmpty()) {
                        BasicComponent(
                            title = stringResource(R.string.airsend_no_devices),
                            summary = stringResource(R.string.airsend_share_no_target_desc),
                            startAction = {
                                Icon(
                                    imageVector = AppIcons.DeviceOther,
                                    contentDescription = null,
                                    modifier = Modifier.size(28.dp),
                                    tint = MiuixTheme.colorScheme.onSurfaceVariantActions
                                )
                            },
                            onClick = onDiscover
                        )
                    } else {
                        onlinePeers.forEach { peer ->
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
                                endActions = if (peer.id == runtimeState.preferredTargetId) {
                                    {
                                        Icon(
                                            imageVector = AppIcons.Active,
                                            contentDescription = stringResource(R.string.airsend_current_target),
                                            modifier = Modifier.size(22.dp),
                                            tint = MiuixTheme.colorScheme.primary
                                        )
                                    }
                                } else null,
                                onClick = { onSelect(peer.id) }
                            )
                        }
                    }
                }
                Spacer(Modifier.height(20.dp))
                TextButton(
                    modifier = Modifier.fillMaxWidth(),
                    text = stringResource(R.string.cancel),
                    colors = ButtonDefaults.textButtonColors(),
                    onClick = onDismiss
                )
            }
        }
    )
}

@Composable
private fun MiuixAirSendTrustedDevicesDialog(
    runtimeState: AirSendRuntimeState,
    onDismiss: () -> Unit,
    onRevoke: (String) -> Unit
) {
    WindowDialog(
        show = true,
        onDismissRequest = onDismiss,
        title = stringResource(R.string.airsend_trusted_devices),
        content = {
            Column {
                MiuixAirSendScrollableDialogCard(maxHeight = 560.dp) {
                    if (runtimeState.trustedPeerFingerprints.isEmpty()) {
                        BasicComponent(
                            title = stringResource(R.string.airsend_no_trusted_devices),
                            summary = stringResource(R.string.airsend_no_trusted_devices_desc)
                        )
                    } else {
                        runtimeState.trustedPeerFingerprints.sorted().forEach { fingerprint ->
                            val peer = runtimeState.peers.firstOrNull {
                                it.fingerprint.equals(fingerprint, ignoreCase = true)
                            }
                            BasicComponent(
                                title = peer?.alias ?: stringResource(R.string.airsend_unknown_device),
                                summary = listOfNotNull(
                                    peer?.address?.takeIf(String::isNotBlank),
                                    fingerprint.chunked(8).joinToString(":" )
                                ).joinToString(" · "),
                                endActions = {
                                    TextButton(
                                        text = stringResource(R.string.airsend_revoke_trust),
                                        onClick = { onRevoke(fingerprint) }
                                    )
                                }
                            )
                        }
                    }
                }
                Spacer(Modifier.height(20.dp))
                TextButton(
                    modifier = Modifier.fillMaxWidth(),
                    text = stringResource(R.string.confirm),
                    colors = ButtonDefaults.textButtonColorsPrimary(),
                    onClick = onDismiss
                )
            }
        }
    )
}

@Composable
private fun MiuixAirSendDiagnosticsDialog(
    runtimeState: AirSendRuntimeState,
    onRestartDaemon: () -> Unit,
    onDismiss: () -> Unit
) {
    val yes = stringResource(R.string.airsend_health_ready)
    val no = stringResource(R.string.airsend_health_unavailable)
    val rows = listOf(
        stringResource(R.string.airsend_diagnostic_app_version) to
            "${runtimeState.appVersion} (${runtimeState.appVersionCode})",
        stringResource(R.string.airsend_diagnostic_root) to
            (runtimeState.rootProvider ?: no),
        stringResource(R.string.airsend_diagnostic_module) to
            (runtimeState.moduleVersion ?: no),
        stringResource(R.string.airsend_diagnostic_daemon) to
            (runtimeState.daemonVersion ?: no),
        stringResource(R.string.airsend_diagnostic_protocol) to
            (runtimeState.protocolVersion?.toString() ?: no),
        "TLS" to if (runtimeState.tlsReady) yes else no,
        "LSPosed IPC" to if (runtimeState.reverseClipboardIpcReady) yes else no,
        stringResource(R.string.airsend_diagnostic_storage) to
            if (runtimeState.storageReady) yes else no,
        stringResource(R.string.airsend_diagnostic_network) to
            (runtimeState.networkBinding ?: no),
        stringResource(R.string.airsend_diagnostic_ports) to
            listOfNotNull(runtimeState.transferPort, runtimeState.discoveryPort)
                .joinToString(" / ")
                .ifBlank { no },
        stringResource(R.string.airsend_diagnostic_target) to
            (runtimeState.peers.firstOrNull { it.id == runtimeState.preferredTargetId }?.alias
                ?: stringResource(R.string.airsend_no_target))
    )
    WindowDialog(
        show = true,
        onDismissRequest = onDismiss,
        title = stringResource(R.string.airsend_runtime_diagnostics),
        content = {
            Column {
                MiuixAirSendScrollableDialogCard(maxHeight = 560.dp) {
                    rows.forEach { (label, value) ->
                        BasicComponent(title = label, summary = value)
                    }
                }
                runtimeState.lastError?.let { error ->
                    Spacer(Modifier.height(12.dp))
                    Text(text = error, color = MiuixTheme.colorScheme.error)
                }
                Spacer(Modifier.height(20.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    TextButton(
                        modifier = Modifier.weight(1f),
                        text = stringResource(R.string.airsend_restart_daemon),
                        enabled = runtimeState.daemonReachable,
                        onClick = onRestartDaemon
                    )
                    TextButton(
                        modifier = Modifier.weight(1f),
                        text = stringResource(R.string.confirm),
                        colors = ButtonDefaults.textButtonColorsPrimary(),
                        onClick = onDismiss
                    )
                }
            }
        }
    )
}

@Composable
private fun MiuixAirSendScrollableDialogCard(
    maxHeight: androidx.compose.ui.unit.Dp = 440.dp,
    content: @Composable ColumnScope.() -> Unit
) {
    val scrollState = rememberScrollState()
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = maxHeight)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(scrollState),
            content = content
        )
    }
}

@Composable
private fun MiuixAirSendConfirmDialog(
    title: String,
    message: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit
) {
    WindowDialog(
        show = true,
        onDismissRequest = onDismiss,
        title = title,
        content = {
            Column {
                Text(
                    text = message,
                    color = MiuixTheme.colorScheme.onSurface
                )
                Spacer(Modifier.height(24.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    TextButton(
                        modifier = Modifier.weight(1f),
                        text = stringResource(R.string.cancel),
                        onClick = onDismiss
                    )
                    TextButton(
                        modifier = Modifier.weight(1f),
                        text = stringResource(R.string.confirm),
                        colors = ButtonDefaults.textButtonColorsPrimary(),
                        onClick = onConfirm
                    )
                }
            }
        }
    )
}

@Composable
private fun MiuixAirSendTransferBriefCard(
    transfer: AirSendTransferSnapshot,
    onClick: () -> Unit
) {
    val context = LocalContext.current
    val title = transfer.files.singleOrNull()?.name
        ?: stringResource(R.string.airsend_transfer_files_count, transfer.files.size)
    val fileTypeIcon = transferFileTypeIcon(transfer)
    val status = transferStatusLabel(transfer.status)
    val statusColor = transferStatusColor(transfer.status)
    val transferred = Formatter.formatFileSize(context, transfer.transferredBytes)
    val total = Formatter.formatFileSize(context, transfer.totalBytes)
    val compactTitleStyle = MiuixTheme.textStyles.headline1.copy(
        fontSize = MiuixTheme.textStyles.headline1.fontSize * 0.86f
    )
    val compactSubtitleStyle = MiuixTheme.textStyles.subtitle.copy(
        fontSize = MiuixTheme.textStyles.subtitle.fontSize * 0.84f
    )
    val compactBodyStyle = MiuixTheme.textStyles.body1.copy(
        fontSize = MiuixTheme.textStyles.body1.fontSize * 0.84f
    )

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp),
        cornerRadius = 14.dp,
        insideMargin = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
        colors = CardDefaults.defaultColors(
            color = MiuixTheme.colorScheme.surfaceContainerHighest,
            contentColor = MiuixTheme.colorScheme.onSurfaceContainerHighest
        ),
        pressFeedbackType = PressFeedbackType.Sink,
        onClick = onClick
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = fileTypeIcon,
                contentDescription = null,
                modifier = Modifier.size(28.dp),
                tint = MiuixTheme.colorScheme.primary
            )
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = title,
                        style = compactTitleStyle,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    Text(
                        text = status,
                        style = compactSubtitleStyle,
                        color = statusColor,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(start = 12.dp)
                    )
                }

                Spacer(Modifier.size(3.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = stringResource(
                            R.string.airsend_transfer_peer_status,
                            transfer.peerAlias,
                            stringResource(R.string.airsend_transfer_bytes, transferred, total)
                        ),
                        style = compactBodyStyle,
                        color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    Text(
                        text = transfer.startedAtMs.formatHistoryTime(),
                        style = compactBodyStyle,
                        color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                        modifier = Modifier.padding(start = 12.dp)
                    )
                }

                if (!transfer.isTerminal) {
                    Spacer(Modifier.size(8.dp))
                    LinearProgressIndicator(
                        progress = if (transfer.status in setOf("queued", "preparing")) {
                            null
                        } else {
                            transfer.progress
                        }
                    )
                }
            }
        }
    }
}

private fun transferFileTypeIcon(transfer: AirSendTransferSnapshot): ImageVector {
    val file = transfer.files.singleOrNull()
    return when (
        classifyAirSendFileKind(
            name = file?.name.orEmpty(),
            mimeType = file?.mimeType.orEmpty(),
            fileCount = transfer.files.size
        )
    ) {
        AirSendFileKind.Multiple -> AppIcons.FileMultiple
        AirSendFileKind.AndroidPackage -> AppIcons.Android
        AirSendFileKind.Image -> AppIcons.FileImage
        AirSendFileKind.Video -> AppIcons.FileVideo
        AirSendFileKind.Audio -> AppIcons.FileAudio
        AirSendFileKind.Pdf -> AppIcons.FilePdf
        AirSendFileKind.Archive -> AppIcons.FileArchive
        AirSendFileKind.Presentation -> AppIcons.FilePresentation
        AirSendFileKind.Spreadsheet -> AppIcons.FileSpreadsheet
        AirSendFileKind.WordProcessing -> AppIcons.FileWordProcessing
        AirSendFileKind.Html -> AppIcons.FileHtml
        AirSendFileKind.Markdown -> AppIcons.FileMarkdown
        AirSendFileKind.StructuredData -> AppIcons.FileStructuredData
        AirSendFileKind.Code -> AppIcons.FileSourceCode
        AirSendFileKind.Text -> AppIcons.FileText
        AirSendFileKind.Document -> AppIcons.FileDocument
        AirSendFileKind.Generic -> AppIcons.FileGeneric
    }
}

@Composable
private fun MiuixAirSendTransferDetailDialog(
    transfer: AirSendTransferSnapshot,
    useBlur: Boolean,
    onAction: (AirSendRuntimeAction) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val title = transfer.files.singleOrNull()?.name
        ?: stringResource(R.string.airsend_transfer_files_count, transfer.files.size)
    val status = transferStatusLabel(transfer.status)
    val transferred = Formatter.formatFileSize(context, transfer.transferredBytes)
    val total = Formatter.formatFileSize(context, transfer.totalBytes)
    val savedPath = transfer.savedPaths.firstOrNull()
    val savedMimeType = transfer.files.firstOrNull()?.mimeType ?: "application/octet-stream"
    val isActive = !transfer.isTerminal
    val isError = transfer.status in setOf("failed", "declined")
    var showContentPreview by rememberSaveable(transfer.id) { mutableStateOf(true) }
    val dialogButtonParams = dialogButtons("airsend_transfer_detail_${transfer.id}") {
        buildList {
            when {
                transfer.direction == "incoming" &&
                    transfer.status == "awaiting_acceptance" -> {
                    add(
                        DialogButton(stringResource(R.string.airsend_decline_transfer)) {
                            onAction(AirSendRuntimeAction.DeclineTransfer(transfer.id))
                            onDismiss()
                        }
                    )
                    add(
                        DialogButton(stringResource(R.string.airsend_accept_transfer)) {
                            onAction(AirSendRuntimeAction.AcceptTransfer(transfer.id))
                            onDismiss()
                        }
                    )
                }

                isActive -> add(
                    DialogButton(stringResource(R.string.airsend_cancel_transfer)) {
                        onAction(AirSendRuntimeAction.CancelTransfer(transfer.id))
                        onDismiss()
                    }
                )

                else -> {
                    if (transfer.direction == "incoming" &&
                        transfer.status == "completed" &&
                        savedPath != null
                    ) {
                        add(
                            DialogButton(stringResource(R.string.airsend_open_received_file)) {
                                onAction(
                                    AirSendRuntimeAction.OpenReceivedFile(savedPath, savedMimeType)
                                )
                                onDismiss()
                            }
                        )
                        add(
                            DialogButton(stringResource(R.string.airsend_share_received_file)) {
                                onAction(
                                    AirSendRuntimeAction.ShareReceivedFile(savedPath, savedMimeType)
                                )
                                onDismiss()
                            }
                        )
                    }
                    if (transfer.retryable) {
                        add(
                            DialogButton(stringResource(R.string.airsend_retry_transfer)) {
                                onAction(AirSendRuntimeAction.RetryTransfer(transfer.id))
                                onDismiss()
                            }
                        )
                    }
                    add(
                        DialogButton(stringResource(R.string.airsend_delete_history_item)) {
                            onAction(AirSendRuntimeAction.DeleteHistory(transfer.id))
                            onDismiss()
                        }
                    )
                }
            }
            add(DialogButton(stringResource(R.string.close), onClick = onDismiss))
        }
    }

    InstallerMaterialExpressiveTheme(
        colorScheme = InstallerTheme.colorScheme,
        darkTheme = InstallerTheme.isDark,
        compatStatusBarColor = false
    ) {
        PositionDialog(
            modifier = Modifier.fillMaxWidth(),
            useBlur = useBlur,
            contentAnimationSpec = spring(
                dampingRatio = Spring.DampingRatioLowBouncy,
                stiffness = Spring.StiffnessMedium
            ),
            onDismissRequest = onDismiss,
            centerIcon = {
                val containerColor = if (isError) {
                    androidx.compose.material3.MaterialTheme.colorScheme.errorContainer
                } else {
                    androidx.compose.material3.MaterialTheme.colorScheme.primaryContainer
                }
                val contentColor = if (isError) {
                    androidx.compose.material3.MaterialTheme.colorScheme.onErrorContainer
                } else {
                    androidx.compose.material3.MaterialTheme.colorScheme.onPrimaryContainer
                }
                Box(
                    modifier = Modifier
                        .size(64.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(containerColor),
                    contentAlignment = Alignment.Center
                ) {
                    androidx.compose.material3.Icon(
                        imageVector = transferStatusIcon(transfer),
                        contentDescription = null,
                        modifier = Modifier.size(36.dp),
                        tint = contentColor
                    )
                }
            },
            centerTitle = {
                Row(
                    modifier = Modifier.animateContentSize(),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    androidx.compose.material3.Text(
                        text = title,
                        modifier = Modifier
                            .weight(1f, fill = false)
                            .basicMarquee(),
                        maxLines = 1
                    )
                }
            },
            centerSubtitle = {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    androidx.compose.material3.Text(
                        text = transfer.peerAlias,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.basicMarquee(),
                        maxLines = 1
                    )
                    Spacer(Modifier.size(8.dp))
                    androidx.compose.material3.Text(
                        text = "$status · ${transfer.startedAtMs.formatHistoryTime()}",
                        textAlign = TextAlign.Center
                    )
                    Spacer(Modifier.size(4.dp))
                    androidx.compose.material3.Text(
                        text = stringResource(
                            R.string.airsend_transfer_bytes,
                            transferred,
                            total
                        ),
                        textAlign = TextAlign.Center
                    )
                }
            },
            centerText = {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    SwitchWidget(
                        iconPlaceholder = false,
                        title = stringResource(R.string.airsend_show_content_preview),
                        liquidGlass = true,
                        checked = showContentPreview,
                        onCheckedChange = { showContentPreview = it }
                    )
                    AnimatedVisibility(
                        visible = showContentPreview,
                        enter = fadeIn(animationSpec = tween(110)) + expandVertically(
                            animationSpec = spring(
                                dampingRatio = Spring.DampingRatioLowBouncy,
                                stiffness = Spring.StiffnessMedium
                            ),
                            expandFrom = Alignment.Top
                        ),
                        exit = fadeOut(animationSpec = tween(80)) + shrinkVertically(
                            animationSpec = tween(110),
                            shrinkTowards = Alignment.Top
                        )
                    ) {
                        MiuixAirSendContentPreview(transfer)
                    }
                    if (isActive || !transfer.errorMessage.isNullOrBlank() || savedPath != null) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 112.dp)
                                .verticalScroll(rememberScrollState()),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            if (isActive) {
                                androidx.compose.material3.LinearProgressIndicator(
                                    progress = {
                                        if (transfer.status in setOf("queued", "preparing")) {
                                            0f
                                        } else {
                                            transfer.progress
                                        }
                                    },
                                    modifier = Modifier.fillMaxWidth()
                                )
                            }
                            transfer.errorMessage?.takeIf { it.isNotBlank() }?.let { error ->
                                androidx.compose.material3.Text(
                                    text = error,
                                    color = androidx.compose.material3.MaterialTheme.colorScheme.error
                                )
                            }
                            savedPath?.let { path ->
                                androidx.compose.material3.Text(
                                    text = path,
                                    color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            },
            centerButton = dialogInnerWidget(dialogButtonParams)
        )
    }
}

@Composable
private fun MiuixAirSendContentPreview(transfer: AirSendTransferSnapshot) {
    val context = LocalContext.current
    val preview by produceState<AirSendContentPreview?>(
        initialValue = null,
        transfer.id,
        transfer.status,
        transfer.previewPaths,
        transfer.previewText,
        transfer.savedPaths
    ) {
        value = loadAirSendContentPreview(context, transfer)
    }
    val shape = RoundedCornerShape(8.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(144.dp)
            .clip(shape)
            .background(
                androidx.compose.material3.MaterialTheme.colorScheme.surfaceContainerHigh
            ),
        contentAlignment = Alignment.Center
    ) {
        when (val content = preview) {
            null -> androidx.compose.material3.CircularProgressIndicator(
                modifier = Modifier.size(28.dp),
                strokeWidth = 3.dp
            )
            is AirSendContentPreview.Image -> Image(
                bitmap = content.bitmap.asImageBitmap(),
                contentDescription = stringResource(R.string.airsend_content_preview),
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Fit
            )
            is AirSendContentPreview.Text -> androidx.compose.material3.Text(
                text = content.text,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(12.dp),
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 13.sp,
                lineHeight = 18.sp,
                maxLines = 6,
                overflow = TextOverflow.Ellipsis
            )
            AirSendContentPreview.Unavailable -> androidx.compose.material3.Icon(
                imageVector = transferFileTypeIcon(transfer),
                contentDescription = stringResource(R.string.airsend_content_preview),
                modifier = Modifier.size(48.dp),
                tint = androidx.compose.material3.MaterialTheme.colorScheme.primary
            )
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

private fun transferStatusIcon(transfer: AirSendTransferSnapshot): ImageVector = when (transfer.status) {
    "completed" -> AppIcons.Active
    "failed", "declined" -> AppIcons.Info
    "cancelled" -> AppIcons.Close
    else -> if (transfer.direction == "incoming") AppIcons.Download else AppIcons.ArrowUp
}

@Composable
private fun transferStatusColor(status: String): Color = when (status) {
    "failed", "declined" -> MiuixTheme.colorScheme.error
    "cancelled" -> MiuixTheme.colorScheme.onSurfaceVariantActions
    else -> MiuixTheme.colorScheme.primary
}

private fun LazyListScope.airSendMiuixDevices(
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onAddManualPeer: () -> Unit
) {
    item(key = "airsend-current-target") {
        val selectedPeer = runtimeState.peers.firstOrNull {
            it.id == runtimeState.preferredTargetId
        }
        SmallTitle(stringResource(R.string.airsend_current_target))
        Card(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Column(modifier = Modifier.fillMaxWidth()) {
                BasicComponent(
                    title = selectedPeer?.alias ?: stringResource(R.string.airsend_no_target),
                    summary = selectedPeer?.deviceSubtitle()
                        ?: stringResource(R.string.airsend_no_target_desc),
                    startAction = {
                        Icon(
                            imageVector = selectedPeer?.deviceKind()?.asMiuixIcon() ?: AppIcons.DeviceOther,
                            contentDescription = null,
                            modifier = Modifier.size(28.dp),
                            tint = MiuixTheme.colorScheme.primary
                        )
                    },
                    endActions = if (selectedPeer == null) null else {
                        {
                            AirSendPeerActions(selectedPeer, runtimeState, onAction)
                        }
                    }
                )
                if (selectedPeer != null) {
                    AirSendQuickShareScanningAnimation(
                        modifier = Modifier
                            .align(Alignment.CenterHorizontally)
                            .padding(bottom = 12.dp)
                    )
                }
            }
        }
    }
    item(key = "airsend-online-devices") {
        SmallTitle(stringResource(R.string.airsend_online_devices))
        Card(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            val onlinePeers = runtimeState.peers.filter { it.online }
            if (onlinePeers.isEmpty()) {
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
                onlinePeers.forEach { peer ->
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
                        endActions = {
                            AirSendPeerActions(peer, runtimeState, onAction)
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
                onClick = { onAction(AirSendRuntimeAction.DiscoverNow) }
            )
            BasicComponent(
                title = stringResource(R.string.airsend_add_manual),
                summary = stringResource(R.string.airsend_add_manual_desc),
                startAction = {
                    Icon(
                        imageVector = AppIcons.Add,
                        contentDescription = null,
                        modifier = Modifier.size(28.dp),
                        tint = MiuixTheme.colorScheme.primary
                    )
                },
                onClick = onAddManualPeer
            )
        }
    }
    val offlineManualPeers = runtimeState.peers.filter { it.manual && !it.online }
    if (offlineManualPeers.isNotEmpty()) {
        item(key = "airsend-manual-devices") {
            SmallTitle(stringResource(R.string.airsend_saved_devices))
            Card(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
                offlineManualPeers.forEach { peer ->
                    BasicComponent(
                        title = peer.alias,
                        summary = peer.address,
                        startAction = {
                            Icon(
                                imageVector = peer.deviceKind().asMiuixIcon(),
                                contentDescription = null,
                                modifier = Modifier.size(28.dp),
                                tint = MiuixTheme.colorScheme.onSurfaceVariantActions
                            )
                        },
                        endActions = {
                            IconButton(
                                onClick = {
                                    onAction(AirSendRuntimeAction.RemoveManualPeer(peer.id))
                                }
                            ) {
                                Icon(
                                    imageVector = AppIcons.Close,
                                    contentDescription = stringResource(R.string.airsend_remove_manual_peer),
                                    tint = MiuixTheme.colorScheme.error
                                )
                            }
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun AirSendQuickShareScanningAnimation(modifier: Modifier = Modifier) {
    val composition by rememberLottieComposition(
        LottieCompositionSpec.RawRes(R.raw.quick_share_pulsing_scanning_icon)
    )
    val primary = MiuixTheme.colorScheme.primary.toArgb()
    val primaryContainer = MiuixTheme.colorScheme.primaryContainer.toArgb()
    val dynamicProperties = rememberLottieDynamicProperties(
        rememberLottieDynamicProperty(
            LottieProperty.COLOR,
            primary,
            ".icon_outline",
            "**",
            "Fill 1"
        ),
        rememberLottieDynamicProperty(
            LottieProperty.STROKE_COLOR,
            primary,
            ".icon_outline",
            "**",
            "Stroke 1"
        ),
        rememberLottieDynamicProperty(
            LottieProperty.COLOR,
            primaryContainer,
            ".icon_background",
            "**",
            "Fill 1"
        ),
        rememberLottieDynamicProperty(
            LottieProperty.COLOR,
            primary,
            "506531",
            "**",
            "Fill 1"
        ),
        rememberLottieDynamicProperty(
            LottieProperty.TRANSFORM_SCALE,
            ScaleXY(0.875f, 0.875f),
            ".icon_outline"
        ),
        rememberLottieDynamicProperty(
            LottieProperty.TRANSFORM_SCALE,
            ScaleXY(0.875f, 0.875f),
            ".FFFFFF 2"
        ),
        rememberLottieDynamicProperty(
            LottieProperty.TRANSFORM_SCALE,
            ScaleXY(0.875f, 0.875f),
            ".icon_background"
        )
    )

    LottieAnimation(
        composition = composition,
        iterations = LottieConstants.IterateForever,
        dynamicProperties = dynamicProperties,
        modifier = modifier.size(128.dp)
    )
}

@Composable
private fun MiuixAirSendManualPeerDialog(
    onDismiss: () -> Unit,
    onConfirm: (String, String, Int, String?) -> Unit
) {
    var alias by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("53317") }
    var fingerprint by remember { mutableStateOf("") }
    val parsedPort = port.toIntOrNull()
    val valid = address.isNotBlank() && parsedPort in 1..65535

    WindowDialog(
        show = true,
        onDismissRequest = onDismiss,
        title = stringResource(R.string.airsend_add_manual),
        content = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                TextField(
                    value = alias,
                    onValueChange = { alias = it },
                    label = stringResource(R.string.airsend_manual_alias),
                    useLabelAsPlaceholder = true,
                    singleLine = true
                )
                TextField(
                    value = address,
                    onValueChange = { address = it },
                    label = stringResource(R.string.airsend_manual_address),
                    useLabelAsPlaceholder = true,
                    singleLine = true
                )
                TextField(
                    value = port,
                    onValueChange = { value -> port = value.filter(Char::isDigit).take(5) },
                    label = stringResource(R.string.airsend_manual_port),
                    useLabelAsPlaceholder = true,
                    singleLine = true
                )
                TextField(
                    value = fingerprint,
                    onValueChange = { fingerprint = it },
                    label = stringResource(R.string.airsend_manual_fingerprint_optional),
                    useLabelAsPlaceholder = true,
                    singleLine = true
                )
                Spacer(Modifier.height(4.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    TextButton(
                        modifier = Modifier.weight(1f),
                        text = stringResource(R.string.cancel),
                        onClick = onDismiss
                    )
                    TextButton(
                        modifier = Modifier.weight(1f),
                        text = stringResource(R.string.confirm),
                        enabled = valid,
                        colors = ButtonDefaults.textButtonColorsPrimary(),
                        onClick = {
                            onConfirm(
                                alias.trim(),
                                address.trim(),
                                checkNotNull(parsedPort),
                                fingerprint.trim().ifEmpty { null }
                            )
                        }
                    )
                }
            }
        }
    )
}

@Composable
private fun AirSendPeerActions(
    peer: com.rosan.installer.ui.page.airsend.runtime.AirSendPeer,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit
) {
    val fingerprint = peer.fingerprint.trim().lowercase()
    val trusted = fingerprint.isNotEmpty() && fingerprint in runtimeState.trustedPeerFingerprints
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(
            enabled = fingerprint.isNotEmpty(),
            onClick = {
                onAction(AirSendRuntimeAction.SetPeerTrusted(fingerprint, !trusted))
            }
        ) {
            Icon(
                imageVector = AppIcons.DisableAdbVerify,
                contentDescription = stringResource(
                    if (trusted) R.string.airsend_revoke_trust else R.string.airsend_trust_device
                ),
                modifier = Modifier.size(22.dp),
                tint = if (trusted) {
                    MiuixTheme.colorScheme.primary
                } else {
                    MiuixTheme.colorScheme.onSurfaceVariantActions
                }
            )
        }
        if (peer.selected) {
            Icon(
                imageVector = AppIcons.Active,
                contentDescription = stringResource(R.string.airsend_current_target),
                modifier = Modifier.size(22.dp),
                tint = MiuixTheme.colorScheme.primary
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
    onPickFiles: (() -> Unit)?,
    onPickDownloadLocation: (() -> Unit)?,
    onPickMediaLocation: (() -> Unit)?,
    onPickTarget: (() -> Unit)?,
    onExportLogs: (() -> Unit)?,
    onClearLogs: (() -> Unit)?,
    onRequestPermissions: (() -> Unit)?,
    onShowTrustedDevices: (() -> Unit)?,
    onShowDiagnostics: (() -> Unit)?
) {
    SmallTitle(stringResource(section.titleRes))
    Card(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
        section.items.forEach { item ->
            MiuixAirSendContentItem(
                item,
                navigator,
                runtimeState,
                onAction,
                onPickFiles,
                onPickDownloadLocation,
                onPickMediaLocation,
                onPickTarget,
                onExportLogs,
                onClearLogs,
                onRequestPermissions,
                onShowTrustedDevices,
                onShowDiagnostics
            )
        }
    }
}

@Composable
private fun MiuixAirSendContentItem(
    item: AirSendContentItem,
    navigator: Navigator,
    runtimeState: AirSendRuntimeState,
    onAction: (AirSendRuntimeAction) -> Unit,
    onPickFiles: (() -> Unit)?,
    onPickDownloadLocation: (() -> Unit)?,
    onPickMediaLocation: (() -> Unit)?,
    onPickTarget: (() -> Unit)?,
    onExportLogs: (() -> Unit)?,
    onClearLogs: (() -> Unit)?,
    onRequestPermissions: (() -> Unit)?,
    onShowTrustedDevices: (() -> Unit)?,
    onShowDiagnostics: (() -> Unit)?
) {
    val title = stringResource(item.titleRes)
    val description = miuixAirSendDescription(item, runtimeState)
    val target = item.navigationTarget

    when {
        item.id == AirSendContentId.BackgroundService -> {
            MiuixSwitchWidget(
                title = title,
                description = description,
                checked = runtimeState.backgroundServiceRunning,
                onCheckedChange = {
                    onAction(
                        if (it) AirSendRuntimeAction.StartService else AirSendRuntimeAction.StopService
                    )
                }
            )
        }
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
        item.id == AirSendContentId.RestartWholeService -> {
            BasicComponent(
                title = title,
                summary = description,
                onClick = { onAction(AirSendRuntimeAction.RestartWholeService) }
            )
        }
        item.id == AirSendContentId.DiscoverAgain || item.id == AirSendContentId.NetworkDiscovery -> {
            BasicComponent(
                title = title,
                summary = description,
                onClick = { onAction(AirSendRuntimeAction.DiscoverNow) }
            )
        }
        item.id == AirSendContentId.SelectedFiles -> {
            BasicComponent(
                title = stringResource(R.string.airsend_pick_files),
                summary = description,
                enabled = runtimeState.daemonReachable && runtimeState.preferredTargetId != null,
                onClick = onPickFiles
            )
        }
        item.id == AirSendContentId.NearbyTargets -> {
            BasicComponent(
                title = title,
                summary = description,
                enabled = runtimeState.daemonReachable && onPickTarget != null,
                onClick = onPickTarget
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
        item.id == AirSendContentId.ClipboardSync -> {
            MiuixSwitchWidget(
                title = title,
                description = description,
                checked = runtimeState.clipboardSyncEnabled,
                enabled = runtimeState.daemonReachable,
                onCheckedChange = {
                    onAction(AirSendRuntimeAction.SetClipboardSyncEnabled(it))
                }
            )
        }
        item.id == AirSendContentId.ScreenshotSync -> {
            MiuixSwitchWidget(
                title = title,
                description = description,
                checked = runtimeState.screenshotSyncEnabled,
                enabled = runtimeState.daemonReachable,
                onCheckedChange = {
                    onAction(AirSendRuntimeAction.SetScreenshotSyncEnabled(it))
                }
            )
        }
        item.id == AirSendContentId.ServiceNotification -> {
            MiuixSwitchWidget(
                title = title,
                description = description,
                enabled = runtimeState.canDisableServiceNotification,
                checked = runtimeState.serviceNotificationEnabled,
                onCheckedChange = {
                    onAction(AirSendRuntimeAction.SetServiceNotificationEnabled(it))
                }
            )
        }
        item.id == AirSendContentId.HistoryRetention -> {
            val limits = listOf(10, 30, 50, 100)
            val entries = limits.map { limit ->
                DropdownItem(
                    title = stringResource(R.string.airsend_history_limit_count, limit)
                )
            }
            WindowSpinnerPreference(
                title = title,
                summary = description,
                items = entries,
                selectedIndex = limits.indexOf(runtimeState.historyLimitPerDirection)
                    .takeIf { it >= 0 } ?: 1,
                enabled = runtimeState.daemonReachable,
                onSelectedIndexChange = { index ->
                    limits.getOrNull(index)?.let { limit ->
                        onAction(AirSendRuntimeAction.SetHistoryLimitPerDirection(limit))
                    }
                }
            )
        }
        item.id == AirSendContentId.ReceiveRequests -> {
            val pendingCount = runtimeState.transfers.count {
                it.direction == "incoming" && it.status == "awaiting_acceptance"
            }
            BasicComponent(
                title = title,
                summary = stringResource(R.string.airsend_pending_receive_count, pendingCount)
            )
        }
        item.id == AirSendContentId.QuickSave -> {
            MiuixSwitchWidget(
                title = title,
                description = description,
                checked = runtimeState.receivePolicy == "trusted_only",
                enabled = runtimeState.daemonReachable,
                onCheckedChange = {
                    onAction(
                        AirSendRuntimeAction.SetReceivePolicy(
                            if (it) "trusted_only" else "ask"
                        )
                    )
                }
            )
        }
        item.id == AirSendContentId.ReceiveSwitch -> {
            MiuixSwitchWidget(
                title = title,
                description = description,
                checked = runtimeState.receivePolicy != "off",
                enabled = runtimeState.daemonReachable,
                onCheckedChange = {
                    onAction(
                        AirSendRuntimeAction.SetReceivePolicy(if (it) "ask" else "off")
                    )
                }
            )
        }
        item.id == AirSendContentId.SaveLocation -> {
            BasicComponent(
                title = stringResource(R.string.airsend_download_destination),
                summary = runtimeState.downloadDestination,
                enabled = runtimeState.daemonReachable && onPickDownloadLocation != null,
                onClick = onPickDownloadLocation
            )
            BasicComponent(
                title = stringResource(R.string.airsend_media_destination),
                summary = runtimeState.mediaDestination,
                enabled = runtimeState.daemonReachable && onPickMediaLocation != null,
                onClick = onPickMediaLocation
            )
        }
        item.id == AirSendContentId.TrustedDevices -> {
            BasicComponent(
                title = title,
                summary = stringResource(
                    R.string.airsend_trusted_device_count,
                    runtimeState.trustedPeerFingerprints.size
                ),
                onClick = onShowTrustedDevices
            )
        }
        item.id == AirSendContentId.Transport -> {
            val entries = listOf(
                DropdownItem(title = stringResource(R.string.airsend_transport_https)),
                DropdownItem(title = stringResource(R.string.airsend_transport_http_compatibility))
            )
            WindowSpinnerPreference(
                title = title,
                summary = description,
                items = entries,
                selectedIndex = if (runtimeState.transportPreference == "https") 0 else 1,
                enabled = runtimeState.daemonReachable,
                onSelectedIndexChange = { index ->
                    onAction(
                        AirSendRuntimeAction.SetTransportPreference(
                            if (index == 0) "https" else "http_compatibility"
                        )
                    )
                }
            )
        }
        item.id == AirSendContentId.RuntimeDiagnostics -> {
            BasicComponent(
                title = title,
                summary = description,
                onClick = onShowDiagnostics
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
            BasicComponent(
                title = title,
                summary = description,
                enabled = runtimeState.daemonReachable && onExportLogs != null,
                onClick = onExportLogs
            )
            BasicComponent(
                title = stringResource(R.string.airsend_clear_logs),
                summary = stringResource(R.string.airsend_clear_logs_desc),
                enabled = runtimeState.daemonReachable && onClearLogs != null,
                onClick = onClearLogs
            )
        }
        item.id == AirSendContentId.PermissionCheck -> {
            BasicComponent(
                title = title,
                summary = description,
                enabled = onRequestPermissions != null,
                onClick = onRequestPermissions
            )
        }
        item.id == AirSendContentId.OpenPermissions -> {
            MiuixNavigationItemWidget(
                icon = item.icon.asMiuixIcon(),
                title = title,
                description = description,
                onClick = { navigator.push(Route.Priv) }
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
        else -> {
            BasicComponent(
                title = title,
                summary = description
            )
        }
    }
}

@Composable
internal fun MiuixAirSendRuntimeEvents(
    viewModel: AirSendRuntimeViewModel,
    snackbarHostState: SnackbarHostState
) {
    val resources = LocalResources.current
    LaunchedEffect(viewModel, snackbarHostState) {
        viewModel.events.collect { event ->
            val message = when (event) {
                is AirSendRuntimeEvent.ShowMessage -> resources.getString(event.messageRes)
                is AirSendRuntimeEvent.ShowRawMessage -> event.message
            }
            snackbarHostState.showSnackbar(message)
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
            if (runtimeState.backgroundServiceRunning) R.string.airsend_state_running else R.string.airsend_state_stopped
        )
        AirSendContentId.Daemon -> if (runtimeState.daemonReachable) {
            stringResource(
                R.string.airsend_daemon_version_reachable,
                runtimeState.daemonVersion ?: "?"
            )
        } else {
            runtimeState.lastError?.let { stringResource(R.string.airsend_daemon_error, it) }
                ?: stringResource(R.string.airsend_state_unreachable)
        }
        AirSendContentId.LspModule -> when {
            !runtimeState.rootAvailable -> stringResource(R.string.airsend_no_root_manual_clipboard)
            !runtimeState.moduleInstalled -> stringResource(R.string.airsend_module_not_installed)
            !runtimeState.moduleEnabled -> stringResource(R.string.airsend_module_disabled)
            !runtimeState.versionsMatch -> stringResource(R.string.airsend_module_version_mismatch)
            runtimeState.reverseClipboardIpcReady -> stringResource(
                R.string.airsend_lsp_ready,
                runtimeState.moduleVersion ?: "?"
            )
            else -> stringResource(R.string.airsend_lsp_reload_required)
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
            "${stringResource(R.string.notification_settings)}: $notification · ${stringResource(R.string.airsend_permission_media)}: $storage"
        }
        AirSendContentId.NearbyTargets -> stringResource(
            R.string.airsend_peer_count,
            runtimeState.peers.count { it.online }
        )
        AirSendContentId.SavedDevices -> stringResource(R.string.airsend_peer_count, runtimeState.peers.size)
        AirSendContentId.SelectedFiles,
        AirSendContentId.SendClipboard,
        AirSendContentId.ClipboardPush -> runtimeState.peers
            .firstOrNull { it.id == runtimeState.preferredTargetId }
            ?.let { stringResource(R.string.airsend_send_to_peer, it.alias) }
            ?: stringResource(R.string.airsend_select_target_before_sending)
        AirSendContentId.ClipboardSync -> when {
            runtimeState.clipboardSyncEnabled -> stringResource(R.string.airsend_sync_enabled_desc)
            else -> stringResource(R.string.airsend_sync_disabled_desc)
        }
        AirSendContentId.ScreenshotSync -> if (runtimeState.screenshotSyncEnabled) {
            stringResource(R.string.airsend_sync_enabled_desc)
        } else stringResource(R.string.airsend_sync_disabled_desc)
        AirSendContentId.ServiceNotification -> when {
            !runtimeState.canDisableServiceNotification -> stringResource(
                R.string.airsend_service_notification_required_desc
            )
            runtimeState.serviceNotificationEnabled -> stringResource(
                R.string.airsend_service_notification_enabled_desc
            )
            else -> stringResource(R.string.airsend_service_notification_disabled_desc)
        }
        AirSendContentId.HistoryRetention -> stringResource(
            R.string.airsend_history_limit_desc,
            runtimeState.historyLimitPerDirection
        )
        AirSendContentId.Transport -> stringResource(
            if (runtimeState.transportPreference == "https") {
                R.string.airsend_transport_https
            } else {
                R.string.airsend_transport_http_compatibility
            }
        )
        AirSendContentId.RuntimeDiagnostics -> stringResource(
            R.string.airsend_runtime_diagnostics_summary,
            runtimeState.healthWarnings.size
        )
        else -> stringResource(item.descriptionRes)
    }

@Composable
private fun miuixAirSendNoDeviceDescription(runtimeState: AirSendRuntimeState): String =
    if (!runtimeState.daemonReachable && runtimeState.lastError != null) {
        stringResource(R.string.airsend_daemon_error, runtimeState.lastError)
    } else {
        stringResource(R.string.airsend_no_devices_desc)
    }

private fun airSendRuntimePermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 33) {
    arrayOf(
        Manifest.permission.POST_NOTIFICATIONS,
        Manifest.permission.READ_MEDIA_IMAGES,
        Manifest.permission.READ_MEDIA_VIDEO
    )
} else {
    arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
}

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
    backdrop: LayerBackdrop,
    mode: FloatingBottomBarMode
) {
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
            backdrop = backdrop,
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
