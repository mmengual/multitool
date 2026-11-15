import AppKit
import SwiftUI

/// The monitor window: what the machine is doing right now, what is abnormal,
/// and who consumes what.
final class MonitorWindowController: NSObject, NSWindowDelegate {
    static let shared = MonitorWindowController()
    private var window: NSWindow?

    @MainActor
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        ResourceMonitor.shared.setWindowOpen(true)
        HelperClient.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Moniteur"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Orbe.fond)
        window.contentViewController = NSHostingController(rootView: MonitorRootView())
        window.setContentSize(NSSize(width: 1040, height: 760))
        window.center()
        window.setFrameAutosaveName("MultitoolMonitor")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in ResourceMonitor.shared.setWindowOpen(false) }
    }
}

struct MonitorRootView: View {
    @ObservedObject private var monitor = ResourceMonitor.shared
    @ObservedObject private var helper = HelperClient.shared
    @State private var axis: MonitorAxis = .cpu
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Orbe.filet).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Orbe.Space.s7) {
                    if !monitor.privileged, monitor.unreadable > 0 || helper.state != .enabled { accessBanner }
                    tiles
                    anomalies
                    consumers
                    if !monitor.suspects.isEmpty { suspects }
                }
                .padding(Orbe.Densite.marge)
            }
        }
        .background(Orbe.fond)
        .preferredColorScheme(.dark)
        .tint(Orbe.accent)
        .refreshEverySecond { helper.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Orbe.Space.s5) {
            VStack(alignment: .leading, spacing: Orbe.Space.s2) {
                Text("Moniteur").orbe(.titre2)
                Text("\(compte(monitor.processCount, "processus", "processus")) · mesure toutes les 2 s · 10 dernières minutes")
                    .orbe(.texte, Orbe.texte2)
            }
            Spacer()
            if monitor.privileged {
                OrbeBadge(ton: .hausse, text: "Lecture complète")
            } else {
                OrbeBadge(ton: .alerte, text: "Lecture limitée")
            }
        }
        .padding(.horizontal, Orbe.Densite.marge)
        .padding(.top, 40)
        .padding(.bottom, Orbe.Space.s6)
    }

    private var accessBanner: some View {
        OrbePanel {
            OrbeRow(title: "\(compte(monitor.unreadable, "processus système illisible", "processus système illisibles"))",
                    detail: accessDetail, icon: "lock.shield") {
                switch helper.state {
                case .needsApproval:
                    Button("Ouvrir les réglages") { helper.openApprovalSettings() }.buttonStyle(.orbePlein)
                case .enabled:
                    OrbeBadge(ton: .info, text: "Démarrage du service")
                case .unavailable:
                    EmptyView()
                case .notInstalled:
                    Button("Activer la lecture complète") { helper.install() }.buttonStyle(.orbePlein)
                }
            }
        }
    }

    private var accessDetail: String {
        switch helper.state {
        case .needsApproval:
            return "Autorisez « Multitool » dans Réglages Système → Général → Ouverture et extensions, section Autoriser en arrière-plan."
        case .unavailable(let reason):
            return reason
        default:
            return "macOS cache leurs compteurs à un utilisateur normal. Un service en lecture seule, lancé par macOS avec les droits système, peut les lire pour Multitool. Il ne modifie rien."
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let history = monitor.history
        let point = monitor.point
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Orbe.Space.s4)], spacing: Orbe.Space.s4) {
            MonitorTile(label: "Processeur",
                        value: point.map { Format.percent($0.cpu * 100) } ?? "—",
                        detail: "tous les cœurs",
                        values: history.map(\.cpu), ceiling: 1,
                        tone: (point?.cpu ?? 0) >= MonitorEngine.cpuSystem ? .alerte : .neutre)
            MonitorTile(label: "Mémoire",
                        value: point.map { Format.bytes($0.memoryUsed) } ?? "—",
                        detail: point.map { "sur \(Format.bytes($0.memoryTotal))\n\(pressure($0.memoryPressure))" } ?? "",
                        values: history.map { Double($0.memoryUsed) }, ceiling: Double(point?.memoryTotal ?? 1),
                        tone: (point?.memoryPressure ?? 1) >= 2 ? .alerte : .neutre)
            MonitorTile(label: "Swap",
                        value: point.map { Format.bytes($0.swap) } ?? "—",
                        detail: "mémoire sur le disque",
                        values: history.map { Double($0.swap) }, ceiling: nil,
                        tone: (point?.swap ?? 0) >= MonitorEngine.swapHigh ? .alerte : .neutre)
            MonitorTile(label: "Disque",
                        value: point.map { Format.rate($0.diskRead + $0.diskWrite) } ?? "—",
                        detail: point.map { "lu \(Format.rate($0.diskRead))\nécrit \(Format.rate($0.diskWrite))" } ?? "",
                        values: history.map { $0.diskRead + $0.diskWrite }, ceiling: nil, tone: .neutre)
            MonitorTile(label: "Réseau",
                        value: point.map { Format.rate($0.netIn + $0.netOut) } ?? "—",
                        detail: point.map { "reçu \(Format.rate($0.netIn))\nenvoyé \(Format.rate($0.netOut))" } ?? "",
                        values: history.map { $0.netIn + $0.netOut }, ceiling: nil, tone: .neutre)
            MonitorTile(label: "Température",
                        value: point.map { thermal($0.thermal) } ?? "—",
                        detail: "bridage thermique",
                        values: [], ceiling: nil,
                        tone: (point?.thermal.rawValue ?? 0) >= ProcessInfo.ThermalState.serious.rawValue ? .alerte : .neutre)
        }
    }

    private func pressure(_ level: Int) -> String {
        switch level {
        case 4: return "saturée"
        case 2: return "sous tension"
        default: return "pression normale"
        }
    }

    private func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normale"
        case .fair: return "Tiède"
        case .serious: return "Bridé"
        case .critical: return "Critique"
        @unknown default: return "—"
        }
    }

    // MARK: Anomalies

    private var anomalies: some View {
        OrbeSection(title: "Anormal",
                    note: "Un seuil doit être dépassé plusieurs minutes de suite avant d'apparaître ici : un pic bref n'est pas une anomalie.") {
            if monitor.anomalies.isEmpty {
                OrbeRow(title: monitor.point == nil ? "Première mesure en cours" : "Rien d'anormal") {
                    OrbeBadge(ton: monitor.point == nil ? .neutre : .hausse, text: monitor.point == nil ? "Patientez" : "RAS")
                }
            } else {
                ForEach(Array(monitor.anomalies.enumerated()), id: \.element.id) { index, anomaly in
                    if index > 0 { OrbeFilet() }
                    OrbeRow(title: anomaly.title, detail: anomaly.detail) {
                        OrbeBadge(ton: tone(anomaly.severity), text: label(anomaly.severity))
                    }
                }
            }
        }
    }

    private func tone(_ severity: Anomaly.Severity) -> OrbeBadge.Ton {
        switch severity {
        case .info: return .info
        case .alerte: return .alerte
        case .critique: return .baisse
        }
    }

    private func label(_ severity: Anomaly.Severity) -> String {
        switch severity {
        case .info: return "À savoir"
        case .alerte: return "Alerte"
        case .critique: return "Critique"
        }
    }

    // MARK: Consumers

    private var consumers: some View {
        let sorted = monitor.groups.sorted { $0.value(axis) > $1.value(axis) }.prefix(25)
        let maximum = max(sorted.first?.value(axis) ?? 0, 1e-9)
        return VStack(alignment: .leading, spacing: Orbe.Space.s3) {
            HStack {
                Text("CONSOMMATEURS, PAR APP").orbe(.label, Orbe.texte2).padding(.leading, Orbe.Space.s2)
                Spacer()
                OrbeSegmented(selection: $axis, options: MonitorAxis.allCases.map { ($0, $0.title) })
            }
            OrbePanel {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { OrbeFilet() }
                    GroupRow(group: group, axis: axis, maximum: maximum,
                             expanded: expanded.contains(group.id)) {
                        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                    }
                }
            }
            Text(axisNote).orbe(.texteS, Orbe.texte2).padding(.horizontal, Orbe.Space.s2)
        }
    }

    private var axisNote: String {
        switch axis {
        case .cpu: return "100 % correspond à un cœur entier. Les processus d'une même app sont additionnés."
        case .memory: return "Empreinte mémoire réelle, comme le Moniteur d'activité la compte."
        case .disk: return "Lecture · écriture. Les processus système n'apparaissent qu'en lecture complète."
        case .network: return "Reçu · envoyé, mesuré par nettop pendant que cette fenêtre est ouverte."
        case .energy: return "Puissance consommée par le processeur et le GPU pour l'app, en watts."
        }
    }

    // MARK: Suspects

    private var suspects: some View {
        OrbeSection(title: "Origine à vérifier",
                    note: "Ce n'est pas forcément malveillant : un outil de développement ou un script maison arrive souvent ici. Vérifiez que vous savez d'où vient chacun.") {
            ForEach(Array(monitor.suspects.enumerated()), id: \.element.id) { index, suspect in
                if index > 0 { OrbeFilet() }
                OrbeRow(title: suspect.info.displayName, detail: "\(suspect.reason)\n\(suspect.path)") {
                    Text(suspect.pids.map(String.init).joined(separator: ", ")).orbe(.donnee, Orbe.texte2)
                    Button("Afficher") { reveal(suspect.path) }.buttonStyle(.orbe)
                }
                .contextMenu { pathMenu(suspect.path) }
            }
        }
    }
}

// MARK: - Components

/// One machine-wide figure with its last ten minutes.
struct MonitorTile: View {
    let label: String
    let value: String
    let detail: String
    let values: [Double]
    let ceiling: Double?
    let tone: OrbeBadge.Ton

    var body: some View {
        OrbePanel {
            VStack(alignment: .leading, spacing: Orbe.Space.s2) {
                HStack {
                    Text(label.uppercased()).orbe(.label, Orbe.texte2)
                    Spacer()
                    if tone == .alerte {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Orbe.alerte)
                    }
                }
                Text(value).orbe(.donneeL, tone == .alerte ? Orbe.alerte : Orbe.texte)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(detail).orbe(.texteS, Orbe.texte2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                Sparkline(values: values, ceiling: ceiling, color: tone == .alerte ? Orbe.alerte : Orbe.texte2)
                    .frame(height: 28)
            }
            .padding(Orbe.Space.s5)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let ceiling: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let top = max(ceiling ?? (values.max() ?? 0), 1e-9)
            let count = max(values.count, 2)
            let step = geometry.size.width / CGFloat(ResourceMonitor.historyLength - 1)
            let offset = geometry.size.width - step * CGFloat(count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: offset + CGFloat(index) * step,
                        y: geometry.size.height * (1 - CGFloat(min(value / top, 1))))
            }
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.12))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, lineWidth: 1)
                }
                Rectangle().fill(Orbe.filet).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// An app and its processes, with a bar proportional to the top consumer.
struct GroupRow: View {
    let group: AppGroup
    let axis: MonitorAxis
    let maximum: Double
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: Orbe.Densite.ecart) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Orbe.texte2).frame(width: 10)
                    Image(nsImage: ExecutableCatalog.shared.icon(for: group.info))
                        .resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                        Text(group.info.displayName).orbe(.texte).lineLimit(1)
                        Text("\(compte(group.processes.count, "processus", "processus")) · \(group.info.signer.label)")
                            .orbe(.texteS, Orbe.texte2).lineLimit(1)
                    }
                    Spacer(minLength: Orbe.Space.s4)
                    bar.frame(width: 140)
                    Text(Format.value(group, axis)).orbe(.donnee)
                        .frame(width: 190, alignment: .trailing)
                }
                .padding(.horizontal, Orbe.Densite.padPanneau)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .contextMenu {
                if let path = group.info.appPath ?? group.processes.first?.path { pathMenu(path) }
            }

            if expanded {
                ForEach(group.processes.sorted { value($0) > value($1) }) { row in
                    OrbeFilet(inset: 62)
                    HStack(spacing: Orbe.Densite.ecart) {
                        Text(String(row.pid)).orbe(.donnee, Orbe.texte2).frame(width: 60, alignment: .leading)
                        Text(row.name).orbe(.texteS).lineLimit(1)
                        if row.uid == 0 { OrbeBadge(ton: .neutre, text: "root") }
                        Spacer()
                        Text(Format.value(row, axis)).orbe(.donnee, row.hasUsage ? Orbe.texte : Orbe.texte2)
                            .frame(width: 190, alignment: .trailing)
                    }
                    .padding(.leading, 62)
                    .padding(.trailing, Orbe.Densite.padPanneau)
                    .frame(height: 30)
                    .contextMenu { if let path = row.path { pathMenu(path, pid: row.pid) } }
                }
            }
        }
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Orbe.filet)
                Capsule().fill(Orbe.texte2)
                    .frame(width: max(2, geometry.size.width * CGFloat(min(group.value(axis) / maximum, 1))))
            }
        }
        .frame(height: 4)
    }

    private func value(_ row: ProcessRow) -> Double {
        switch axis {
        case .cpu: return row.cpu
        case .memory: return Double(row.memory)
        case .disk: return row.diskRead + row.diskWrite
        case .network: return row.netIn + row.netOut
        case .energy: return row.energy
        }
    }
}

@ViewBuilder
func pathMenu(_ path: String, pid: Int32? = nil) -> some View {
    Button("Afficher dans le Finder") { reveal(path) }
    Button("Copier le chemin") { copy(path) }
    if let pid { Button("Copier le PID") { copy(String(pid)) } }
}

func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
