import AppKit
import AirSendConsoleSupport
import QuartzCore
import SwiftUI

private typealias AirSendState<Value> = SwiftUI.State<Value>

private enum AirSendSettingsMetrics {
    static let cardCornerRadius: CGFloat = 12
    static let cardContentInset: CGFloat = 14
    static let transferRowSpacing: CGFloat = 8
    static let transferViewportHeightRatio: CGFloat = 0.40
    static let transferViewportMinimumHeight: CGFloat = 180
    static let transferViewportMaximumHeight: CGFloat = 320
    static let transferViewportMinimumCap: CGFloat = 240
    static let transferEstimatedRowHeight: CGFloat = 78
    static let actionCornerRadius: CGFloat = 7
    static let pageEntranceOffset: CGFloat = 14
    static let pageEntranceDuration: TimeInterval = 0.78
    static let pageEntranceBounce = 0.10
    static let pageEntranceMaximumBlur: CGFloat = 6
    static let pageEntranceRevealFraction: CGFloat = 0.38
    static let pageEntranceSurfaceOffset: CGFloat = 8
    static let pageEntranceSurfaceDuration: TimeInterval = 0.72
    static let pageEntranceSurfaceBounce = 0.05
    static let pageEntranceStaggerMilliseconds = 78
    static let pageEntranceMaximumStaggerIndex = 28
    static let pageSectionSlotCount = 11
    static let pageTransitionTriggerDuration: TimeInterval = 0.001
}

private enum AirSendSettingsCategory: String, CaseIterable, Identifiable {
    case status
    case devices
    case transfers
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status:
            return "Status"
        case .devices:
            return "Devices"
        case .transfers:
            return "Transfers"
        case .settings:
            return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .status:
            return "Runtime health, automation, and quick actions."
        case .devices:
            return "Current target, nearby devices, and discovery."
        case .transfers:
            return "Send and receive activity, progress, and history."
        case .settings:
            return "Automation, receiving, network, diagnostics, and identity."
        }
    }

    var symbol: String {
        switch self {
        case .status:
            return "waveform.path.ecg"
        case .devices:
            return "macbook.and.iphone"
        case .transfers:
            return "arrow.left.arrow.right"
        case .settings:
            return "gearshape"
        }
    }
}

private enum AirSendTransferHistoryFilter: String, CaseIterable, Identifiable {
    case outgoing = "Send"
    case incoming = "Receive"

    var id: String { rawValue }
    var direction: String { self == .outgoing ? "outgoing" : "incoming" }
    var symbolName: String { self == .outgoing ? "arrow.up" : "arrow.down" }
}

private enum AirSendSettingsPageSection: String, Identifiable {
    case statusOverview
    case statusHealth
    case statusQuickActions
    case statusRecentActivity
    case devicesCurrentTarget
    case devicesLAN
    case devicesManual
    case transfersMode
    case transfersActivity
    case transfersQueue
    case transfersOptions
    case settingsAutomation
    case settingsReceiving
    case settingsTrustedDevices
    case settingsNetwork
    case settingsHistory
    case settingsUpdates
    case settingsDiagnostics
    case settingsDiagnosticTools
    case settingsLogs
    case settingsIdentity
    case settingsAbout

    var id: String { rawValue }

    var order: Int {
        switch self {
        case .statusOverview, .devicesCurrentTarget, .transfersMode, .settingsAutomation:
            return 2
        case .statusHealth, .devicesLAN, .transfersActivity:
            return 4
        case .settingsReceiving:
            return 6
        case .transfersQueue:
            return 7
        case .statusQuickActions, .devicesManual:
            return 9
        case .settingsTrustedDevices, .transfersOptions:
            return 10
        case .statusRecentActivity:
            return 11
        case .settingsNetwork:
            return 14
        case .settingsHistory:
            return 17
        case .settingsUpdates:
            return 19
        case .settingsDiagnostics:
            return 23
        case .settingsDiagnosticTools:
            return 26
        case .settingsLogs:
            return 28
        case .settingsIdentity:
            return 30
        case .settingsAbout:
            return 32
        }
    }
}

struct AirSendSettingsView: View {
    private let topInset: CGFloat = 52
    private let edgeBlurHeight: CGFloat = 54
    private let topEdgeBlurHeight: CGFloat = 76
    private let edgeBlurSidebarOffset: CGFloat = 236
    private let edgeBlurMaxRadius: CGFloat = 5.5
    private let edgeBlurFalloffExponent: CGFloat = 2.05
    private let edgeBlurClearTailFraction: CGFloat = 0.18
    private let edgeBlurTailAlphaFloor: CGFloat = 0.10
    private var sidebarContentTopInset: CGFloat { topEdgeBlurHeight + 8 }
    private var detailContentTopInset: CGFloat { topEdgeBlurHeight - 2 }

    @ObservedObject var store: AirSendSettingsStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("airsend.console.selectedCategory.v2")
    private var selectedCategoryRawValue = AirSendSettingsCategory.status.rawValue

    @AirSendState private var transferHistoryFilter = AirSendTransferHistoryFilter.outgoing
    @AirSendState private var selectedTransferID: String?

    private var snapshot: AirSendSettingsSnapshot {
        store.snapshot
    }

    private var selectedCategory: AirSendSettingsCategory {
        AirSendSettingsCategory(rawValue: selectedCategoryRawValue) ?? .status
    }

    private var primaryDiagnostics: [AirSendDiagnosticSummary] {
        let preferredOrder = ["network", "receiver", "storage"]
        return preferredOrder.compactMap { id in
            snapshot.diagnostics.first { $0.id == id }
        }
    }

    private var selectedActiveTransfers: [AirSendTransferSummary] {
        snapshot.activeTransfers.filter { $0.direction == transferHistoryFilter.direction }
    }

    private var selectedTransferHistory: [AirSendTransferSummary] {
        transferHistoryFilter == .outgoing ? snapshot.sentHistory : snapshot.receivedHistory
    }

    private var selectedTransferActivity: [AirSendTransferSummary] {
        (selectedActiveTransfers + selectedTransferHistory)
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var transferContentEntranceID: String {
        "\(AirSendSettingsCategory.transfers.rawValue).\(transferHistoryFilter.rawValue)"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(SettingsSidebarBackground())
                .overlay(alignment: .trailing) {
                    SettingsSidebarEdgeFade()
                        .frame(width: 18)
                        .allowsHitTesting(false)
                }

            SettingsSidebarSeparator()
                .frame(width: 26)

            detail
        }
        .background(WindowDragSurface())
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 800, minHeight: 520)
        .overlay(alignment: .top) {
            edgeBlurOverlay(
                direction: .blurredTopClearBottom,
                height: topEdgeBlurHeight,
                sidebarOffset: 0
            )
        }
        .overlay(alignment: .bottom) {
            edgeBlurOverlay(
                direction: .blurredBottomClearTop,
                height: edgeBlurHeight,
                sidebarOffset: edgeBlurSidebarOffset
            )
        }
    }

    private func edgeBlurOverlay(
        direction: SettingsVariableBlurDirection,
        height: CGFloat,
        sidebarOffset: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: sidebarOffset)

            SettingsVariableBlurView(
                maxBlurRadius: edgeBlurMaxRadius,
                direction: direction,
                falloffExponent: edgeBlurFalloffExponent,
                clearTailFraction: edgeBlurClearTailFraction,
                tailAlphaFloor: edgeBlurTailAlphaFloor
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private var sidebar: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AirSend")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Console")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(AirSendSettingsCategory.allCases) { category in
                            Button {
                                selectCategory(category)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: category.symbol)
                                        .frame(width: 16)
                                        .foregroundStyle(Color(nsColor: .systemBlue))
                                    Text(category.title)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                }
                            }
                            .buttonStyle(SettingsSidebarButtonStyle(isSelected: selectedCategory == category))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, sidebarContentTopInset)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    private var detail: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedCategory.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .settingsPageEntrance(trigger: selectedCategory.rawValue, order: 0)
                        Text(selectedCategory.subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .settingsPageEntrance(trigger: selectedCategory.rawValue, order: 1)
                    }

                    pageContent(for: selectedCategory, availableHeight: proxy.size.height)
                }
                .padding(.horizontal, 20)
                .padding(.top, detailContentTopInset)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .draggableBlankArea()
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    private var animatedTransferHistoryFilter: Binding<AirSendTransferHistoryFilter> {
        Binding(
            get: { transferHistoryFilter },
            set: { selectTransferHistoryFilter($0) }
        )
    }

    private func pageContent(
        for category: AirSendSettingsCategory,
        availableHeight: CGFloat
    ) -> some View {
        let sections = pageSections(for: category)

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<AirSendSettingsMetrics.pageSectionSlotCount, id: \.self) { slot in
                let section = slot < sections.count ? sections[slot] : nil
                let trigger = section.map {
                    sectionEntranceTrigger(for: $0, category: category)
                } ?? "empty|\(slot)"
                let rowStartOrder = section == .transfersMode
                    ? (section?.order ?? 0)
                    : (section?.order ?? 0) + 2

                SettingsAnimatedCard(
                    title: section.flatMap { pageSectionTitle($0) },
                    trigger: "\(trigger)|section=\(section?.id ?? "empty")",
                    order: section?.order ?? 0,
                    usesCardBackground: section.map { $0 != .transfersMode } ?? false,
                    headerAccessory: {
                        pageSectionHeaderAccessory(section)
                    },
                    content: {
                        pageSectionRows(
                            section,
                            trigger: trigger,
                            startOrder: rowStartOrder,
                            availableHeight: availableHeight
                        )
                    }
                )
                .padding(.top, section == nil || slot == 0 ? 0 : 14)
            }
        }
        .onAppear {
            if category == .transfers {
                reconcileTransferSelection()
            }
        }
        .onChange(of: category) { _, newCategory in
            if newCategory == .transfers {
                reconcileTransferSelection()
            }
        }
        .onChange(of: transferHistoryFilter) { _, _ in
            selectedTransferID = selectedTransferActivity.first?.id
        }
        .onChange(of: selectedTransferActivity.map(\.id)) { _, _ in
            reconcileTransferSelection()
        }
        .onChange(of: store.quickLookSelectionID) { _, id in
            guard let id,
                  selectedTransferActivity.contains(where: { $0.id == id }) else { return }
            selectedTransferID = id
        }
    }

    private func pageSections(
        for category: AirSendSettingsCategory
    ) -> [AirSendSettingsPageSection] {
        switch category {
        case .status:
            return [
                .statusOverview,
                .statusHealth,
                .statusQuickActions,
                .statusRecentActivity,
            ]
        case .devices:
            return [.devicesCurrentTarget, .devicesLAN, .devicesManual]
        case .transfers:
            return [.transfersMode, .transfersActivity, .transfersQueue, .transfersOptions]
        case .settings:
            return [
                .settingsAutomation,
                .settingsReceiving,
                .settingsTrustedDevices,
                .settingsNetwork,
                .settingsHistory,
                .settingsUpdates,
                .settingsDiagnostics,
                .settingsDiagnosticTools,
                .settingsLogs,
                .settingsIdentity,
                .settingsAbout,
            ]
        }
    }

    private func pageSectionTitle(
        _ section: AirSendSettingsPageSection
    ) -> String? {
        switch section {
        case .statusOverview:
            return "Status"
        case .statusHealth:
            return "Health"
        case .statusQuickActions:
            return "Quick Actions"
        case .statusRecentActivity:
            return "Recent Activity"
        case .devicesCurrentTarget:
            return "Current Target"
        case .devicesLAN:
            return "LAN Devices"
        case .devicesManual:
            return "Manual Devices"
        case .transfersMode:
            return nil
        case .transfersActivity:
            return "Activity"
        case .transfersQueue:
            return "Transfer Queue"
        case .transfersOptions:
            return transferHistoryFilter == .outgoing ? "Send Options" : "Receive Options"
        case .settingsAutomation:
            return "Automation"
        case .settingsReceiving:
            return "Receiving"
        case .settingsTrustedDevices:
            return "Trusted Devices"
        case .settingsNetwork:
            return "Network"
        case .settingsHistory:
            return "History"
        case .settingsUpdates:
            return "Startup & Updates"
        case .settingsDiagnostics:
            return "Diagnostics"
        case .settingsDiagnosticTools:
            return "Diagnostic Tools"
        case .settingsLogs:
            return "Logs"
        case .settingsIdentity:
            return "Identity"
        case .settingsAbout:
            return "About"
        }
    }

    private func sectionEntranceTrigger(
        for section: AirSendSettingsPageSection,
        category: AirSendSettingsCategory
    ) -> String {
        switch section {
        case .transfersActivity, .transfersQueue, .transfersOptions:
            return transferContentEntranceID
        default:
            return category.rawValue
        }
    }

    @ViewBuilder
    private func pageSectionHeaderAccessory(
        _ section: AirSendSettingsPageSection?
    ) -> some View {
        if section == .devicesLAN {
            SettingsDiscoveryHeaderActions(
                isRefreshing: snapshot.isDiscoveryRefreshing,
                refreshAction: { store.actions.rescan() },
                addByIPAction: { store.actions.addDeviceByIP() },
                broadcastAction: { store.actions.selectBroadcastTarget() }
            )
        }
    }

    private func transferViewportHeight(availableHeight: CGFloat) -> CGFloat {
        let maximumHeight = min(
            AirSendSettingsMetrics.transferViewportMaximumHeight,
            max(
                AirSendSettingsMetrics.transferViewportMinimumCap,
                availableHeight * AirSendSettingsMetrics.transferViewportHeightRatio
            )
        )
        let estimatedContentHeight =
            CGFloat(selectedTransferActivity.count) * AirSendSettingsMetrics.transferEstimatedRowHeight
            + CGFloat(max(0, selectedTransferActivity.count - 1)) * AirSendSettingsMetrics.transferRowSpacing
            + AirSendSettingsMetrics.cardContentInset * 2

        return min(
            maximumHeight,
            max(
                AirSendSettingsMetrics.transferViewportMinimumHeight,
                estimatedContentHeight
            )
        )
    }

    @ViewBuilder
    private func pageSectionRows(
        _ section: AirSendSettingsPageSection?,
        trigger: String,
        startOrder: Int,
        availableHeight: CGFloat
    ) -> some View {
        switch section {
        case .statusOverview:
            SettingsConnectionOverviewRow(
                snapshot: snapshot,
                action: { store.actions.runDiagnostics() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=status-overview",
                order: startOrder
            )

        case .statusHealth:
            let diagnosticCount = primaryDiagnostics.count

            ForEach(Array(primaryDiagnostics.enumerated()), id: \.element.id) { index, diagnostic in
                SettingsDiagnosticRow(diagnostic: diagnostic)
                    .settingsPageEntrance(
                        trigger: "\(trigger)|row=status-diagnostic-\(diagnostic.id)",
                        order: startOrder + index
                    )
            }

            SettingsToggleRow(
                title: "Clipboard Sync",
                detail: "Sync copied text and images to the current Android target.",
                isOn: Binding(
                    get: { snapshot.clipboardSyncEnabled },
                    set: { store.actions.setClipboardSyncEnabled($0) }
                )
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=status-clipboard",
                order: startOrder + diagnosticCount
            )

            SettingsToggleRow(
                title: "Screenshot Sync",
                detail: "Send new macOS screenshots to one trusted target.",
                isOn: Binding(
                    get: { snapshot.screenshotSyncEnabled },
                    set: { store.actions.setScreenshotSyncEnabled($0) }
                )
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=status-screenshot",
                order: startOrder + diagnosticCount + 1
            )

        case .statusQuickActions:
            SettingsButtonRow(
                primaryTitle: "Run Diagnostics",
                primaryAction: { store.actions.runDiagnostics() },
                secondaryTitle: snapshot.isDiscoveryRefreshing ? "Refreshing…" : "Refresh Devices",
                secondaryAction: { store.actions.rescan() },
                tertiaryTitle: "Restart Runtime",
                tertiaryAction: { store.actions.restartRuntime() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=status-quick-actions",
                order: startOrder
            )

        case .statusRecentActivity:
            Group {
                if snapshot.recentActivities.isEmpty {
                    SettingsEmptyStateRow(
                        title: "No recent activity",
                        message: "Discovery, transfers, and diagnostics will appear here."
                    )
                } else {
                    SettingsActivityList(
                        activities: snapshot.recentActivities,
                        maximumVisibleRows: 3
                    )
                }
            }
            .settingsPageEntrance(
                trigger: "\(trigger)|row=status-recent-activity",
                order: startOrder
            )

        case .devicesCurrentTarget:
            SettingsCurrentTargetRow(snapshot: snapshot)
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=current-target",
                    order: startOrder
                )

        case .devicesLAN:
            SettingsDevicesSummaryRow(snapshot: snapshot)
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=lan-summary",
                    order: startOrder
                )

            if snapshot.nearbyDevices.isEmpty {
                SettingsEmptyStateRow(
                    title: "No devices found",
                    message: "Make sure the other device is on the same LAN, then rescan."
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=lan-empty",
                    order: startOrder + 1
                )
            } else {
                ForEach(Array(snapshot.nearbyDevices.enumerated()), id: \.element.id) { index, device in
                    SettingsDeviceRow(
                        device: device,
                        isCompatibilityModeEnabled: snapshot.compatibilityModeEnabled,
                        selectAction: {
                            store.actions.selectDeviceTarget(device.id)
                        }
                    )
                    .settingsPageEntrance(
                        trigger: "\(trigger)|row=lan-device-\(device.id)",
                        order: startOrder + index + 1
                    )
                }
            }

        case .devicesManual:
            if snapshot.manualPeers.isEmpty {
                SettingsEmptyStateRow(
                    title: "No manual devices",
                    message: "Direct endpoints appear here."
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=manual-empty",
                    order: startOrder
                )
            } else {
                ForEach(Array(snapshot.manualPeers.enumerated()), id: \.element.id) { index, peer in
                    SettingsManualPeerRow(
                        peer: peer,
                        removeAction: { store.actions.removeManualPeer(peer.id) }
                    )
                    .settingsPageEntrance(
                        trigger: "\(trigger)|row=manual-peer-\(peer.id)",
                        order: startOrder + index
                    )
                }
            }

            SettingsInlineCommandRow(
                title: "Add Manual Device",
                symbolName: "plus",
                action: { store.actions.addDeviceByIP() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=manual-add",
                order: startOrder + snapshot.manualPeers.count + 1
            )

        case .transfersMode:
            SettingsTransferModeBar(
                filter: animatedTransferHistoryFilter,
                historyCount: selectedTransferHistory.count,
                clearAction: { requestClearSelectedHistory() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=transfer-mode",
                order: startOrder
            )

        case .transfersActivity:
            if selectedTransferActivity.isEmpty {
                SettingsTransferEmptyState(direction: transferHistoryFilter)
                    .settingsPageEntrance(
                        trigger: "\(trigger)|row=transfer-activity-empty",
                        order: startOrder
                    )
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        SettingsEntranceGate(
                            trigger: trigger,
                            spacing: AirSendSettingsMetrics.transferRowSpacing
                        ) {
                            ForEach(
                                Array(selectedTransferActivity.enumerated()),
                                id: \.element.id
                            ) { index, transfer in
                                SettingsTransferRow(
                                    transfer: transfer,
                                    isSelected: selectedTransferID == transfer.id,
                                    selectAction: { selectedTransferID = transfer.id },
                                    previewAction: {
                                        store.actions.previewTransfer(
                                            transfer.id,
                                            selectedTransferActivity.map(\.id)
                                        )
                                    },
                                    cancelAction: { store.actions.cancelTransfer(transfer.id) },
                                    retryAction: { store.actions.retryTransfer(transfer.id) },
                                    revealAction: { store.actions.revealTransfer(transfer.id) },
                                    shareAction: { store.actions.shareTransfer(transfer.id) },
                                    deleteAction: { store.actions.deleteHistory(transfer.id) }
                                )
                                .settingsPageEntrance(
                                    trigger: "\(trigger)|row=transfer-\(transfer.id)",
                                    order: startOrder + index
                                )
                                .id(transfer.id)
                            }
                        }
                        .padding(AirSendSettingsMetrics.cardContentInset)
                    }
                    .frame(height: transferViewportHeight(availableHeight: availableHeight))
                    .scrollContentBackground(.hidden)
                    .onChange(of: selectedTransferID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            scrollProxy.scrollTo(id)
                        }
                    }
                }
            }

        case .transfersQueue:
            if transferHistoryFilter == .outgoing {
                SettingsTransferActionRow(
                    title: "Choose Files",
                    detail: snapshot.canSendToSelectedTarget
                        ? "Send to \(snapshot.selectedTargetTitle)"
                        : "Choose an online target first",
                    symbolName: "folder.badge.plus",
                    isEnabled: snapshot.canSendToSelectedTarget,
                    action: { store.actions.chooseFilesToSend() }
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=queue-choose-files",
                    order: startOrder
                )

                SettingsTransferActionRow(
                    title: "Nearby Targets",
                    detail: "\(snapshot.selectedTargetTitle) · \(snapshot.discoveredDeviceCount) online",
                    symbolName: snapshot.selectedTargetIsBroadcast
                        ? "square.grid.2x2"
                        : "dot.radiowaves.left.and.right",
                    action: { selectCategory(.devices) }
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=queue-nearby-targets",
                    order: startOrder + 1
                )
            } else {
                SettingsTransferInfoRow(
                    title: "Receive Requests",
                    detail: selectedActiveTransfers.isEmpty
                        ? "No active requests"
                        : "\(selectedActiveTransfers.count) active",
                    symbolName: "tray.and.arrow.down"
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=queue-receive-requests",
                    order: startOrder
                )
            }

        case .transfersOptions:
            if transferHistoryFilter == .outgoing {
                SettingsTransferActionRow(
                    title: "Send Clipboard",
                    detail: "Text or image from the clipboard",
                    symbolName: "clipboard",
                    isEnabled: snapshot.canSendToSelectedTarget,
                    action: { store.actions.sendClipboardNow() }
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=options-send-clipboard",
                    order: startOrder
                )
            } else {
                SettingsReceivePolicyRow(
                    selection: Binding(
                        get: { snapshot.receivePolicy },
                        set: { store.actions.setReceivePolicy($0) }
                    )
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=options-receive-policy",
                    order: startOrder
                )

                SettingsDestinationRow(
                    title: "Files",
                    path: snapshot.downloadDestination,
                    action: { store.actions.selectDownloadDestination() }
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=options-files",
                    order: startOrder + 1
                )

                SettingsDestinationRow(
                    title: "Images & Video",
                    path: snapshot.mediaDestination,
                    action: { store.actions.selectMediaDestination() }
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=options-media",
                    order: startOrder + 2
                )
            }

        case .settingsAutomation:
            SettingsToggleRow(
                title: "Clipboard Sync",
                detail: "Sync copied text and images to the current Android target.",
                isOn: Binding(
                    get: { snapshot.clipboardSyncEnabled },
                    set: { store.actions.setClipboardSyncEnabled($0) }
                )
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=automation-clipboard",
                order: startOrder
            )

            SettingsToggleRow(
                title: "Screenshot Sync",
                detail: "Watch new screenshots and send them to one trusted target.",
                isOn: Binding(
                    get: { snapshot.screenshotSyncEnabled },
                    set: { store.actions.setScreenshotSyncEnabled($0) }
                )
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=automation-screenshot",
                order: startOrder + 1
            )

            SettingsValueRow(
                title: "Screenshot watcher",
                value: snapshot.screenshotWatcherStatus,
                detail: snapshot.screenshotWatchFolder
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=automation-watcher",
                order: startOrder + 2
            )

        case .settingsReceiving:
            SettingsReceivePolicyRow(
                selection: Binding(
                    get: { snapshot.receivePolicy },
                    set: { store.actions.setReceivePolicy($0) }
                )
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=receiving-policy",
                order: startOrder
            )

            SettingsDestinationRow(
                title: "Files",
                path: snapshot.downloadDestination,
                action: { store.actions.selectDownloadDestination() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=receiving-files",
                order: startOrder + 1
            )

            SettingsDestinationRow(
                title: "Images & Video",
                path: snapshot.mediaDestination,
                action: { store.actions.selectMediaDestination() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=receiving-media",
                order: startOrder + 2
            )

        case .settingsTrustedDevices:
            if snapshot.trustedPeers.isEmpty {
                SettingsEmptyStateRow(
                    title: "No trusted devices",
                    message: "Trust is only needed for unattended receiving and automation."
                )
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=trusted-empty",
                    order: startOrder
                )
            } else {
                ForEach(Array(snapshot.trustedPeers.enumerated()), id: \.element.id) { index, peer in
                    SettingsTrustedPeerRow(
                        peer: peer,
                        revokeAction: { store.actions.revokeTrustedPeer(peer.id) }
                    )
                    .settingsPageEntrance(
                        trigger: "\(trigger)|row=trusted-peer-\(peer.id)",
                        order: startOrder + index
                    )
                }
            }

            SettingsInlineCommandRow(
                title: "Trust Device…",
                symbolName: "person.badge.shield.checkmark",
                action: { store.actions.trustKnownDevice() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=trusted-add",
                order: startOrder + snapshot.trustedPeers.count + 1
            )

        case .settingsNetwork:
            SettingsToggleRow(
                title: "Compatibility Mode",
                detail: "Use the simpler HTTP path on tricky networks.",
                isOn: Binding(
                    get: { snapshot.compatibilityModeEnabled },
                    set: { store.actions.setCompatibilityModeEnabled($0) }
                )
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=network-compatibility",
                order: startOrder
            )

            SettingsValueRow(title: "Current transport", value: snapshot.protocolLabel)
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=network-transport",
                    order: startOrder + 1
                )

        case .settingsHistory:
            SettingsHistoryLimitRow(
                value: snapshot.historyLimitPerDirection,
                action: { store.actions.setHistoryLimitPerDirection($0) }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=history-limit",
                order: startOrder
            )

        case .settingsUpdates:
            SettingsToggleRow(
                title: "Launch at login",
                detail: "Start AirSend when you sign in.",
                isOn: Binding(
                    get: { snapshot.launchAtLoginEnabled },
                    set: { store.actions.setLaunchAtLoginEnabled($0) }
                )
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=updates-launch",
                order: startOrder
            )

            SettingsToggleRow(
                title: "Auto-check for updates",
                detail: "Check in the background and download new builds automatically.",
                isOn: Binding(
                    get: { snapshot.autoUpdateEnabled },
                    set: { store.actions.setAutoUpdateEnabled($0) }
                )
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=updates-auto-check",
                order: startOrder + 1
            )

            SettingsButtonRow(
                primaryTitle: "Check for Updates",
                primaryAction: { store.actions.checkForUpdates() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=updates-check",
                order: startOrder + 2
            )

        case .settingsDiagnostics:
            ForEach(Array(snapshot.diagnostics.enumerated()), id: \.element.id) { index, diagnostic in
                SettingsDiagnosticRow(diagnostic: diagnostic)
                    .settingsPageEntrance(
                        trigger: "\(trigger)|row=diagnostic-\(diagnostic.id)",
                        order: startOrder + index
                    )
            }

        case .settingsDiagnosticTools:
            SettingsButtonRow(
                primaryTitle: "Run Diagnostics",
                primaryAction: { store.actions.runDiagnostics() },
                secondaryTitle: "Restart Runtime",
                secondaryAction: { store.actions.restartRuntime() },
                tertiaryTitle: "Export Logs",
                tertiaryAction: { store.actions.exportLogs() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=diagnostic-tools",
                order: startOrder
            )

        case .settingsLogs:
            SettingsLogTailView(lines: snapshot.logTail)
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=logs-tail",
                    order: startOrder
                )

            SettingsInlineCommandRow(
                title: "Clear Logs",
                symbolName: "trash",
                role: .destructive,
                action: { store.actions.clearLogs() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=logs-clear",
                order: startOrder + 1
            )

        case .settingsIdentity:
            SettingsValueRow(title: "Fingerprint", value: snapshot.fingerprintSuffix)
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=identity-fingerprint",
                    order: startOrder
                )

            SettingsButtonRow(
                primaryTitle: "Reset Identity",
                primaryAction: { store.actions.resetIdentity() },
                secondaryTitle: "Clear Devices",
                secondaryAction: { store.actions.clearDiscoveredDevices() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=identity-actions",
                order: startOrder + 1
            )

        case .settingsAbout:
            SettingsValueRow(title: "Version", value: snapshot.currentVersion)
                .settingsPageEntrance(
                    trigger: "\(trigger)|row=about-version",
                    order: startOrder
                )

            SettingsInlineCommandRow(
                title: "Open AirSend Repository",
                symbolName: "arrow.up.right.square",
                action: { store.actions.openAndroidRepository() }
            )
            .settingsPageEntrance(
                trigger: "\(trigger)|row=about-repository",
                order: startOrder + 1
            )

        case nil:
            EmptyView()
        }
    }

    private func selectCategory(_ category: AirSendSettingsCategory) {
        guard category != selectedCategory else { return }

        if reduceMotion {
            selectedCategoryRawValue = category.rawValue
            return
        }

        withAnimation(
            .linear(duration: AirSendSettingsMetrics.pageTransitionTriggerDuration)
        ) {
            selectedCategoryRawValue = category.rawValue
        }
    }

    private func selectTransferHistoryFilter(_ filter: AirSendTransferHistoryFilter) {
        guard filter != transferHistoryFilter else { return }

        if reduceMotion {
            transferHistoryFilter = filter
            return
        }

        withAnimation(
            .linear(duration: AirSendSettingsMetrics.pageTransitionTriggerDuration)
        ) {
            transferHistoryFilter = filter
        }
    }

    private func requestClearSelectedHistory() {
        guard !selectedTransferHistory.isEmpty else { return }

        let directionTitle = transferHistoryFilter == .outgoing ? "Sent" : "Received"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear \(directionTitle) History?"
        alert.informativeText = "This removes completed and failed transfer records. Saved files are not deleted."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.actions.clearHistory(transferHistoryFilter.direction)
    }

    private func reconcileTransferSelection() {
        if let selectedTransferID,
           selectedTransferActivity.contains(where: { $0.id == selectedTransferID }) {
            return
        }
        selectedTransferID = selectedTransferActivity.first?.id
    }

}

private struct WindowDragSurface: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .accessibilityHidden(true)
    }
}

private struct SettingsSidebarSeparator: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .black.opacity(0.018), location: 0.18),
                            .init(color: .clear, location: 0.46),
                            .init(color: .white.opacity(0.012), location: 0.66),
                            .init(color: .clear, location: 1.00),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blur(radius: 5)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.030),
                            .white.opacity(0.014),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 0.5)
                .offset(x: -4)
                .blur(radius: 1.0)
        }
        .padding(.vertical, 28)
        .compositingGroup()
    }
}

private struct SettingsSidebarBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                .white.opacity(0.010),
                .clear,
                .black.opacity(0.010),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct SettingsSidebarEdgeFade: View {
    var body: some View {
        LinearGradient(
            colors: [
                .clear,
                .white.opacity(0.010),
                .clear,
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private enum SettingsVariableBlurDirection {
    case blurredTopClearBottom
    case blurredBottomClearTop
}

private struct SettingsVariableBlurView: NSViewRepresentable {
    let maxBlurRadius: CGFloat
    let direction: SettingsVariableBlurDirection
    let falloffExponent: CGFloat
    let clearTailFraction: CGFloat
    let tailAlphaFloor: CGFloat

    func makeNSView(context: Context) -> SettingsVariableBlurNSView {
        SettingsVariableBlurNSView(
            maxBlurRadius: maxBlurRadius,
            direction: direction,
            falloffExponent: falloffExponent,
            clearTailFraction: clearTailFraction,
            tailAlphaFloor: tailAlphaFloor
        )
    }

    func updateNSView(_ view: SettingsVariableBlurNSView, context: Context) {
        view.update(
            maxBlurRadius: maxBlurRadius,
            direction: direction,
            falloffExponent: falloffExponent,
            clearTailFraction: clearTailFraction,
            tailAlphaFloor: tailAlphaFloor
        )
    }
}

private final class SettingsVariableBlurNSView: NSVisualEffectView {
    private var maxBlurRadius: CGFloat
    private var direction: SettingsVariableBlurDirection
    private var falloffExponent: CGFloat
    private var clearTailFraction: CGFloat
    private var tailAlphaFloor: CGFloat

    init(
        maxBlurRadius: CGFloat,
        direction: SettingsVariableBlurDirection,
        falloffExponent: CGFloat,
        clearTailFraction: CGFloat,
        tailAlphaFloor: CGFloat
    ) {
        self.maxBlurRadius = maxBlurRadius
        self.direction = direction
        self.falloffExponent = falloffExponent
        self.clearTailFraction = clearTailFraction
        self.tailAlphaFloor = tailAlphaFloor
        super.init(frame: .zero)
        wantsLayer = true
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        isEmphasized = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        maxBlurRadius: CGFloat,
        direction: SettingsVariableBlurDirection,
        falloffExponent: CGFloat,
        clearTailFraction: CGFloat,
        tailAlphaFloor: CGFloat
    ) {
        self.maxBlurRadius = maxBlurRadius
        self.direction = direction
        self.falloffExponent = falloffExponent
        self.clearTailFraction = clearTailFraction
        self.tailAlphaFloor = tailAlphaFloor
        installVariableBlur()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.installVariableBlur()
        }
    }

    override func layout() {
        super.layout()
        installVariableBlur()
    }

    private func installVariableBlur() {
        guard let materialLayer = layer?.sublayers?.first else {
            layer?.opacity = 0
            return
        }
        guard let backdropLayer = findBackdropLayer(in: materialLayer),
              let variableBlur = makeVariableBlurFilter() else {
            layer?.opacity = 0
            return
        }

        layer?.opacity = 1
        materialLayer.backgroundColor = nil
        materialLayer.isOpaque = false
        materialLayer.sublayers?.forEach { sublayer in
            if sublayer !== backdropLayer {
                sublayer.opacity = 0
                sublayer.isHidden = true
            }
        }
        backdropLayer.backgroundColor = nil
        backdropLayer.isOpaque = false
        backdropLayer.filters = [variableBlur]
        backdropLayer.setValue(NSScreen.main?.backingScaleFactor ?? 2, forKey: "scale")
    }

    private func findBackdropLayer(in layer: CALayer) -> CALayer? {
        if layer.name == "backdrop" || String(describing: type(of: layer)).contains("CABackdropLayer") {
            return layer
        }
        for sublayer in layer.sublayers ?? [] {
            if let match = findBackdropLayer(in: sublayer) {
                return match
            }
        }
        return nil
    }

    private func makeVariableBlurFilter() -> NSObject? {
        let className = String("retliFAC".reversed())
        let selectorName = String(":epyThtiWretlif".reversed())
        guard let filterClass = NSClassFromString(className) as? NSObject.Type,
              let filter = filterClass
                .perform(NSSelectorFromString(selectorName), with: "variableBlur")?
                .takeUnretainedValue() as? NSObject,
              let maskImage = makeGradientImage() else {
            return nil
        }

        filter.setValue(maxBlurRadius, forKey: "inputRadius")
        filter.setValue(maskImage, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }

    private func makeGradientImage(width: Int = 32, height: Int = 256) -> CGImage? {
        let exponent = max(1.4, min(falloffExponent, 5.0))
        let clearTail = max(0, min(clearTailFraction, 0.42))
        let tailFloor = max(0, min(tailAlphaFloor, 0.20))
        let rowCount = max(height - 1, 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for row in 0..<height {
            let topToBottom = CGFloat(row) / CGFloat(rowCount)
            let directionalAlpha: CGFloat
            switch direction {
            case .blurredBottomClearTop:
                directionalAlpha = topToBottom
            case .blurredTopClearBottom:
                directionalAlpha = 1 - topToBottom
            }
            let mixedAlpha: CGFloat
            if directionalAlpha <= clearTail {
                let tailProgress = clearTail > 0 ? directionalAlpha / clearTail : 1
                mixedAlpha = tailFloor * smoothStep(tailProgress)
            } else {
                let normalizedAlpha = (directionalAlpha - clearTail) / (1 - clearTail)
                let curvedAlpha = pow(normalizedAlpha, exponent)
                mixedAlpha = tailFloor + ((1 - tailFloor) * curvedAlpha)
            }
            let alpha = UInt8((mixedAlpha * 255).rounded())

            for column in 0..<width {
                let offset = ((row * width) + column) * 4
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = alpha
            }
        }

        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let x = max(0, min(value, 1))
        return x * x * (3 - (2 * x))
    }
}

private extension View {
    func draggableBlankArea() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture(), including: .gesture)
            .allowsWindowActivationEvents(true)
    }

    func settingsPageEntrance(trigger: String, order: Int) -> some View {
        SettingsPageEntranceHost(order: order, content: self)
            .id("settings-page-entrance|\(trigger)|\(order)")
    }

    func settingsCardSurfaceEntrance(trigger: String, order: Int) -> some View {
        SettingsCardSurfaceEntranceHost(order: order, content: self)
            .id("settings-card-surface|\(trigger)|\(order)")
    }
}

private struct SettingsPageEntranceHost<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let order: Int
    let content: Content

    @AirSendState private var focusProgress: CGFloat = 0
    @AirSendState private var motionProgress: CGFloat = 0

    private var delay: TimeInterval {
        let staggerIndex = min(
            max(order, 0),
            AirSendSettingsMetrics.pageEntranceMaximumStaggerIndex
        )
        return TimeInterval(
            staggerIndex * AirSendSettingsMetrics.pageEntranceStaggerMilliseconds
        ) / 1_000
    }

    var body: some View {
        let focus = reduceMotion ? 1 : min(max(focusProgress, 0), 1)
        let motion = reduceMotion ? 1 : motionProgress
        let reveal = min(
            1,
            focus / AirSendSettingsMetrics.pageEntranceRevealFraction
        )

        content
            .opacity(smoothStep(reveal))
            .blur(
                radius: reduceMotion
                    ? 0
                    : max(
                        0.001,
                        AirSendSettingsMetrics.pageEntranceMaximumBlur * (1 - focus)
                    )
            )
            .offset(y: AirSendSettingsMetrics.pageEntranceOffset * (1 - motion))
            .task {
                guard !reduceMotion else { return }

                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }

                withAnimation(
                    .timingCurve(
                        0.16,
                        1.0,
                        0.30,
                        1.0,
                        duration: AirSendSettingsMetrics.pageEntranceDuration
                    )
                    .delay(delay)
                ) {
                    focusProgress = 1
                }

                withAnimation(
                    .spring(
                        duration: AirSendSettingsMetrics.pageEntranceDuration,
                        bounce: AirSendSettingsMetrics.pageEntranceBounce
                    )
                    .delay(delay)
                ) {
                    motionProgress = 1
                }
            }
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - (2 * value))
    }
}

private struct SettingsCardSurfaceEntranceHost<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let order: Int
    let content: Content

    @AirSendState private var revealProgress: CGFloat = 0
    @AirSendState private var motionProgress: CGFloat = 0

    private var delay: TimeInterval {
        let staggerIndex = min(
            max(order, 0),
            AirSendSettingsMetrics.pageEntranceMaximumStaggerIndex
        )
        return TimeInterval(
            staggerIndex * AirSendSettingsMetrics.pageEntranceStaggerMilliseconds
        ) / 1_000
    }

    var body: some View {
        let reveal = reduceMotion ? 1 : min(max(revealProgress, 0), 1)
        let motion = reduceMotion ? 1 : motionProgress

        content
            .opacity(smoothStep(min(1, reveal / 0.58)))
            .offset(y: AirSendSettingsMetrics.pageEntranceSurfaceOffset * (1 - motion))
            .task {
                guard !reduceMotion else { return }

                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }

                withAnimation(
                    .timingCurve(
                        0.16,
                        1.0,
                        0.30,
                        1.0,
                        duration: AirSendSettingsMetrics.pageEntranceSurfaceDuration
                    )
                    .delay(delay)
                ) {
                    revealProgress = 1
                }

                withAnimation(
                    .spring(
                        duration: AirSendSettingsMetrics.pageEntranceSurfaceDuration,
                        bounce: AirSendSettingsMetrics.pageEntranceSurfaceBounce
                    )
                    .delay(delay)
                ) {
                    motionProgress = 1
                }
            }
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - (2 * value))
    }
}

private struct SettingsEntranceGate<Content: View>: View {
    let trigger: String
    let spacing: CGFloat
    let content: Content

    @AirSendState private var isPresented = false

    init(
        trigger: String,
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.trigger = trigger
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        LazyVStack(spacing: spacing) {
            if isPresented {
                content
            }
        }
        .task(id: trigger) {
            var resetTransaction = Transaction(animation: nil)
            resetTransaction.disablesAnimations = true
            withTransaction(resetTransaction) {
                isPresented = false
            }

            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            withAnimation(
                .linear(duration: AirSendSettingsMetrics.pageTransitionTriggerDuration)
            ) {
                isPresented = true
            }
        }
    }
}

private struct SettingsSidebarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.primary)
            .symbolRenderingMode(.hierarchical)
            .background {
                shape
                    .fill(background(for: configuration.isPressed))
            }
            .clipShape(shape)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isSelected)
    }

    private func background(for isPressed: Bool) -> some ShapeStyle {
        if isPressed {
            return AnyShapeStyle(.white.opacity(0.055))
        }
        if isSelected {
            return AnyShapeStyle(.white.opacity(0.065))
        }
        return AnyShapeStyle(.clear)
    }
}

private struct SettingsAnimatedCard<Content: View, HeaderAccessory: View>: View {
    let title: String?
    let trigger: String
    let order: Int
    let usesCardBackground: Bool
    let headerAccessory: HeaderAccessory
    let content: Content

    init(
        title: String?,
        trigger: String,
        order: Int,
        usesCardBackground: Bool,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trigger = trigger
        self.order = order
        self.usesCardBackground = usesCardBackground
        self.headerAccessory = headerAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: title == nil ? 0 : 8) {
            if let title {
                HStack(alignment: .center, spacing: 14) {
                    Text(title.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .settingsPageEntrance(
                            trigger: "\(trigger)|card-title=\(title)",
                            order: order
                        )

                    headerAccessory
                        .settingsPageEntrance(
                            trigger: "\(trigger)|card-accessory=\(title)",
                            order: order + 1
                        )

                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background {
                if usesCardBackground {
                    SettingsAnimatedCardSurface()
                        .settingsCardSurfaceEntrance(
                            trigger: "\(trigger)|card-surface=\(title ?? "plain")",
                            order: order + 2
                        )
                }
            }
        }
    }
}

private struct SettingsAnimatedCardSurface: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: AirSendSettingsMetrics.cardCornerRadius,
            style: .continuous
        )
        .fill(
            LinearGradient(
                colors: [
                    .white.opacity(0.030),
                    .black.opacity(0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: AirSendSettingsMetrics.cardCornerRadius,
                style: .continuous
            )
            .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
    }
}

private struct SettingsDiscoveryHeaderActions: View {
    let isRefreshing: Bool
    let refreshAction: () -> Void
    let addByIPAction: () -> Void
    let broadcastAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(isRefreshing ? "Refreshing…" : "Refresh Devices", action: refreshAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRefreshing)

            Button("Add by IP", action: addByIPAction)
                .buttonStyle(.bordered)

            Button("Use Broadcast", action: broadcastAction)
                .buttonStyle(.bordered)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SettingsHealthStatusRow: View {
    let snapshot: AirSendSettingsSnapshot
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsGlowIcon(
                symbolName: snapshot.healthTone.connectionSymbolName,
                tint: snapshot.healthTone.tintColor,
                size: 40,
                cornerRadius: 13
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.healthTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    SettingsBadge(title: snapshot.protocolLabel, tone: .neutral)
                }

                Text(snapshot.healthDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(snapshot.preflightSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Run Diagnostics", action: action)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SettingsConnectionOverviewRow: View {
    let snapshot: AirSendSettingsSnapshot
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                statusBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                targetBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                Button("Run Diagnostics", action: action)
                    .buttonStyle(.bordered)
                    .fixedSize()
            }

            HStack(spacing: 8) {
                SettingsMetricChip(title: "Visible", value: "\(snapshot.discoveredDeviceCount)")
                SettingsMetricChip(title: "Remembered", value: "\(snapshot.rememberedDeviceCount)")
                SettingsMetricChip(title: "Transport", value: snapshot.protocolLabel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusBlock: some View {
        HStack(spacing: 12) {
            SettingsGlowIcon(
                symbolName: snapshot.healthTone.connectionSymbolName,
                tint: snapshot.healthTone.tintColor,
                size: 40,
                cornerRadius: 13
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.healthTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    SettingsBadge(title: snapshot.protocolLabel, tone: .neutral)
                }

                Text(snapshot.healthDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(snapshot.preflightSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var targetBlock: some View {
        HStack(spacing: 12) {
            SettingsGlowIcon(
                symbolName: snapshot.selectedTargetIsBroadcast ? "square.grid.2x2.fill" : "dot.radiowaves.left.and.right",
                tint: Color(nsColor: .systemBlue),
                size: 40,
                cornerRadius: 13
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.selectedTargetTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    if snapshot.selectedTargetIsBroadcast {
                        SettingsBadge(title: "Broadcast", tone: .neutral)
                    }
                }

                Text(snapshot.selectedTargetSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(1)
            }
        }
    }
}

private struct SettingsGlowIcon: View {
    let symbolName: String
    let tint: Color
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.15),
                            tint.opacity(0.085),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            tint.opacity(0.20),
                            tint.opacity(0.08),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: size * 0.38
                    )
                )
                .frame(width: size * 0.78, height: size * 0.78)
                .blur(radius: 2.5)

            Image(systemName: symbolName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tint.opacity(0.42))
                .symbolRenderingMode(.monochrome)
                .blur(radius: 1.2)

            Image(systemName: symbolName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.98),
                            tint.opacity(0.72),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolRenderingMode(.monochrome)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.035),
                            .white.opacity(0.012),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

private struct SettingsCurrentTargetRow: View {
    let snapshot: AirSendSettingsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsGlowIcon(
                    symbolName: snapshot.selectedTargetIsBroadcast ? "square.grid.2x2.fill" : "dot.radiowaves.left.and.right",
                    tint: Color(nsColor: .systemBlue),
                    size: 40,
                    cornerRadius: 13
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(snapshot.selectedTargetTitle)
                            .font(.system(size: 14, weight: .semibold))

                        if snapshot.selectedTargetIsBroadcast {
                            SettingsBadge(title: "Broadcast", tone: .neutral)
                        }
                    }

                    Text(snapshot.selectedTargetSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                SettingsMetricChip(title: "Visible", value: "\(snapshot.nearbyDevices.count)")
                SettingsMetricChip(title: "Remembered", value: "\(snapshot.rememberedDeviceCount)")
                SettingsMetricChip(title: "Transport", value: snapshot.protocolLabel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SettingsDevicesSummaryRow: View {
    let snapshot: AirSendSettingsSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if snapshot.isDiscoveryRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text(snapshot.discoveryRefreshSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            SettingsMetaChip(title: "Same LAN")
            SettingsMetaChip(title: "\(snapshot.discoveredDeviceCount) live")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.24))
                .frame(height: 1)
        }
    }

    private var summaryText: String {
        let count = snapshot.discoveredDeviceCount
        if count == 0 {
            return "Waiting for other AirSend devices on this LAN."
        }
        if count == 1 {
            return "Showing 1 visible device on the current LAN."
        }
        return "Showing \(count) visible devices on the current LAN."
    }
}

private struct SettingsDeviceRow: View {
    let device: AirSendSettingsDeviceSummary
    let isCompatibilityModeEnabled: Bool
    let selectAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: selectAction) {
                HStack(alignment: .top, spacing: 12) {
                    SettingsGlowIcon(
                        symbolName: iconName,
                        tint: device.isOnline ? Color(nsColor: .systemBlue) : Color(nsColor: .systemGray),
                        size: 40,
                        cornerRadius: 13
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(device.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if device.isSelected {
                                SettingsBadge(title: "Selected", tone: .accent)
                            }
                            if device.isManual {
                                SettingsBadge(title: "Manual", tone: .neutral)
                            }
                        }

                        Text("\(device.deviceType) • \(device.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { metadataChips }
                            VStack(alignment: .leading, spacing: 6) { metadataChips }
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 7) {
                SettingsBadge(title: device.statusLabel, tone: .neutral)

                if device.isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemBlue))
                        .frame(width: 18, height: 18)
                        .accessibilityLabel("Selected target")
                }

                Text("ID \(device.fingerprintSuffix)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(device.isSelected ? .white.opacity(0.06) : .clear)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.22))
                .frame(height: 1)
        }
    }

    private var iconName: String {
        switch device.deviceType.lowercased() {
        case "phone":
            return "iphone"
        case "computer":
            return "desktopcomputer"
        case "tablet":
            return "ipad.landscape"
        case "server", "headless":
            return "externaldrive.fill"
        case "web":
            return "globe"
        default:
            return "display"
        }
    }

    @ViewBuilder
    private var metadataChips: some View {
        SettingsMetaChip(title: "\(device.ipAddress):\(device.port)")
        SettingsMetaChip(title: peerProtocolTitle)

        if !device.versionLabel.isEmpty {
            SettingsMetaChip(title: "v\(device.versionLabel)")
        }
    }

    private var peerProtocolTitle: String {
        isCompatibilityModeEnabled ? "Compatibility Mode" : "HTTPS Mode"
    }
}

private struct SettingsManualPeerRow: View {
    let peer: AirSendManualPeerSummary
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlowIcon(
                symbolName: "point.3.connected.trianglepath.dotted",
                tint: Color(nsColor: .systemTeal),
                size: 34,
                cornerRadius: 11
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.alias)
                    .font(.system(size: 13, weight: .semibold))
                Text(peer.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let fingerprint = peer.fingerprintSuffix {
                SettingsMetaChip(title: "ID \(fingerprint)")
            } else {
                SettingsBadge(title: "HTTP", tone: .neutral)
            }

            Button(role: .destructive, action: removeAction) {
                Image(systemName: "trash")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Remove manual device")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator.opacity(0.24)).frame(height: 1)
        }
    }
}

private struct SettingsTrustedPeerRow: View {
    let peer: AirSendTrustedPeerSummary
    let revokeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlowIcon(
                symbolName: "checkmark.shield.fill",
                tint: peer.isOnline ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray),
                size: 34,
                cornerRadius: 11
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("ID \(peer.fingerprintSuffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            SettingsBadge(title: peer.isOnline ? "Online" : "Offline", tone: .neutral)

            Button("Revoke", role: .destructive, action: revokeAction)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator.opacity(0.24)).frame(height: 1)
        }
    }
}

private struct SettingsTransferModeBar: View {
    @Binding var filter: AirSendTransferHistoryFilter
    let historyCount: Int
    let clearAction: () -> Void

    var body: some View {
        ZStack {
            Picker("Direction", selection: $filter) {
                ForEach(AirSendTransferHistoryFilter.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbolName)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color(nsColor: .systemBlue))
            .frame(width: 240)

            HStack {
                Spacer()
                Button(role: .destructive, action: clearAction) {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(historyCount == 0)
                .help("Clear \(filter == .outgoing ? "sent" : "received") history")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsTransferEmptyState: View {
    let direction: AirSendTransferHistoryFilter

    var body: some View {
        VStack(spacing: 9) {
            SettingsGlowIcon(
                symbolName: direction == .outgoing ? "paperplane" : "tray.and.arrow.down",
                tint: Color(nsColor: direction == .outgoing ? .systemBlue : .systemGreen),
                size: 42,
                cornerRadius: 12
            )

            Text(direction == .outgoing ? "No sent files yet" : "No received files yet")
                .font(.system(size: 13, weight: .semibold))

            Text(
                direction == .outgoing
                    ? "Shared files and clipboard sends will appear here."
                    : "Incoming transfers will appear here."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
    }
}

private struct SettingsTransferActionRow: View {
    let title: String
    let detail: String
    let symbolName: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsGlowIcon(
                    symbolName: symbolName,
                    tint: Color(nsColor: .systemBlue),
                    size: 34,
                    cornerRadius: 9
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator.opacity(0.24)).frame(height: 1)
        }
    }
}

private struct SettingsTransferInfoRow: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlowIcon(
                symbolName: symbolName,
                tint: Color(nsColor: .systemGreen),
                size: 34,
                cornerRadius: 9
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SettingsTransferRow: View {
    let transfer: AirSendTransferSummary
    let isSelected: Bool
    let selectAction: () -> Void
    let previewAction: () -> Void
    let cancelAction: () -> Void
    let retryAction: () -> Void
    let revealAction: () -> Void
    let shareAction: () -> Void
    let deleteAction: () -> Void

    @FocusState private var isPreviewFocused: Bool
    @AirSendState private var isPreviewHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                isPreviewFocused = true
                if isSelected {
                    previewAction()
                } else {
                    selectAction()
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    SettingsTransferPreview(fileKind: transfer.fileKind)
                    transferDetails
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: AirSendSettingsMetrics.cardCornerRadius,
                        style: .continuous
                    )
                )
            }
            .buttonStyle(.plain)
            .focusable()
            .focusEffectDisabled()
            .focused($isPreviewFocused)
            .onKeyPress(.space) {
                if isSelected {
                    previewAction()
                } else {
                    selectAction()
                }
                return .handled
            }
            .onAppear {
                if isSelected { isPreviewFocused = true }
            }
            .onChange(of: isSelected) { _, selected in
                if selected { isPreviewFocused = true }
            }
            .onHover { isPreviewHovered = $0 }
            .help(isSelected ? "Open with Quick Look" : "Select transfer")
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if isSelected {
                    if transfer.canCancel {
                        SettingsIconCommand(symbol: "xmark", help: "Cancel transfer", role: .destructive, action: cancelAction)
                    } else {
                        if transfer.canRetry {
                            SettingsIconCommand(symbol: "arrow.clockwise", help: "Retry transfer", action: retryAction)
                        }
                        if transfer.hasAvailableFiles {
                            SettingsIconCommand(symbol: "folder", help: "Show in Finder", action: revealAction)
                            SettingsIconCommand(symbol: "square.and.arrow.up", help: "Share", action: shareAction)
                        }
                        SettingsIconCommand(symbol: "trash", help: "Delete history item", role: .destructive, action: deleteAction)
                    }
                }
            }
            .frame(width: 118, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(
                cornerRadius: AirSendSettingsMetrics.cardCornerRadius,
                style: .continuous
            )
            .fill(
                isSelected
                    ? Color(nsColor: .controlAccentColor).opacity(0.09)
                    : (isPreviewHovered ? .white.opacity(0.045) : .clear)
            )
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: AirSendSettingsMetrics.cardCornerRadius,
                style: .continuous
            )
            .strokeBorder(
                isSelected ? Color(nsColor: .controlAccentColor).opacity(0.42) : .clear,
                lineWidth: 1
            )
        }
    }

    private var transferDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(transfer.fileTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                SettingsTransferStatusChip(status: transfer.status)
            }

            Text("\(transfer.direction == "incoming" ? "From" : "To") \(transfer.peerTitle) · \(transfer.timeLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if transfer.canCancel {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: transfer.progress)
                        .progressViewStyle(.linear)
                    Text(transfer.byteProgress)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 25, alignment: .top)
            } else if let failure = transfer.failureMessage, !failure.isEmpty {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .lineLimit(2)
            } else if let preview = transfer.previewText, !preview.isEmpty {
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(transfer.byteProgress)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct SettingsTransferPreview: View {
    let fileKind: AirSendTransferFileKind

    var body: some View {
        SettingsGlowIcon(
            symbolName: fileKind.symbolName,
            tint: Color(nsColor: .systemBlue),
            size: 38,
            cornerRadius: 8
        )
        .frame(width: 38, height: 38)
        .accessibilityLabel(fileKind.accessibilityLabel)
    }
}

private extension AirSendTransferFileKind {
    var symbolName: String {
        switch self {
        case .multiple: return "folder.fill"
        case .androidPackage: return "shippingbox.fill"
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext.fill"
        case .archive: return "doc.zipper"
        case .presentation: return "rectangle.3.group.fill"
        case .spreadsheet: return "tablecells.fill"
        case .wordProcessing: return "doc.text.fill"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .markdown: return "text.justify.leading"
        case .structuredData: return "curlybraces.square.fill"
        case .code: return "terminal.fill"
        case .text: return "doc.plaintext.fill"
        case .document: return "book.closed.fill"
        case .generic: return "doc.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .multiple: return "Multiple files"
        case .androidPackage: return "Android package"
        case .image: return "Image file"
        case .video: return "Video file"
        case .audio: return "Audio file"
        case .pdf: return "PDF document"
        case .archive: return "Archive file"
        case .presentation: return "Presentation"
        case .spreadsheet: return "Spreadsheet"
        case .wordProcessing: return "Word processing document"
        case .html: return "HTML document"
        case .markdown: return "Markdown document"
        case .structuredData: return "Structured data file"
        case .code: return "Source code file"
        case .text: return "Text file"
        case .document: return "Document"
        case .generic: return "File"
        }
    }
}

private struct SettingsTransferStatusChip: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var label: String {
        switch status {
        case "awaitingAcceptance": return "Waiting"
        case "preparing": return "Preparing"
        case "transferring": return "Transferring"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        case "declined": return "Declined"
        default: return status.capitalized
        }
    }

    private var tint: Color {
        switch status {
        case "completed": return Color(nsColor: .systemGreen)
        case "failed", "declined": return Color(nsColor: .systemOrange)
        case "cancelled": return Color(nsColor: .secondaryLabelColor)
        default: return Color(nsColor: .systemBlue)
        }
    }
}

private struct SettingsIconCommand: View {
    let symbol: String
    let help: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @AirSendState private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: AirSendSettingsMetrics.actionCornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color(nsColor: .systemRed) : .secondary)
        .background {
            RoundedRectangle(
                cornerRadius: AirSendSettingsMetrics.actionCornerRadius,
                style: .continuous
            )
            .fill(
                isHovered
                    ? (role == .destructive
                        ? Color(nsColor: .systemRed).opacity(0.12)
                        : .white.opacity(0.07))
                    : .clear
            )
        }
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SettingsDiagnosticRow: View {
    let diagnostic: AirSendDiagnosticSummary

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlowIcon(
                symbolName: diagnostic.symbolName,
                tint: diagnostic.tone.tintColor,
                size: 34,
                cornerRadius: 11
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(diagnostic.title)
                    .font(.system(size: 13, weight: .medium))
                if let detail = diagnostic.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 10)
            Text(diagnostic.value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(diagnostic.tone.tintColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator.opacity(0.24)).frame(height: 1)
        }
    }
}

private struct SettingsLogTailView: View {
    let lines: [String]

    var body: some View {
        if lines.isEmpty {
            SettingsEmptyStateRow(title: "No log entries", message: "Run diagnostics to refresh the log view.")
        } else {
            ScrollView(.vertical) {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 150, maxHeight: 230)
            .background(.black.opacity(0.12))
        }
    }
}

private struct SettingsReceivePolicyRow: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            Text("Receive requests")
            Spacer(minLength: 12)
            Picker("Receive requests", selection: $selection) {
                Text("Ask").tag("ask")
                Text("Trusted Only").tag("trusted_only")
                Text("Off").tag("off")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator.opacity(0.28)).frame(height: 1)
        }
    }
}

private struct SettingsDestinationRow: View {
    let title: String
    let path: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button(action: action) {
                Image(systemName: "folder")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .help("Choose folder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator.opacity(0.28)).frame(height: 1)
        }
    }
}

private struct SettingsHistoryLimitRow: View {
    let value: Int
    let action: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Items per direction")
            Spacer(minLength: 12)
            Picker("Items per direction", selection: Binding(
                get: { value },
                set: { newValue in action(newValue) }
            )) {
                ForEach([10, 30, 100, 300], id: \.self) { limit in
                    Text("\(limit)").tag(limit)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SettingsInlineCommandRow: View {
    let title: String
    let symbolName: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .frame(width: 18, height: 18)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color(nsColor: .systemRed) : .primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SettingsActivityRow: View {
    let activity: AirSendActivitySummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsGlowIcon(
                symbolName: activity.symbolName,
                tint: activity.tone.tintColor,
                size: 28,
                cornerRadius: 9
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title)
                    .font(.system(size: 12, weight: .semibold))

                Text(activity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(activity.timeLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.24))
                .frame(height: 1)
        }
    }
}

private struct SettingsActivityList: View {
    let activities: [AirSendActivitySummary]
    let maximumVisibleRows: Int

    var body: some View {
        if activities.count > maximumVisibleRows {
            ScrollView(.vertical, showsIndicators: true) {
                activityRows
            }
            .frame(height: CGFloat(maximumVisibleRows) * 64)
        } else {
            activityRows
        }
    }

    private var activityRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(activities) { activity in
                SettingsActivityRow(activity: activity)
            }
        }
    }
}

private extension AirSendConsoleHealthTone {
    var tintColor: Color {
        switch self {
        case .good:
            return Color(nsColor: .systemGreen)
        case .warning:
            return Color(nsColor: .systemOrange)
        case .neutral:
            return Color(nsColor: .systemBlue)
        }
    }

    var statusSymbolName: String {
        switch self {
        case .good:
            return "checkmark.seal.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .neutral:
            return "wave.3.right"
        }
    }

    var connectionSymbolName: String {
        switch self {
        case .good:
            return "checkmark.seal"
        case .warning:
            return "exclamationmark.triangle"
        case .neutral:
            return "wave.3.right"
        }
    }
}

private struct SettingsMetricChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
    }
}

private struct SettingsBadge: View {
    enum Tone {
        case accent
        case neutral
    }

    let title: String
    let tone: Tone

    var body: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(tone == .neutral ? .secondary : Color(nsColor: .systemBlue))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(tone == .neutral ? .white.opacity(0.05) : Color(nsColor: .systemBlue).opacity(0.12))
            )
    }
}

private struct SettingsMetaChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.04))
            )
    }
}

private struct SettingsEmptyStateRow: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .fontWeight(.medium)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.28))
                .frame(height: 1)
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .multilineTextAlignment(.trailing)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.28))
                .frame(height: 1)
        }
    }
}

private struct SettingsButtonRow: View {
    let primaryTitle: String
    let primaryAction: () -> Void
    var primaryDisabled = false
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var tertiaryTitle: String? = nil
    var tertiaryAction: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            actionStack
            VStack(alignment: .leading, spacing: 8) {
                actionStack
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var actionStack: some View {
        HStack(spacing: 8) {
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)

            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.bordered)
            }

            if let tertiaryTitle, let tertiaryAction {
                Button(tertiaryTitle, action: tertiaryAction)
                    .buttonStyle(.bordered)
            }
        }
    }
}
