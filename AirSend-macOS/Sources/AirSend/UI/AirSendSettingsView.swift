import SwiftUI

private enum AirSendSettingsCategory: String, CaseIterable, Identifiable {
    case devices
    case sync
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices:
            return "Devices"
        case .sync:
            return "Sync"
        case .advanced:
            return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .devices:
            return "Targets, discovery, and quick device actions."
        case .sync:
            return "Clipboard and screenshot behavior."
        case .advanced:
            return "Network, launch behavior, and receiver identity."
        }
    }

    var symbol: String {
        switch self {
        case .devices:
            return "macbook.and.iphone"
        case .sync:
            return "arrow.triangle.2.circlepath"
        case .advanced:
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

            Divider()
                .overlay(.separator.opacity(0.45))

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
                        Text("Settings")
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
                SettingsCard(title: "Current Target") {
                    SettingsCurrentTargetRow(snapshot: snapshot)
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

                SettingsCard(title: "Actions") {
                    SettingsButtonRow(
                        primaryTitle: "Rescan",
                        primaryAction: { store.actions.rescan() },
                        secondaryTitle: "Add by IP",
                        secondaryAction: { store.actions.addDeviceByIP() },
                        tertiaryTitle: "Broadcast",
                        tertiaryAction: { store.actions.selectBroadcastTarget() }
                    )
                }
            }

        case .sync:
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

        case .advanced:
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
            return AnyShapeStyle(.white.opacity(0.11))
        }
        if isSelected {
            return AnyShapeStyle(.white.opacity(0.075))
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
                    .fill(.white.opacity(0.035))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            }
        }
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
