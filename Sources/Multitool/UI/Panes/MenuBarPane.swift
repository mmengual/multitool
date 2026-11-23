import AppKit
import SwiftUI

struct MenuBarPane: View {
    @ObservedObject private var inventory = MenuBarInventory.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var classifier = MenuBarClassifier.shared
    @State private var accessibility = Permissions.accessibility
    @State private var layoutAccess = true
    @State private var freeSpace = MenuBarChevron.shared.freeSpace
    @State private var hasBackup = MenuBarLayoutStore.hasBackup

    var body: some View {
        PaneForm {
            if !accessibility || !layoutAccess {
                OrbeSection(title: "Accès") {
                    if !accessibility {
                        OrbeRow(title: "Autorisation Accessibilité manquante",
                                detail: "Sans elle, Multitool ne peut pas lire les icônes de la barre des menus.") {
                            OrbeBadge(ton: .alerte, text: "À accorder")
                            Button("Autoriser", action: Permissions.openAccessibilitySettings)
                                .buttonStyle(.orbePlein)
                        }
                    }
                    if !accessibility && !layoutAccess { OrbeFilet() }
                    if !layoutAccess {
                        OrbeRow(title: "Accès à la disposition de la barre",
                                detail: "macOS garde l'ordre des icônes dans un dossier protégé. Avec l'accès complet au disque, Multitool range une icône sans prendre le curseur. Sans lui, il la glisse avec ⌘, ce qui prend le curseur moins d'une seconde.") {
                            Button("Choisir le dossier") { layoutAccess = MenuBarLayoutStore.requestAccess() }
                                .buttonStyle(.orbe)
                            Button("Accès complet au disque", action: MenuBarLayoutStore.openFullDiskAccessSettings)
                                .buttonStyle(.orbePlein)
                        }
                    }
                }
            }

            OrbeSection(title: "Icônes", note: note) {
                OrbeRow(title: "Place libre dans la barre principale", detail: freeSpaceDetail) {
                    Button("Ranger maintenant", action: classifier.arrangeAll)
                        .buttonStyle(.orbe)
                        .disabled(!settings.menuBarEnabled || !classifier.busy.isEmpty)
                }
                OrbeFilet()
                MenuBarColumnHeader()
                let rows = classifier.rows
                if rows.isEmpty {
                    OrbeFilet()
                    OrbeRow(title: "Aucune icône lue")
                }
                ForEach(rows) { item in
                    OrbeFilet()
                    MenuBarItemRow(item: item, classifier: classifier, enabled: settings.menuBarEnabled,
                                   placements: settings.menuBarPlacements)
                }
                if inventory.overflowIndicator != nil && inventory.lastFullScan == nil {
                    OrbeFilet()
                    OrbeRow(title: "Icônes cachées pas encore lues",
                            detail: "Multitool les lit à l'ouverture de cette page ou de la bande.")
                }
            }

            if hasBackup {
                OrbeSection(title: "Disposition d'origine",
                            note: "Multitool a gardé l'ordre de la barre tel qu'il était avant son premier rangement.") {
                    OrbeRow(title: "Revenir à la disposition d'origine",
                            detail: "Remet chaque icône à sa place d'avant. Les cases suivent la barre.") {
                        Button("Restaurer") { restore() }.buttonStyle(.orbeDanger)
                    }
                }
            }
        }
        .onAppear { refresh(readHidden: true) }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in refresh(readHidden: false) }
    }

    private var note: String? {
        guard settings.menuBarEnabled else { return "Activez le module pour classer les icônes." }
        return "Sans case cochée, une icône reste dans la barre principale. « Barre cachée » la range dans la bande ouverte par le chevron. « Masquée » la cache aussi de la bande."
    }

    private var freeSpaceDetail: String {
        guard settings.menuBarEnabled else { return "Module désactivé." }
        guard let freeSpace else { return "Écran sans encoche : rien n'est caché ici, et rien n'est refusé." }
        return "\(Int(freeSpace)) pt entre l'encoche et vos icônes. Une icône en prend environ 25."
    }

    /// Light scan every 3 s. On appearing, the hidden icons are read too if the cache
    /// is stale: the native overflow opens for about 150 ms.
    private func refresh(readHidden: Bool) {
        accessibility = Permissions.accessibility
        freeSpace = MenuBarChevron.shared.freeSpace
        hasBackup = MenuBarLayoutStore.hasBackup
        inventory.refresh {
            layoutAccess = inventory.layoutAccess
            guard readHidden, settings.menuBarEnabled, inventory.overflowIndicator != nil, inventory.cacheStale else { return }
            inventory.fullScan { _ in }
        }
    }

    private func restore() {
        MenuBarOverflow.queue.async {
            MenuBarOverflow.setArranging(true)
            let ok = MenuBarLayoutStore.restoreBackup()
            // Icons may come back to the main bar: the chevron makes room first, then
            // computes its length again from its new place.
            DispatchQueue.main.sync { MainActor.assumeIsolated { MenuBarChevron.shared.forceLayoutRead(shrinkBy: 120) } }
            Thread.sleep(forTimeInterval: 2)
            MenuBarOverflow.setArranging(false)
            Log.menuBar.info("layout restored from the backup: \(ok)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MenuBarChevron.shared.arrangementEnded()
                    MenuBarInventory.shared.markStale("layout restored")
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

/// One icon: its image, its name, where it is, and its 2 boxes.
private struct MenuBarItemRow: View {
    let item: MenuBarItem
    @ObservedObject var classifier: MenuBarClassifier
    let enabled: Bool
    /// Passed so the row is drawn again when a choice changes.
    let placements: [String: String]

    /// A system item is named by what it is ("Horloge"), not by the process that draws it.
    private var title: String { item.isSystem && !item.label.isEmpty ? item.label : item.appName }
    private var key: String { item.placementKey }
    private var inventoryHasAccess: Bool { MenuBarInventory.shared.layoutAccess }
    private var zoneText: String {
        classifier.actualSide(of: item) == .hidden ? "Dans la barre cachée" : "Dans la barre principale"
    }

    private var detail: String {
        if let note = classifier.notes[key] { return note }
        if classifier.busy.contains(key) { return "Déplacement en cours…" }
        if classifier.isFixed(item) { return "Toujours dans la barre principale : macOS ne la déplace pas." }
        if item.layoutKeys.isEmpty && inventoryHasAccess { return zoneText + " · déplacée par glisser ⌘, faute d'entrée dans la table de macOS" }
        return zoneText
    }

    var body: some View {
        let placement = classifier.shownPlacement(of: item)
        HStack(spacing: Orbe.Densite.ecart) {
            MenuBarItemIcon(item: item).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                Text(title).orbe(.texte)
                Text(detail).orbe(.texteS, classifier.notes[key] == nil ? Orbe.texte2 : Orbe.alerte)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Orbe.Space.s3)
            if classifier.isNew(item) {
                OrbeBadge(ton: .info, text: "Nouvelle")
                Button("Garder ici") { classifier.keep(item) }.buttonStyle(OrbeButtonStyle(variante: .discret, compact: true))
            }
            if !classifier.isFixed(item) {
                OrbeSwitch(isOn: Binding(
                    get: { placement != .main },
                    set: { classifier.set($0 ? .hidden : .main, for: item) }))
                    .disabled(placement == .masked)
                    .frame(width: menuBarBoxWidth)
                OrbeSwitch(isOn: Binding(
                    get: { placement == .masked },
                    set: { classifier.set($0 ? .masked : .hidden, for: item) }))
                    .frame(width: menuBarBoxWidth)
            }
        }
        .disabled(!enabled || classifier.busy.contains(key))
        .frame(minHeight: Orbe.Densite.ligne)
        .padding(.horizontal, Orbe.Densite.padPanneau)
        .padding(.vertical, Orbe.Space.s3)
    }
}

/// The application's icon, or a symbol for a system icon that has none.
struct MenuBarItemIcon: View {
    let item: MenuBarItem

    var body: some View {
        if let symbol = item.systemSymbol {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Orbe.texte)
        } else if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
            Image(nsImage: icon).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(Orbe.texte2)
        }
    }
}

extension MenuBarItem {
    /// SF Symbol for an Apple icon whose process has no application icon. nil for a
    /// third-party app. The first candidate that exists on this macOS is used.
    var systemSymbol: String? {
        guard isSystem || bundleID.hasPrefix("com.apple.") else { return nil }
        let text = (layoutKeys.joined(separator: " ") + " " + axIdentifier + " " + bundleID).lowercased()
        let table: [(String, [String])] = [
            ("wifi", ["wifi"]),
            ("battery", ["battery.100percent", "battery.100"]),
            ("bluetooth", ["bluetooth", "dot.radiowaves.left.and.right"]),
            ("clock", ["clock"]),
            ("bentobox", ["switch.2"]), ("controlcenter", ["switch.2"]),
            ("sound", ["speaker.wave.2.fill"]),
            ("focus", ["moon.fill"]),
            ("nowplaying", ["play.circle"]),
            ("userswitcher", ["person.crop.circle"]),
            ("audiovideo", ["mic.fill"]),
            ("textinput", ["keyboard"]),
            ("campo", ["magnifyingglass"]),
            ("vpn", ["network"]),
            ("ssmenuagent", ["rectangle.on.rectangle"]),
        ]
        for (needle, candidates) in table where text.contains(needle) {
            if let found = candidates.first(where: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }) {
                return found
            }
        }
        return isSystem ? "square.grid.2x2" : nil
    }
}
