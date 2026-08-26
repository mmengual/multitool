import SwiftUI
import AppKit

extension Notification.Name {
    static let openStatsWindow = Notification.Name("com.mmengual.stopchattering.openStatsWindow")
}

struct PreferencesView: View {
    @State private var tab: Tab = .settings

    enum Tab: Hashable, CaseIterable {
        case settings, stats, info

        var label: String {
            switch self {
            case .settings: return "Settings"
            case .stats:    return "Stats"
            case .info:     return "Info"
            }
        }

        var icon: String {
            switch self {
            case .settings: return "gearshape.fill"
            case .stats:    return "chart.bar.fill"
            case .info:     return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .settings: SettingsTab()
                    case .stats:    CompactStatsTab()
                    case .info:     InfoTab()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 400, height: 580)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon)
                        Text(t.label).font(.callout)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(tab == t ? Color.accentColor.opacity(0.22) : Color.clear)
                    )
                    .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                    Text("Quit")
                    Text("⌘Q").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - Settings tab

struct SettingsTab: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var detector = KeyboardDetector.shared
    @ObservedObject var regionShare = RegionShareController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            preferencesSection
            shortcutsSection
            keyRemapSection
            regionShareSection
        }
    }

    private var regionShareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("REGION SHARE", icon: "rectangle.dashed")

            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share a portion of the screen").font(.body)
                    Text(regionShareStatusText)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                regionShareButton
            }

            if case .sharing = regionShare.state {
                SampleBufferPreviewView(
                    publisher: regionShare.framePublisher.eraseToAnyPublisher()
                )
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.green.opacity(0.5), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private var regionShareButton: some View {
        switch regionShare.state {
        case .idle, .error:
            Button("Select…") { regionShare.startSelection() }
        case .selecting:
            Button("Cancel") { regionShare.cancelSelection() }
        case .starting:
            ProgressView().controlSize(.small)
        case .sharing:
            Button("Stop") { Task { await regionShare.stop() } }
        }
    }

    private var regionShareStatusText: String {
        switch regionShare.state {
        case .idle:
            return "Capture a region; share its window in Teams or any app"
        case .selecting:
            return "Drag a rectangle on screen (or press Esc)"
        case .starting:
            return "Starting capture…"
        case .sharing:
            if let r = regionShare.currentRegion {
                return "Sharing \(Int(r.width)) × \(Int(r.height)) — pick the \"\(ShareWindowController.titleSentinel)\" window in Teams"
            }
            return "Sharing"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    private var keyRemapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("KEY REMAP", icon: "arrow.left.arrow.right")

            HStack(spacing: 10) {
                Image(systemName: "command.square")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swap ⌘ and ⌥").font(.body)
                    Text(remapStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $settings.swapCmdOptionMode) {
                    Text("Off").tag(SwapMode.off)
                    Text("Auto").tag(SwapMode.auto)
                    Text("On").tag(SwapMode.on)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
        }
    }

    private var remapStatusText: String {
        switch settings.swapCmdOptionMode {
        case .off:
            return "Disabled"
        case .on:
            return "Active — swap forced on"
        case .auto:
            return detector.hasLogitechKeyboard
                ? "Active — Logitech keyboard detected"
                : "Standby — no Logitech keyboard"
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("PREFERENCES", icon: "slider.horizontal.3")

            ToggleRow(
                icon: "keyboard",
                title: "Chatter Blocker",
                subtitle: "Filter rapid duplicate keypresses",
                isOn: $settings.enabled
            )

            HStack(spacing: 10) {
                Image(systemName: "ruler")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Threshold").font(.body)
                        Spacer()
                        Text("\(settings.thresholdMs) ms")
                            .monospacedDigit().bold()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.thresholdMs) },
                            set: { settings.thresholdMs = Int($0.rounded()) }
                        ),
                        in: Double(Settings.thresholdRange.lowerBound)...Double(Settings.thresholdRange.upperBound)
                    )
                    HStack {
                        Text("\(Settings.thresholdRange.lowerBound) ms")
                        Spacer()
                        Text("\(Settings.thresholdRange.upperBound) ms")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(settings.enabled ? 1 : 0.5)

            ToggleRow(
                icon: "macwindow",
                title: "Window Mover",
                subtitle: "Move/resize with modifiers + drag",
                isOn: $settings.windowMoverEnabled
            )
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("SHORTCUTS", icon: "command")

            HStack(spacing: 10) {
                Image(systemName: "keyboard.macwindow")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text("Modifiers").frame(width: 70, alignment: .leading)
                Spacer()
                modifierChip(.ctrl,   "⌃")
                modifierChip(.option, "⌥")
                modifierChip(.shift,  "⇧")
                modifierChip(.cmd,    "⌘")
            }

            ActionBinder(
                title: "Move",
                icon: "arrow.up.and.down.and.arrow.left.and.right",
                button: $settings.moveButton,
                other: $settings.resizeButton
            )

            ActionBinder(
                title: "Resize",
                icon: "arrow.up.left.and.arrow.down.right",
                button: $settings.resizeButton,
                other: $settings.moveButton
            )
        }
        .opacity(settings.windowMoverEnabled ? 1 : 0.5)
    }

    private func modifierChip(_ mask: ModifierMask, _ symbol: String) -> some View {
        let isOn = settings.windowMoverModifiers.contains(mask)
        return Button {
            if isOn {
                settings.windowMoverModifiers.remove(mask)
            } else {
                settings.windowMoverModifiers.insert(mask)
            }
        } label: {
            Text(symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.18))
                )
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
            Spacer()
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Action binder (Move/Resize)

struct ActionBinder: View {
    let title: String
    let icon: String
    @Binding var button: MouseButton
    @Binding var other: MouseButton

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title).frame(width: 70, alignment: .leading)
            Spacer()
            Picker("", selection: Binding(
                get: { button },
                set: { newValue in
                    if newValue != .unset && other == newValue {
                        other = .unset
                    }
                    button = newValue
                }
            )) {
                Text("None").tag(MouseButton.unset)
                Text("Left").tag(MouseButton.left)
                Text("Right").tag(MouseButton.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
        }
    }
}

// MARK: - Toggle row

struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                if let sub = subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
    }
}

// MARK: - Stats tab (compact)

struct CompactStatsTab: View {
    @ObservedObject var detector = ChatterDetector.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                stat("Blocked",   "\(detector.totalDropped)", .red)
                stat("Passed",    "\(detector.totalPassed)",  .secondary)
                stat("Threshold", "\(settings.thresholdMs) ms", .blue)
            }

            HStack {
                Button("Open detailed stats…") {
                    NotificationCenter.default.post(name: .openStatsWindow, object: nil)
                }
                Spacer()
                Button("Reset") { detector.reset() }
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "list.bullet").font(.caption2)
                Text("TOP BLOCKED KEYS")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                Spacer()
            }
            .foregroundStyle(.secondary)

            if topBlocked.isEmpty {
                Text("No blocks yet — type rapidly on a chattering switch to see entries here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 4) {
                    ForEach(topBlocked, id: \.id) { row in
                        HStack {
                            Text(row.name).frame(width: 80, alignment: .leading)
                            Spacer()
                            Text("\(row.drops)x")
                                .bold().monospacedDigit()
                                .foregroundStyle(.red)
                                .frame(width: 50, alignment: .trailing)
                            Text("min \(formatMs(row.minInterval))")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var topBlocked: [PerKeyRow] {
        detector.perKey
            .filter { $0.value.drops > 0 }
            .map { code, stats in
                PerKeyRow(id: code,
                          name: KeyCodeMap.name(for: code),
                          drops: stats.drops,
                          passes: stats.passes,
                          minInterval: stats.minInterval,
                          lastDropInterval: stats.lastDropInterval)
            }
            .sorted { $0.drops > $1.drops }
            .prefix(8)
            .map { $0 }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatMs(_ v: Double?) -> String {
        guard let v = v, v.isFinite else { return "—" }
        return String(format: "%.0f ms", v)
    }
}

// MARK: - Info tab

struct InfoTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("StopChattering").font(.title3).bold()
                    Text("v0.1.0").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                InfoRow(
                    icon: "keyboard",
                    title: "Chatter Blocker",
                    description: "Filters duplicate keypresses caused by faulty mechanical switches. Threshold-based per-key debounce."
                )
                InfoRow(
                    icon: "macwindow",
                    title: "Window Mover",
                    description: "Hold modifiers + drag any window. Configure modifier combo and which mouse button performs move/resize."
                )
            }

            Spacer(minLength: 4)

            Text("Requires Accessibility permission to read keyboard events and manipulate window frames.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
