import SwiftUI

struct StatsView: View {
    @ObservedObject var detector = ChatterDetector.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            thresholdSlider
            Divider()
            perKeySection
            Divider()
            recentSection
        }
        .padding()
        .frame(minWidth: 680, minHeight: 600)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            statBlock("Blocked", value: "\(detector.totalDropped)", tint: .red)
            statBlock("Passed (same-key)", value: "\(detector.totalPassed)", tint: .secondary)
            statBlock("Threshold", value: "\(settings.thresholdMs) ms", tint: .blue)
            Spacer()
            Button("Reset") { detector.reset() }
        }
    }

    private var thresholdSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Threshold").font(.callout)
                Spacer()
                Text("\(settings.thresholdMs) ms")
                    .font(.callout).monospacedDigit().bold()
            }
            Slider(
                value: Binding(
                    get: { Double(settings.thresholdMs) },
                    set: { settings.thresholdMs = Int($0.rounded()) }
                ),
                in: Double(Settings.thresholdRange.lowerBound)...Double(Settings.thresholdRange.upperBound),
                step: 1
            )
            HStack {
                Text("\(Settings.thresholdRange.lowerBound) ms")
                Spacer()
                Text("\(Settings.thresholdRange.upperBound) ms")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statBlock(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private var perKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-key").font(.headline)
            if perKeyRows.isEmpty {
                Text("No same-key activity yet. Start typing.")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
            } else {
                Table(perKeyRows) {
                    TableColumn("Key") { Text($0.name) }
                    TableColumn("Blocked") { Text("\($0.drops)").monospacedDigit() }
                    TableColumn("Passed") { Text("\($0.passes)").monospacedDigit() }
                    TableColumn("Min interval") { Text(formatMs($0.minInterval)).monospacedDigit() }
                    TableColumn("Last block") { Text(formatMs($0.lastDropInterval)).monospacedDigit() }
                }
                .frame(minHeight: 160)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent intervals (< \(Int(ChatterDetector.observationWindowMs)) ms)")
                .font(.headline)
            if recentRows.isEmpty {
                Text("No close intervals recorded yet.")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
            } else {
                Table(recentRows) {
                    TableColumn("Time") { Text($0.timeString).monospacedDigit() }
                    TableColumn("Key") { Text($0.keyName) }
                    TableColumn("Interval") { row in
                        Text(String(format: "%.1f ms", row.intervalMs))
                            .monospacedDigit()
                            .foregroundStyle(row.wasDropped ? .red : .primary)
                    }
                    TableColumn("Action") { row in
                        Text(row.wasDropped ? "Blocked" : "Passed")
                            .foregroundStyle(row.wasDropped ? .red : .secondary)
                    }
                }
                .frame(minHeight: 180)
            }
        }
    }

    private var perKeyRows: [PerKeyRow] {
        detector.perKey
            .map { code, stats in
                PerKeyRow(id: code,
                          name: KeyCodeMap.name(for: code),
                          drops: stats.drops,
                          passes: stats.passes,
                          minInterval: stats.minInterval,
                          lastDropInterval: stats.lastDropInterval)
            }
            .sorted { ($0.drops, $0.passes) > ($1.drops, $1.passes) }
    }

    private var recentRows: [RecentRow] {
        detector.recentEvents.suffix(100).reversed().map { e in
            RecentRow(id: e.id,
                      timeString: Self.timeFormatter.string(from: e.timestamp),
                      keyName: KeyCodeMap.name(for: e.keyCode),
                      intervalMs: e.intervalMs,
                      wasDropped: e.wasDropped)
        }
    }

    private func formatMs(_ v: Double?) -> String {
        guard let v = v, v.isFinite else { return "—" }
        return String(format: "%.1f ms", v)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

struct PerKeyRow: Identifiable {
    let id: Int64
    let name: String
    let drops: Int
    let passes: Int
    let minInterval: Double?
    let lastDropInterval: Double?
}

struct RecentRow: Identifiable {
    let id: UUID
    let timeString: String
    let keyName: String
    let intervalMs: Double
    let wasDropped: Bool
}
