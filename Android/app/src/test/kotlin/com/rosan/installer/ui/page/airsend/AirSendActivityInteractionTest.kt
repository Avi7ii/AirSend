// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AirSendActivityInteractionTest {
    @Test
    fun materialActivityPageUsesSwipePagerAndAnimatedTabSelection() {
        val source = readSource(
            "src/main/java/com/rosan/installer/ui/page/main/airsend/AirSendMaterialPages.kt"
        )

        assertTrue(source.contains("HorizontalPager("))
        assertTrue(source.contains("rememberPagerState("))
        assertTrue(source.contains("animateScrollToPage("))
        assertTrue(source.contains("selectedIndex = selectedTab"))
        assertTrue(source.contains("selectedTab = page"))
        assertTrue(source.contains("LaunchedEffect(pagerState.currentPage)"))
        assertTrue(source.contains("selectedTab = pagerState.currentPage"))
        assertTrue(source.contains("rememberUpdatedState(selectedIndex)"))
        assertTrue(source.contains("selectedIndexProvider"))
        assertTrue(source.contains("selectedIndex = selectedIndexProvider"))
        assertFalse(source.contains("selectedIndex = { selectedIndex }"))
        assertFalse(source.contains("modifier = Modifier.clickable("))
        assertTrue(source.contains("iconColor = MaterialTheme.colorScheme.primary"))
        assertFalse(source.contains("MaterialTheme.colorScheme.tertiary"))
    }

    @Test
    fun miuixActivityPageUsesSwipePagerAndAnimatedTabSelection() {
        val source = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/airsend/AirSendMiuixPages.kt"
        )

        assertTrue(source.contains("HorizontalPager("))
        assertTrue(source.contains("rememberPagerState("))
        assertTrue(source.contains("animateScrollToPage("))
        assertTrue(source.contains("selectedIndex = selectedTab"))
        assertTrue(source.contains("selectedTab = page"))
        assertTrue(source.contains("LaunchedEffect(pagerState.currentPage)"))
        assertTrue(source.contains("selectedTab = pagerState.currentPage"))
        assertTrue(source.contains("rememberUpdatedState(selectedIndex)"))
        assertTrue(source.contains("selectedIndexProvider"))
        assertTrue(source.contains("selectedIndex = selectedIndexProvider"))
        assertFalse(source.contains("selectedIndex = { selectedIndex }"))
        assertFalse(source.contains("modifier = Modifier.clickable("))
        assertTrue(source.contains(".layerBackdrop(activityTabBackdrop)"))
        assertTrue(source.contains("backdrop = activityTabBackdrop"))
        assertTrue(source.contains("mode = floatingBottomBarMode"))
        assertFalse(source.contains("mode = FloatingBottomBarMode.None"))
        assertFalse(source.contains("Modifier.layerBackdrop(tabBackdrop)"))
        assertTrue(source.contains("tint = MiuixTheme.colorScheme.primary"))
        assertFalse(source.contains("MiuixTheme.colorScheme.tertiaryContainer"))
    }

    @Test
    fun miuixRuntimeEventsAreCollectedOnceAboveThePagePager() {
        val pages = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/airsend/AirSendMiuixPages.kt"
        )
        val settings = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/MiuixSettingsPage.kt"
        )

        assertEquals(
            1,
            Regex(Regex.escape("MiuixAirSendRuntimeEvents(")).findAll(pages).count()
        )
        assertTrue(settings.contains("MiuixAirSendRuntimeEvents(airSendRuntimeViewModel, snackbarHostState)"))
    }

    @Test
    fun miuixHistoryKeepsCardsInsideScrollableRefreshableContainer() {
        val source = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/airsend/AirSendMiuixPages.kt"
        )

        assertTrue(source.contains("activity-history-container-"))
        assertTrue(source.contains("private fun MiuixAirSendHistoryContainer("))
        assertFalse(source.contains(".squircleBorder("))
        assertTrue(source.contains("insideMargin = PaddingValues(horizontal = 8.dp, vertical = 10.dp)"))
        assertFalse(source.contains(".height(330.dp)"))
        assertTrue(source.contains("LocalWindowInfo.current.containerSize.height * 9 / 20"))
        assertTrue(source.contains(".heightIn(max = historyContainerMaxHeight)"))
        assertTrue(source.contains("rememberScrollBarAdapter(historyScrollState)"))
        assertTrue(source.contains("overscrollEffect = null"))
        assertFalse(source.contains("historyOverscrollEffect"))
        assertFalse(source.contains("MiuixOverscrollEffect("))
        assertTrue(source.contains("VerticalScrollBar("))
        assertTrue(source.contains("alwaysVisible = true"))
        assertTrue(source.contains("cornerRadius = 2.5.dp"))
        assertTrue(source.contains("key(direction) {"))
        assertTrue(source.contains("nestedScroll(historyBoundaryConnection)"))
        assertTrue(source.contains("val stopAtTop = available.y > 0f"))
        assertTrue(source.contains("source == NestedScrollSource.UserInput || stopAtTop"))
        assertTrue(source.contains("): Velocity = if (available.y > 0f)"))
        assertFalse(source.contains("change.positionChange()"))
        assertFalse(source.contains("change.consume()"))
        assertTrue(source.contains("val pageScrollState = rememberLazyListState()"))
        assertTrue(source.contains("state = pageScrollState"))
        assertTrue(source.contains("val historyScrollIsolation = remember { mutableStateOf(false) }"))
        assertTrue(source.contains("if (historyScrollIsolation.value)"))
        assertTrue(source.contains(".nestedScroll(activityScrollConnection)"))
        assertTrue(source.contains("historyScrollIsolation.value = active"))
        assertFalse(source.contains("pageScrollState.scroll(MutatePriority.PreventUserInput)"))
        assertTrue(source.contains("gestureReleaseJob = gestureScope.launch"))
        assertTrue(source.contains("withFrameNanos { }"))
        assertTrue(source.contains("while (historyScrollState.isScrollInProgress)"))
        assertFalse(source.contains("HISTORY_SCROLL_IDLE_CHECK_MS"))
        assertFalse(source.contains("userScrollEnabled = !historyGestureActive"))
        assertTrue(source.contains("pass = PointerEventPass.Initial"))
        assertTrue(source.contains("awaitPointerEvent(pass = PointerEventPass.Final)"))
        assertTrue(source.contains("event.changes.none { it.pressed }"))
        assertFalse(source.contains("waitForUpOrCancellation()"))
        assertFalse(source.contains("change.consume()"))
        assertTrue(source.contains("PullToRefresh("))
        val historyContainer = source
            .substringAfter("private fun MiuixAirSendHistoryContainer(")
            .substringBefore("private fun MiuixAirSendTransferBriefCard(")
        assertTrue(
            historyContainer.indexOf("nestedScroll(historyBoundaryConnection)") <
                historyContainer.indexOf("PullToRefresh(")
        )
        assertTrue(source.contains("onRefresh = { onAction(AirSendRuntimeAction.Refresh) }"))
        assertTrue(source.contains("transfers.forEach { transfer ->"))
        assertTrue(source.contains("MiuixAirSendTransferBriefCard("))
        assertTrue(source.contains("private fun MiuixAirSendTransferBriefCard("))
        assertTrue(source.contains("private fun transferFileTypeIcon("))
        assertTrue(source.contains("classifyAirSendFileKind("))
        assertTrue(source.contains("AirSendFileKind.Image -> AppIcons.FileImage"))
        assertTrue(source.contains("AirSendFileKind.Video -> AppIcons.FileVideo"))
        assertTrue(source.contains("AirSendFileKind.Audio -> AppIcons.FileAudio"))
        assertTrue(source.contains("AppIcons.FileArchive"))
        assertTrue(source.contains("AppIcons.FileGeneric"))
        val appIcons = readSource("src/main/java/com/rosan/installer/ui/icons/AppIcons.kt")
        assertTrue(appIcons.contains("val FileVideo = Icons.TwoTone.VideoFile"))
        assertTrue(appIcons.contains("val FilePresentation = Icons.TwoTone.CoPresent"))
        assertTrue(source.contains("modifier = Modifier.size(28.dp)"))
        assertTrue(source.contains("tint = MiuixTheme.colorScheme.primary"))
        assertTrue(source.contains(".padding(horizontal = 4.dp)"))
        assertTrue(source.contains("cornerRadius = 14.dp"))
        assertTrue(source.contains("insideMargin = PaddingValues(horizontal = 14.dp, vertical = 12.dp)"))
        assertTrue(source.contains("fontSize = MiuixTheme.textStyles.headline1.fontSize * 0.86f"))
        assertTrue(source.contains("fontSize = MiuixTheme.textStyles.subtitle.fontSize * 0.84f"))
        assertTrue(source.contains("fontSize = MiuixTheme.textStyles.body1.fontSize * 0.84f"))
        assertTrue(source.contains("color = MiuixTheme.colorScheme.surfaceContainerHighest"))
        assertTrue(source.contains("contentColor = MiuixTheme.colorScheme.onSurfaceContainerHighest"))
        assertTrue(source.contains("pressFeedbackType = PressFeedbackType.Sink"))
        assertTrue(source.contains("private fun MiuixAirSendTransferDetailDialog("))
        assertTrue(source.contains("InstallerMaterialExpressiveTheme("))
        assertTrue(source.contains("colorScheme = InstallerTheme.colorScheme"))
        assertTrue(source.contains("darkTheme = InstallerTheme.isDark"))
        assertTrue(source.contains("PositionDialog("))
        assertTrue(source.contains("useBlur = enableBlur"))
        assertTrue(source.contains("useBlur = useBlur"))
        assertTrue(source.contains("centerTitle = {"))
        assertTrue(source.contains("centerIcon = {"))
        assertTrue(source.contains("centerSubtitle = {"))
        assertTrue(source.contains("centerText = {"))
        assertTrue(source.contains("private fun MiuixAirSendContentPreview("))
        assertTrue(source.contains("loadAirSendContentPreview(context, transfer)"))
        assertTrue(source.contains(".height(144.dp)"))
        assertTrue(source.contains("contentScale = ContentScale.Fit"))
        assertTrue(source.contains("SwitchWidget("))
        assertTrue(source.contains("R.string.airsend_show_content_preview"))
        assertTrue(source.contains("liquidGlass = true"))
        assertTrue(source.contains("visible = showContentPreview"))
        assertTrue(source.contains("fadeIn(animationSpec = tween(110)) + expandVertically("))
        assertTrue(source.contains("fadeOut(animationSpec = tween(80)) + shrinkVertically("))
        assertTrue(source.contains("dampingRatio = Spring.DampingRatioLowBouncy"))
        assertTrue(source.contains("stiffness = Spring.StiffnessMedium"))
        assertTrue(source.contains("contentAnimationSpec = spring("))
        assertTrue(source.contains("dialogButtons(\"airsend_transfer_detail_"))
        assertTrue(source.contains("centerButton = dialogInnerWidget(dialogButtonParams)"))
        assertFalse(source.contains("MiuixAirSendTransferDetailCard("))
        assertFalse(source.contains("WindowBottomSheet("))
        assertFalse(source.contains("HorizontalDivider("))
    }

    @Test
    fun contentPreviewReadsStoredPathsAndSupportsLegacyScreenshotFallback() {
        val source = readSource(
            "src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendContentPreview.kt"
        )

        assertTrue(source.contains("transfer.previewPaths + transfer.savedPaths"))
        assertTrue(source.contains("readDirect(path, maxBytes)"))
        assertTrue(source.contains("readAsRoot(context, path, maxBytes)"))
        assertTrue(source.contains("/sdcard/Pictures/Screenshots"))
        assertTrue(source.contains("/sdcard/Pictures/AirSend"))
        assertTrue(source.contains("MAX_TEXT_PREVIEW_BYTES"))
        assertTrue(source.contains("MAX_IMAGE_PREVIEW_BYTES"))
    }

    @Test
    fun airSendSwitchesReuseTheLiquidGlassToggleComponent() {
        val miuixWidgets = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/widgets/MiuixBaseWidget.kt"
        )
        val materialSwitch = readSource(
            "src/main/java/com/rosan/installer/ui/page/main/widget/setting/SwitchWidget.kt"
        )
        val liquidToggle = readSource(
            "src/main/java/com/rosan/installer/ui/library/LiquidToggle.kt"
        )
        val miuixApplyPage = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/config/apply/MiuixApplyPage.kt"
        )
        val miuixAboutPage = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/settings/preferred/about/MiuixAboutPage.kt"
        )

        assertTrue(miuixWidgets.contains("LiquidToggle("))
        assertTrue(miuixWidgets.contains("fun MiuixLiquidSwitch("))
        assertTrue(miuixWidgets.contains("rememberCanvasBackdrop"))
        assertTrue(miuixApplyPage.contains("MiuixLiquidSwitch("))
        assertTrue(miuixAboutPage.contains("MiuixLiquidSwitch("))
        assertFalse(miuixApplyPage.contains("top.yukonga.miuix.kmp.basic.Switch"))
        assertFalse(miuixAboutPage.contains("top.yukonga.miuix.kmp.basic.Switch"))
        assertTrue(materialSwitch.contains("liquidGlass: Boolean = false"))
        assertTrue(materialSwitch.contains("if (liquidGlass)"))
        assertTrue(liquidToggle.contains("Adapted from AndroidLiquidGlass' LiquidToggle example"))
        assertTrue(liquidToggle.contains("rememberCombinedBackdrop(backdrop, trackBackdrop)"))
        assertTrue(liquidToggle.contains("pressedScale = 1.7f"))
        assertTrue(liquidToggle.contains("private val ToggleTrackWidth = 60.dp"))
        assertTrue(liquidToggle.contains("private val ToggleDragWidth"))
        assertTrue(liquidToggle.contains(".background(thumbColor, CircleShape)"))
        assertTrue(liquidToggle.contains(".layerBackdrop(trackBackdrop)"))
        assertTrue(liquidToggle.contains("private val ToggleGlassOvershoot = 6.dp"))
        assertTrue(liquidToggle.contains("LaunchedEffect(selected)"))
        assertFalse(liquidToggle.contains("ToggleContainerWidth"))
        assertFalse(liquidToggle.contains("LocalViewConfiguration"))
        assertTrue(liquidToggle.contains(".then(dampedDragAnimation.modifier)"))
        assertTrue(liquidToggle.contains("launchGlassOvershoot(target)"))
        assertTrue(liquidToggle.contains(") + glassOvershoot.value"))
        assertTrue(liquidToggle.contains("delay(45)"))
        assertTrue(liquidToggle.contains("dampingRatio = 0.82f"))
        assertTrue(liquidToggle.contains("blur(0.2.dp.toPx())"))
        assertTrue(liquidToggle.contains("alpha = lerp(0.04f, 0.58f"))
        assertFalse(liquidToggle.contains("onDrawBackdrop = { drawBackdrop ->"))
        assertTrue(liquidToggle.contains("refractionAmount = lerp(2f, 11f, progress).dp.toPx()"))
        assertTrue(liquidToggle.contains("Highlight.GlassStrokeBig"))
        assertFalse(liquidToggle.contains("LocalLiquidGlassBackdrop"))
    }

    @Test
    fun miuixHomeStatusAndPermissionRefreshRemainStable() {
        val pages = readSource(
            "src/main/java/com/rosan/installer/ui/page/miuix/airsend/AirSendMiuixPages.kt"
        )
        val actions = readSource(
            "src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeAction.kt"
        )
        val viewModel = readSource(
            "src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeViewModel.kt"
        )

        assertTrue(pages.contains("fontWeight = FontWeight.Bold"))
        assertTrue(pages.contains("permissionRequestInFlight"))
        assertEquals(2, Regex("AirSendRuntimeAction.RefreshSilently").findAll(pages).count())
        assertTrue(actions.contains("data object RefreshSilently"))
        assertTrue(viewModel.contains("AirSendRuntimeAction.RefreshSilently"))
        assertTrue(viewModel.contains("repository.refresh(showIndicator = false)"))
    }

    @Test
    fun miuixRefreshKeepsContentInteractive() {
        val source = Files.readString(
            appDir().resolve(
                "../third_party/miuix/miuix-ui/src/commonMain/kotlin/" +
                    "top/yukonga/miuix/kmp/basic/PullToRefresh.kt"
            ).normalize()
        )

        assertTrue(source.contains("Keep the content interactive while the refresh indicator is visible."))
        assertTrue(source.contains("return Velocity.Zero"))
        assertFalse(source.contains("If the refresh is in progress, consume all scroll events."))
    }

    private fun readSource(relativePath: String): String =
        Files.readString(appDir().resolve(relativePath))

    private fun appDir(): Path {
        val userDir = Paths.get(System.getProperty("user.dir"))
        return if (Files.exists(userDir.resolve("src/main/res/values/strings.xml"))) {
            userDir
        } else {
            userDir.resolve("app")
        }
    }
}
