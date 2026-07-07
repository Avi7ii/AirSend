import SwiftUI

private enum AirSendSettingsCategory: String, CaseIterable, Identifiable {
    case devices
    case transfers
    case clipboard
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices:
            return "Devices"
        case .transfers:
            return "Transfers"
        case .clipboard:
            return "Clipboard"
        case .diagnostics:
            return "Diagnostics"
        case .settings:
            return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .devices:
            return "Targets, discovery, health, and recent AirSend activity."
        case .transfers:
            return "Recent file transfer state and progress."
        case .clipboard:
            return "Clipboard text, images, and manual sync actions."
        case .diagnostics:
            return "Network health, receiver status, and troubleshooting."
        case .settings:
            return "Network, launch behavior, updates, and identity."
        }
    }

    var symbol: String {
        switch self {
        case .devices:
            return "macbook.and.iphone"
        case .transfers:
            return "arrow.left.arrow.right"
        case .clipboard:
            return "arrow.triangle.2.circlepath"
        case .diagnostics:
            return "stethoscope"
        case .settings:
            return "slider.horizontal.3"
        }
    }
}

struct AirSendSettingsView: View {
    private let topInset: CGFloat = 52

    @ObservedObject var store: AirSendSettingsStore

    @AppStorage("airsend.settings.selectedCategory")
    private var selectedCategoryRawValue = AirSendSettingsCategory.devices.rawValue

    private var snapshot: AirSendSettingsSnapshot {
        store.snapshot
    }

    private var selectedCategory: AirSendSettingsCategory {
        AirSendSettingsCategory(rawValue: selectedCategoryRawValue) ?? .devices
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(Color.black.opacity(0.01))

            Divider()
                .overlay(.separator.opacity(0.55))

            detail
        }
        .padding(.top, topInset)
        .background(WindowDragSurface())
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 760, minHeight: 480)
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
                                selectedCategoryRawValue = category.rawValue
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
                .padding(.top, 14)
                .padding(.bottom, 16)
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
                        Text(selectedCategory.subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    pageContent(for: selectedCategory)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .draggableBlankArea()
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    @ViewBuilder
    private func pageContent(for category: AirSendSettingsCategory) -> some View {
        switch category {
        case .devices:
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: "Connection") {
                    SettingsConnectionOverviewRow(
                        snapshot: snapshot,
                        action: { store.actions.runDiagnostics() }
                    )
                }

                SettingsCard(title: "LAN Devices") {
                    SettingsDevicesSummaryRow(snapshot: snapshot)

                    if snapshot.nearbyDevices.isEmpty {
                        SettingsEmptyStateRow(
                            title: "No devices found",
                            message: "Make sure the other device is on the same LAN, then rescan."
                        )
                    } else {
                        ForEach(snapshot.nearbyDevices) { device in
                            SettingsDeviceRow(
                                device: device,
                                isCompatibilityModeEnabled: snapshot.compatibilityModeEnabled,
                                action: {
                                    store.actions.selectDeviceTarget(device.id)
                                }
                            )
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        quickActionsCard
                        recentActivityCard
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        quickActionsCard
                        recentActivityCard
                    }
                }
            }

        case .transfers:
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: "Recent Status") {
                    if snapshot.recentActivities.isEmpty {
                        SettingsEmptyStateRow(
                            title: "No recent transfers",
                            message: "Sent and received activity will appear here."
                        )
                    } else {
                        SettingsActivityList(
                            activities: snapshot.recentActivities,
                            maximumVisibleRows: 4
                        )
                    }
                }

                SettingsCard(title: "Target") {
                    SettingsValueRow(
                        title: "Current target",
                        value: snapshot.selectedTargetTitle,
                        detail: snapshot.selectedTargetSubtitle
                    )
                    SettingsValueRow(title: "Transport", value: snapshot.protocolLabel)
                }
            }

        case .clipboard:
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: "Automatic Sync") {
                    SettingsToggleRow(
                        title: "Clipboard text",
                        detail: "Sync copied text to the current Android target.",
                        isOn: Binding(
                            get: { snapshot.autoClipboardSyncEnabled },
                            set: { store.actions.setAutoClipboardSyncEnabled($0) }
                        )
                    )

                    SettingsToggleRow(
                        title: "Screenshots",
                        detail: "Handle copied images separately from text sync.",
                        isOn: Binding(
                            get: { snapshot.autoScreenshotSyncEnabled },
                            set: { store.actions.setAutoScreenshotSyncEnabled($0) }
                        )
                    )
                }

                SettingsCard(title: "Destination") {
                    SettingsValueRow(title: "Current target", value: snapshot.selectedTargetTitle, detail: snapshot.selectedTargetSubtitle)
                }

                SettingsCard(title: "Actions") {
                    SettingsButtonRow(
                        primaryTitle: "Send Clipboard Now",
                        primaryAction: { store.actions.sendClipboardNow() },
                        secondaryTitle: "Android Repository",
                        secondaryAction: { store.actions.openAndroidRepository() }
                    )
                }
            }

        case .diagnostics:
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: "Network Health") {
                    SettingsHealthStatusRow(
                        snapshot: snapshot,
                        action: { store.actions.runDiagnostics() }
                    )
                }

                SettingsCard(title: "Preflight") {
                    SettingsValueRow(title: "Network check", value: snapshot.preflightSummary)
                    SettingsValueRow(title: "Visible devices", value: "\(snapshot.nearbyDevices.count)")
                    SettingsValueRow(title: "Remembered devices", value: "\(snapshot.rememberedDeviceCount)")
                    SettingsValueRow(title: "Receiver fingerprint", value: snapshot.fingerprintSuffix)
                }

                SettingsCard(title: "Troubleshooting") {
                    SettingsButtonRow(
                        primaryTitle: "Run Diagnostics",
                        primaryAction: { store.actions.runDiagnostics() },
                        secondaryTitle: "Rescan LAN",
                        secondaryAction: { store.actions.rescan() },
                        tertiaryTitle: "Clear Devices",
                        tertiaryAction: { store.actions.clearDiscoveredDevices() }
                    )
                }
            }

        case .settings:
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: "Network") {
                    SettingsToggleRow(
                        title: "Compatibility Mode",
                        detail: "Use the simpler HTTP path on tricky networks.",
                        isOn: Binding(
                            get: { snapshot.compatibilityModeEnabled },
                            set: { store.actions.setCompatibilityModeEnabled($0) }
                        )
                    )

                    SettingsValueRow(title: "Current transport", value: snapshot.protocolLabel)
                }

                SettingsCard(title: "Startup & Updates") {
                    SettingsToggleRow(
                        title: "Launch at login",
                        detail: "Start AirSend when you sign in.",
                        isOn: Binding(
                            get: { snapshot.launchAtLoginEnabled },
                            set: { store.actions.setLaunchAtLoginEnabled($0) }
                        )
                    )

                    SettingsToggleRow(
                        title: "Auto-check for updates",
                        detail: "Check in the background and download new builds automatically.",
                        isOn: Binding(
                            get: { snapshot.autoUpdateEnabled },
                            set: { store.actions.setAutoUpdateEnabled($0) }
                        )
                    )

                    SettingsButtonRow(
                        primaryTitle: "Check for Updates",
                        primaryAction: { store.actions.checkForUpdates() }
                    )
                }

                SettingsCard(title: "Receiver") {
                    SettingsValueRow(title: "Fingerprint", value: snapshot.fingerprintSuffix)
                    SettingsButtonRow(
                        primaryTitle: "Reset Identity",
                        primaryAction: { store.actions.resetIdentity() },
                        secondaryTitle: "Clear Devices",
                        secondaryAction: { store.actions.clearDiscoveredDevices() }
                    )
                }
            }
        }
    }

    private var quickActionsCard: some View {
        SettingsCard(title: "Quick Actions") {
            SettingsButtonRow(
                primaryTitle: "Rescan",
                primaryAction: { store.actions.rescan() },
                secondaryTitle: "Add by IP",
                secondaryAction: { store.actions.addDeviceByIP() },
                tertiaryTitle: "Broadcast",
                tertiaryAction: { store.actions.selectBroadcastTarget() }
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var recentActivityCard: some View {
        SettingsCard(title: "Recent Activity") {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

private extension View {
    func draggableBlankArea() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture(), including: .gesture)
            .allowsWindowActivationEvents(true)
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

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
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
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            }
        }
    }
}

private struct SettingsHealthStatusRow: View {
    let snapshot: AirSendSettingsSnapshot
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(snapshot.healthTone.tintColor.opacity(0.14))
                    .frame(width: 42, height: 42)

                Image(systemName: snapshot.healthTone.statusSymbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(snapshot.healthTone.tintColor)
            }

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
                SettingsMetricChip(title: "Visible", value: "\(snapshot.nearbyDevices.count)")
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
                .fill(.black.opacity(0.14))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(0.018))

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
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .systemBlue).opacity(0.14))
                        .frame(width: 40, height: 40)

                    Image(systemName: snapshot.selectedTargetIsBroadcast ? "square.grid.2x2.fill" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                }

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
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        let count = snapshot.nearbyDevices.count
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(nsColor: .systemBlue).opacity(device.isSelected ? 0.20 : 0.12))
                        .frame(width: 40, height: 40)

                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(device.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        if device.isSelected {
                            SettingsBadge(title: "Selected", tone: .accent)
                        }
                    }

                    Text("\(device.deviceType) • \(device.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            metadataChips
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            metadataChips
                        }
                    }
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 6) {
                    SettingsBadge(title: device.statusLabel, tone: .neutral)

                    if device.peerCount > 1 {
                        SettingsBadge(title: "\(device.peerCount) peers", tone: .neutral)
                    }

                    Text("ID \(device.fingerprintSuffix)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(verbatim: "Port \(device.port)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(device.isSelected ? .white.opacity(0.06) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(device.isSelected ? .white.opacity(0.08) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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

private struct SettingsActivityRow: View {
    let activity: AirSendActivitySummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(activity.tone.tintColor.opacity(0.12))
                    .frame(width: 28, height: 28)

                Image(systemName: activity.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(activity.tone.tintColor)
            }

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
