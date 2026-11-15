import AppKit
import Combine
import MultitoolShared

// MARK: - Model

enum MonitorAxis: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, energy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "Processeur"
        case .memory: return "Mémoire"
        case .disk: return "Disque"
        case .network: return "Réseau"
        case .energy: return "Énergie"
        }
    }
}

struct ProcessRow: Identifiable {
    let id: String
    let pid: Int32
    let name: String
    let path: String?
    let uid: UInt32
    let hasUsage: Bool
    var cpu: Double = 0          // % of one core
    var memory: UInt64 = 0
    var diskRead: Double = 0     // bytes/s
    var diskWrite: Double = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var energy: Double = 0       // watts
}

struct AppGroup: Identifiable {
    let id: String
    let info: ExecutableInfo
    var processes: [ProcessRow] = []
    var cpu: Double = 0
    var memory: UInt64 = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var energy: Double = 0

    func value(_ axis: MonitorAxis) -> Double {
        switch axis {
        case .cpu: return cpu
        case .memory: return Double(memory)
        case .disk: return diskRead + diskWrite
        case .network: return netIn + netOut
        case .energy: return energy
        }
    }
}

struct SystemPoint {
    let time: Date
    let cpu: Double              // 0...1, all cores
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let memoryPressure: Int
    let swap: UInt64
    let diskRead: Double
    let diskWrite: Double
    let netIn: Double
    let netOut: Double
    let thermal: ProcessInfo.ThermalState
}

struct Anomaly: Identifiable, Equatable {
    enum Severity: Int { case info, alerte, critique }
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    var groupID: String? = nil
}

struct Suspect: Identifiable {
    let id: String
    let info: ExecutableInfo
    let path: String
    let reason: String
    let pids: [Int32]
}

struct MonitorResult {
    var groups: [AppGroup]
    var point: SystemPoint
    var anomalies: [Anomaly]
    var suspects: [Suspect]
    var privileged: Bool
    var unreadable: Int
    var processCount: Int
}

// MARK: - Engine

/// Turns successive samples into rates, groups and anomalies. Its state (the
/// previous sample, how long a threshold has been crossed) lives in an actor,
/// off the main thread.
actor MonitorEngine {
    // Thresholds of the anomalies. Values to tune with use.
    static let cpuGroup = 80.0            // % of one core
    static let cpuGroupFor: TimeInterval = 120
    static let cpuSystem = 0.9
    static let cpuSystemFor: TimeInterval = 60
    static let diskWrite = 40.0 * 1_048_576
    static let diskWriteFor: TimeInterval = 60
    static let leakWindow: TimeInterval = 600
    static let leakGrowth: UInt64 = 1 << 30
    static let swapHigh: UInt64 = 4 << 30
    static let secureInputFor: TimeInterval = 30

    private var previous: ProcessSnapshot?
    private var previousReading: SystemReading?
    private var cpuSince: [String: Date] = [:]
    private var diskSince: [String: Date] = [:]
    private var systemCpuSince: Date?
    private var footprints: [String: [(Date, UInt64)]] = [:]
    private var secureInput: (pid: Int32, since: Date)?

    func ingest(snapshot: ProcessSnapshot, network: [Int32: (inRate: Double, outRate: Double)]) -> MonitorResult {
        let reading = SystemStats.read()
        let now = reading.time
        let elapsed = previous.map { Double(snapshot.time &- $0.time) / 1e9 } ?? 0
        let before = Dictionary(previous?.processes.map { ($0.key, $0) } ?? [], uniquingKeysWith: { a, _ in a })

        var groups: [String: AppGroup] = [:]
        var suspects: [String: Suspect] = [:]
        var unreadable = 0
        var diskReadTotal = 0.0, diskWriteTotal = 0.0

        let byPid = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for sample in snapshot.processes {
            var info = ExecutableCatalog.shared.info(for: sample)
            // An XPC service or extension (WebKit, Quick Look…) counts for the app
            // responsible for it. Command-line tools keep their own line, even when
            // launched from a terminal app.
            let isService = sample.path.map { $0.contains(".xpc/") || $0.contains(".appex/") } ?? false
            if isService, info.appPath == nil || info.signer == .apple, let owner = sample.responsible.flatMap({ byPid[$0] }) {
                let ownerInfo = ExecutableCatalog.shared.info(for: owner)
                if ownerInfo.appPath != nil { info = ownerInfo.asGroup(keeping: info) }
            }
            var row = ProcessRow(id: sample.key, pid: sample.pid, name: sample.name, path: sample.path,
                                 uid: sample.uid, hasUsage: sample.hasUsage)
            if sample.hasUsage {
                row.memory = sample.footprint
                if let old = before[sample.key], old.hasUsage, elapsed > 0 {
                    row.cpu = Double(sample.cpuNs &- old.cpuNs) / (elapsed * 1e9) * 100
                    row.diskRead = Double(sample.diskRead &- old.diskRead) / elapsed
                    row.diskWrite = Double(sample.diskWritten &- old.diskWritten) / elapsed
                    row.energy = Double(sample.energyNj &- old.energyNj) / (elapsed * 1e9)
                }
            } else {
                unreadable += 1
            }
            if let rate = network[sample.pid] {
                row.netIn = rate.inRate
                row.netOut = rate.outRate
            }
            diskReadTotal += row.diskRead
            diskWriteTotal += row.diskWrite

            var group = groups[info.groupKey] ?? AppGroup(id: info.groupKey, info: info)
            group.processes.append(row)
            group.cpu += row.cpu
            group.memory += row.memory
            group.diskRead += row.diskRead
            group.diskWrite += row.diskWrite
            group.netIn += row.netIn
            group.netOut += row.netOut
            group.energy += row.energy
            groups[info.groupKey] = group

            if let reason = info.suspicion, let path = sample.path {
                var suspect = suspects[path] ?? Suspect(id: path, info: info, path: path, reason: reason, pids: [])
                suspect = Suspect(id: path, info: info, path: path, reason: reason, pids: suspect.pids + [sample.pid])
                suspects[path] = suspect
            }
        }

        let netIn = previousReading.map { rate(reading.networkIn, $0.networkIn, now.timeIntervalSince($0.time)) } ?? 0
        let netOut = previousReading.map { rate(reading.networkOut, $0.networkOut, now.timeIntervalSince($0.time)) } ?? 0
        let point = SystemPoint(time: now, cpu: reading.cpu, memoryUsed: reading.memoryUsed,
                                memoryTotal: reading.memoryTotal, memoryPressure: reading.memoryPressure,
                                swap: reading.swapUsed, diskRead: diskReadTotal, diskWrite: diskWriteTotal,
                                netIn: netIn, netOut: netOut, thermal: reading.thermal)

        let sortedGroups = groups.values.sorted { $0.cpu > $1.cpu }
        let anomalies = elapsed > 0
            ? detect(groups: sortedGroups, point: point, reading: reading, snapshot: snapshot, now: now)
            : []

        previous = snapshot
        previousReading = reading
        return MonitorResult(groups: sortedGroups, point: point, anomalies: anomalies,
                             suspects: suspects.values.sorted { $0.info.displayName < $1.info.displayName },
                             privileged: snapshot.privileged, unreadable: unreadable,
                             processCount: snapshot.processes.count)
    }

    private func rate(_ now: UInt64, _ before: UInt64, _ seconds: TimeInterval) -> Double {
        guard seconds > 0, now >= before else { return 0 }
        return Double(now - before) / seconds
    }

    // MARK: Anomalies

    private func detect(groups: [AppGroup], point: SystemPoint, reading: SystemReading,
                        snapshot: ProcessSnapshot, now: Date) -> [Anomaly] {
        var found: [Anomaly] = []
        let current = Set(groups.map(\.id))

        // A process group burning CPU for minutes.
        for group in groups {
            if group.cpu >= Self.cpuGroup {
                let since = cpuSince[group.id] ?? now
                cpuSince[group.id] = since
                let duration = now.timeIntervalSince(since)
                if duration >= Self.cpuGroupFor {
                    found.append(Anomaly(
                        id: "cpu-\(group.id)", severity: group.cpu >= 300 ? .critique : .alerte,
                        title: "\(group.info.displayName) occupe le processeur",
                        detail: "\(Format.percent(group.cpu)) d'un cœur depuis \(Format.duration(duration)).",
                        groupID: group.id))
                }
            } else {
                cpuSince[group.id] = nil
            }

            // Writing to disk at a sustained high rate.
            if group.diskWrite >= Self.diskWrite {
                let since = diskSince[group.id] ?? now
                diskSince[group.id] = since
                let duration = now.timeIntervalSince(since)
                if duration >= Self.diskWriteFor {
                    found.append(Anomaly(
                        id: "disk-\(group.id)", severity: .alerte,
                        title: "\(group.info.displayName) écrit beaucoup sur le disque",
                        detail: "\(Format.rate(group.diskWrite)) depuis \(Format.duration(duration)).",
                        groupID: group.id))
                }
            } else {
                diskSince[group.id] = nil
            }

            // Memory that keeps growing: a probable leak.
            var history = footprints[group.id, default: []]
            history.append((now, group.memory))
            history.removeAll { now.timeIntervalSince($0.0) > Self.leakWindow }
            footprints[group.id] = history
            if let first = history.first, now.timeIntervalSince(first.0) >= Self.leakWindow * 0.8,
               let lowest = history.map(\.1).min(), group.memory > lowest + Self.leakGrowth {
                let middle = history[history.count / 2].1
                if middle > lowest && group.memory > middle {
                    found.append(Anomaly(
                        id: "leak-\(group.id)", severity: .alerte,
                        title: "\(group.info.displayName) grossit sans cesse en mémoire",
                        detail: "+\(Format.bytes(group.memory - lowest)) en \(Format.duration(now.timeIntervalSince(first.0))), \(Format.bytes(group.memory)) au total. Probable fuite mémoire : relancer l'app la libère.",
                        groupID: group.id))
                }
            }
        }
        cpuSince = cpuSince.filter { current.contains($0.key) }
        diskSince = diskSince.filter { current.contains($0.key) }
        footprints = footprints.filter { current.contains($0.key) }

        // The whole machine saturated.
        if point.cpu >= Self.cpuSystem {
            let since = systemCpuSince ?? now
            systemCpuSince = since
            if now.timeIntervalSince(since) >= Self.cpuSystemFor {
                let top = groups.prefix(3).map { "\($0.info.displayName) \(Format.percent($0.cpu))" }.joined(separator: ", ")
                found.append(Anomaly(id: "cpu-system", severity: .critique,
                                     title: "Processeur saturé",
                                     detail: "\(Format.percent(point.cpu * 100)) depuis \(Format.duration(now.timeIntervalSince(since))). En tête : \(top)."))
            }
        } else {
            systemCpuSince = nil
        }

        if point.memoryPressure >= 2 {
            let top = groups.sorted { $0.memory > $1.memory }.prefix(3)
                .map { "\($0.info.displayName) \(Format.bytes($0.memory))" }.joined(separator: ", ")
            found.append(Anomaly(id: "memory-pressure", severity: point.memoryPressure >= 4 ? .critique : .alerte,
                                 title: point.memoryPressure >= 4 ? "Mémoire saturée" : "Mémoire sous tension",
                                 detail: "macOS compresse et déplace la mémoire sur le disque, tout ralentit. Plus gros consommateurs : \(top)."))
        }
        if point.swap >= Self.swapHigh {
            found.append(Anomaly(id: "swap", severity: .alerte, title: "Swap élevé",
                                 detail: "\(Format.bytes(point.swap)) de mémoire déplacée sur le disque."))
        }

        switch point.thermal {
        case .serious:
            found.append(Anomaly(id: "thermal", severity: .alerte, title: "Mac bridé par la chaleur",
                                 detail: "macOS réduit la vitesse du processeur pour le refroidir."))
        case .critical:
            found.append(Anomaly(id: "thermal", severity: .critique, title: "Surchauffe",
                                 detail: "macOS bride fortement le processeur."))
        default: break
        }

        // An app holding Secure Input blocks global shortcuts and key remappers.
        if let pid = reading.secureInputPID, pid > 0 {
            let since = secureInput?.pid == pid ? secureInput!.since : now
            secureInput = (pid, since)
            if now.timeIntervalSince(since) >= Self.secureInputFor {
                let name = snapshot.processes.first { $0.pid == pid }
                    .map { ExecutableCatalog.shared.info(path: $0.path, name: $0.name).displayName } ?? "PID \(pid)"
                found.append(Anomaly(id: "secure-input", severity: .info,
                                     title: "\(name) bloque les raccourcis globaux",
                                     detail: "Saisie sécurisée active depuis \(Format.duration(now.timeIntervalSince(since))). Un champ de mot de passe reste sans doute ouvert : le fermer, ou quitter l'app, rétablit les raccourcis."))
            }
        } else {
            secureInput = nil
        }

        return found.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }
}

// MARK: - Monitor

/// Samples the machine on a timer and publishes the result for the views. It
/// watches in the background every 5 s, to flag anomalies in the menu bar, and
/// every 2 s while the monitor window is open.
@MainActor
final class ResourceMonitor: ObservableObject {
    static let shared = ResourceMonitor()
    static let historyLength = 300

    @Published private(set) var groups: [AppGroup] = []
    @Published private(set) var point: SystemPoint?
    @Published private(set) var history: [SystemPoint] = []
    @Published private(set) var anomalies: [Anomaly] = []
    @Published private(set) var suspects: [Suspect] = []
    @Published private(set) var privileged = false
    @Published private(set) var unreadable = 0
    @Published private(set) var processCount = 0

    private let engine = MonitorEngine()
    private let network = NetworkSampler()
    private var timer: Timer?
    private var windowOpen = false
    private var backgroundEnabled = false
    private var sampling = false

    func setBackgroundEnabled(_ enabled: Bool) {
        backgroundEnabled = enabled
        reschedule()
    }

    func setWindowOpen(_ open: Bool) {
        windowOpen = open
        network.reset()
        reschedule()
        if open { tick() }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard windowOpen || backgroundEnabled else { return }
        let interval: TimeInterval = windowOpen ? 2 : 5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = interval / 5
    }

    private func tick() {
        guard !sampling else { return }
        sampling = true
        let engine = engine, network = network, withNetwork = windowOpen
        Task {
            let snapshot: ProcessSnapshot
            if let privileged = await HelperClient.shared.snapshot() {
                snapshot = privileged
            } else {
                snapshot = await Task.detached(priority: .utility) { ProcessSampler.snapshot() }.value
            }
            let rates = withNetwork
                ? await Task.detached(priority: .utility) { network.sample() }.value
                : [:]
            let result = await engine.ingest(snapshot: snapshot, network: rates)
            publish(result)
            sampling = false
        }
    }

    private func publish(_ result: MonitorResult) {
        groups = result.groups
        point = result.point
        history.append(result.point)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        if anomalies != result.anomalies { anomalies = result.anomalies }
        suspects = result.suspects
        privileged = result.privileged
        unreadable = result.unreadable
        processCount = result.processCount
    }

    /// One line for the popover and the menu bar tooltip.
    var summary: String {
        if let first = anomalies.first {
            return anomalies.count == 1 ? first.title : "\(first.title), et \(compte(anomalies.count - 1, "autre"))"
        }
        guard let point else { return "Analyse en cours" }
        return "Rien d'anormal · processeur \(Format.percent(point.cpu * 100))"
    }
}

// MARK: - Formatting

enum Format {
    /// French units: o, Ko, Mo, Go, To, binary multiples like macOS memory figures.
    static func bytes(_ value: UInt64) -> String { size(Double(value), base: 1024) }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "0 o/s" : size(bytesPerSecond, base: 1000) + "/s"
    }

    private static func size(_ value: Double, base: Double) -> String {
        let units = ["o", "Ko", "Mo", "Go", "To"]
        var value = value, index = 0
        while value >= base && index < units.count - 1 { value /= base; index += 1 }
        let digits = index == 0 || value >= 100 ? 0 : value >= 10 ? 1 : 2
        let number = String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
        return "\(number) \(units[index])"
    }

    static func percent(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f %%", value).replacingOccurrences(of: ".", with: ",")
                   : String(format: "%.0f %%", value)
    }

    static func watts(_ value: Double) -> String {
        value < 10 ? String(format: "%.2f W", value).replacingOccurrences(of: ".", with: ",")
                   : String(format: "%.0f W", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "\(Int(seconds)) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    static func value(_ group: AppGroup, _ axis: MonitorAxis) -> String {
        switch axis {
        case .cpu: return percent(group.cpu)
        case .memory: return bytes(group.memory)
        case .disk: return "\(rate(group.diskRead)) · \(rate(group.diskWrite))"
        case .network: return "\(rate(group.netIn)) · \(rate(group.netOut))"
        case .energy: return watts(group.energy)
        }
    }

    static func value(_ row: ProcessRow, _ axis: MonitorAxis) -> String {
        guard row.hasUsage || axis == .network else { return "illisible" }
        switch axis {
        case .cpu: return percent(row.cpu)
        case .memory: return bytes(row.memory)
        case .disk: return "\(rate(row.diskRead)) · \(rate(row.diskWrite))"
        case .network: return "\(rate(row.netIn)) · \(rate(row.netOut))"
        case .energy: return watts(row.energy)
        }
    }
}
