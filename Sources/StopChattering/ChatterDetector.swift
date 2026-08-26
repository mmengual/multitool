import Foundation
import Combine

struct KeyEvent: Identifiable {
    let id = UUID()
    let keyCode: Int64
    let timestamp: Date
    let intervalMs: Double
    let wasDropped: Bool
}

struct KeyStats {
    var drops: Int = 0
    var passes: Int = 0
    var lastDropInterval: Double? = nil
    var minInterval: Double? = nil
}

@MainActor
final class ChatterDetector: ObservableObject {
    static let shared = ChatterDetector()

    @Published private(set) var recentEvents: [KeyEvent] = []
    @Published private(set) var perKey: [Int64: KeyStats] = [:]
    @Published private(set) var totalDropped: Int = 0
    @Published private(set) var totalPassed: Int = 0

    // Only keep events with an interval below this in the recent-events list.
    static let observationWindowMs: Double = 250
    private let maxEvents = 500

    func record(keyCode: Int64, intervalMs: Double, wasDropped: Bool) {
        var stats = perKey[keyCode] ?? KeyStats()
        if wasDropped {
            stats.drops += 1
            stats.lastDropInterval = intervalMs
            totalDropped += 1
        } else {
            stats.passes += 1
            totalPassed += 1
        }
        stats.minInterval = min(stats.minInterval ?? .infinity, intervalMs)
        perKey[keyCode] = stats

        if intervalMs < Self.observationWindowMs {
            let event = KeyEvent(keyCode: keyCode, timestamp: Date(),
                                 intervalMs: intervalMs, wasDropped: wasDropped)
            recentEvents.append(event)
            if recentEvents.count > maxEvents {
                recentEvents.removeFirst(recentEvents.count - maxEvents)
            }
        }
    }

    func reset() {
        recentEvents.removeAll()
        perKey.removeAll()
        totalDropped = 0
        totalPassed = 0
    }
}
