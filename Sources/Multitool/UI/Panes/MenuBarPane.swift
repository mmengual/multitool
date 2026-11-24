import AppKit
import SwiftUI

struct MenuBarPane: View {
    @ObservedObject private var inventory = MenuBarInventory.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var visibility = MenuBarVisibility.shared
    @State private var accessibility = Permissions.accessibility
    @State private var hasBackup = MenuBarLayoutStore.hasBackup
    @State private var restoreNote: String?

    var body: some View {
        PaneForm {
            if !accessibility || (visibility.loaded && visibility.switches == nil) {
                OrbeSection(title: "Accès") {
                    if !accessibility {
                        OrbeRow(title: "Autorisation Accessibilité manquante",
                                detail: "Sans elle, Multitool ne peut ni lire les icônes de la barre des menus ni cliquer celles de la bande.") {
                            OrbeBadge(ton: .alerte, text: "À accorder")
                            Button("Autoriser", action: Permissions.openAccessibilitySettings)
                                .buttonStyle(.orbePlein)
                        }
                    }
                    if visibility.loaded && visibility.switches == nil {
                        if !accessibility { OrbeFilet() }
                        OrbeRow(title: "Masquage indisponible",
                                detail: "Cette version de Multitool n'a pas l'outil signé qui règle les interrupteurs de macOS. Les icônes restent dans la barre.") {
                            OrbeBadge(ton: .alerte, text: "Indisponible")
                        }
                    }
                }
            }

            OrbeSection(title: "Icônes", note: note) {
                MenuBarColumnHeader()
                let rows = self.rows
                if rows.isEmpty {
                    OrbeFilet()
                    OrbeRow(title: "Aucune icône lue")
                }
                ForEach(rows) { app in
                    OrbeFilet()
                    MenuBarAppRow(app: app, visibility: visibility, enabled: settings.menuBarEnabled,
                                  placement: visibility.placement(of: app.bundleID),
                                  switches: visibility.switches)
                }
            }

            if hasBackup {
                OrbeSection(title: "Ordre des icônes",
                            note: "Multitool 0.4 déplaçait les icônes. Il a gardé l'ordre de la barre d'avant son premier déplacement. Demande l'accès complet au disque.") {
                    OrbeRow(title: "Revenir à l'ordre d'origine", detail: restoreNote) {
                        Button("Restaurer") { restore() }.buttonStyle(.orbeDanger)
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private var note: String? {
        guard settings.menuBarEnabled else { return "Activez le module pour classer les icônes." }
        return "Sans case cochée, l'icône reste dans la barre. « Barre cachée » la retire de la barre et la range dans la bande ouverte par le chevron : un clic l'y fait revenir le temps de s'en servir. « Masquée » la retire aussi de la bande. Le réglage vaut pour toutes les icônes d'une même app."
    }

    /// Apps with a readable icon and classified apps that are not running.
    private var rows: [MenuBarApp] {
        var seen: Set<String> = []
        var result: [MenuBarApp] = []
        // A system process draws several icons: one row each. An app: one row.
        for item in inventory.items where seen.insert(item.isSystem ? item.id : item.bundleID).inserted {
            let name = item.isSystem && !item.label.isEmpty ? item.label : item.appName
            result.append(MenuBarApp(bundleID: item.isSystem ? item.id : item.bundleID, name: name, running: true))
        }
        for bundleID in settings.menuBarPlacements.keys.sorted() where seen.insert(bundleID).inserted {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            let name = running?.localizedName
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
                ?? bundleID
            result.append(MenuBarApp(bundleID: bundleID, name: name, running: running != nil))
        }
        // By name, the system icons last: a row never moves when its icon does (seen
        // on 24/11: sorted by position, rows jumped under the pointer at each change).
        return result.sorted {
            let (a, b) = ($0.bundleID.contains("#"), $1.bundleID.contains("#"))
            return a != b ? !a : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func refresh() {
        accessibility = Permissions.accessibility
        hasBackup = MenuBarLayoutStore.hasBackup
        inventory.refresh()
        visibility.loaded ? visibility.refreshFromBar() : visibility.apply()
    }

    private func restore() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = MenuBarLayoutStore.restoreBackup()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let applied = ok && MenuBarChevron.shared.forceLayoutRead()
                    restoreNote = applied ? "Ordre d'origine remis."
                        : "Échec : activez le module et accordez l'accès complet au disque à Multitool."
                    Log.menuBar.info("layout restored from the backup: \(ok)")
                }
            }
        }
    }
}

private let menuBarBoxWidth: CGFloat = 92

private struct MenuBarColumnHeader: View {
    var body: some View {
        HStack(spacing: Orbe.Densite.ecart) {
            Text("Icône").orbe(.label, Orbe.texte2)
            Spacer()
            Text("Barre cachée").orbe(.label, Orbe.texte2).frame(width: menuBarBoxWidth)
            Text("Masquée").orbe(.label, Orbe.texte2).frame(width: menuBarBoxWidth)
        }
        .padding(.horizontal, Orbe.Densite.padPanneau)
        .padding(.vertical, Orbe.Space.s3)
    }
}

/// One app: its icon, its name, where its icon is, and its 2 boxes.
private struct MenuBarAppRow: View {
    let app: MenuBarApp
    @ObservedObject var visibility: MenuBarVisibility
    let enabled: Bool
    // Passed so the row is drawn again when they change.
    let placement: MenuBarPlacement?
    let switches: [String: Bool]?

    private var bundleID: String { app.bundleID.components(separatedBy: "#")[0] }
    private var reason: String? { visibility.unclassifiableReason(bundleID) }

    private var detail: String {
        if let note = visibility.notes[bundleID] { return note }
        if let reason { return reason }
        if visibility.relaying.contains(bundleID) { return "Affichée le temps d'un clic" }
        if !app.running { return "App non lancée" }
        switch placement {
        case .hidden: return "Dans la barre cachée"
        case .masked: return "Masquée"
        case nil: return switches?[bundleID] == false ? "Éteinte dans Réglages Système" : "Dans la barre"
        }
    }

    var body: some View {
        HStack(spacing: Orbe.Densite.ecart) {
            Group {
                if app.bundleID.contains("#") {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Orbe.texte2)
                } else {
                    MenuBarAppIcon(bundleID: bundleID)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                Text(app.name).orbe(.texte)
                Text(detail).orbe(.texteS, visibility.notes[bundleID] == nil ? Orbe.texte2 : Orbe.alerte)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Orbe.Space.s3)
            if reason == nil {
                OrbeSwitch(isOn: Binding(
                    get: { placement != nil },
                    set: { visibility.set($0 ? .hidden : nil, for: bundleID) }))
                    .disabled(placement == .masked)
                    .frame(width: menuBarBoxWidth)
                OrbeSwitch(isOn: Binding(
                    get: { placement == .masked },
                    set: { visibility.set($0 ? .masked : .hidden, for: bundleID) }))
                    .frame(width: menuBarBoxWidth)
            }
        }
        .disabled(!enabled)
        .frame(minHeight: Orbe.Densite.ligne)
        .padding(.horizontal, Orbe.Densite.padPanneau)
        .padding(.vertical, Orbe.Space.s3)
    }
}
