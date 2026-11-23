import AppKit
import SwiftUI

struct MenuBarPane: View {
    @ObservedObject private var inventory = MenuBarInventory.shared
    @ObservedObject private var settings = Settings.shared
    @State private var accessibility = Permissions.accessibility

    var body: some View {
        PaneForm {
            if !accessibility {
                OrbeSection(title: "Accès") {
                    OrbeRow(title: "Autorisation Accessibilité manquante",
                            detail: "Sans elle, Multitool ne peut pas lire les icônes de la barre des menus.") {
                        OrbeBadge(ton: .alerte, text: "À accorder")
                        Button("Autoriser", action: Permissions.openAccessibilitySettings)
                            .buttonStyle(.orbePlein)
                    }
                }
            }

            OrbeSection(title: "Barre principale",
                        note: "Lecture seule pour l'instant : le classement des icônes arrive avec les prochaines versions.") {
                rows(for: inventory.items.filter { $0.zone == .main })
            }

            OrbeSection(title: "Barre cachée",
                        note: settings.menuBarEnabled
                            ? "Glissez le chevron avec ⌘ : tout ce qui est à sa gauche est caché." : nil) {
                let hidden = inventory.items.filter { $0.zone == .hidden }
                if !hidden.isEmpty {
                    rows(for: hidden)
                } else if inventory.overflowIndicator != nil && !inventory.overflowOpen {
                    OrbeRow(title: "Le déroulé de macOS est fermé",
                            detail: "Ses icônes ne sont lisibles que lorsqu'il est ouvert.")
                } else {
                    OrbeRow(title: "Aucune icône cachée")
                }
            }
        }
        .onAppear { inventory.refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            accessibility = Permissions.accessibility
            inventory.refresh()
        }
    }

    @ViewBuilder
    private func rows(for list: [MenuBarItem]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
            if index > 0 { OrbeFilet() }
            MenuBarItemRow(item: item)
        }
    }
}

/// An `OrbeRow` look-alike with the app icon in place of a SF Symbol.
private struct MenuBarItemRow: View {
    let item: MenuBarItem

    /// A system item is named by what it is ("Horloge"), not by the process that draws it.
    private var title: String { item.isSystem && !item.label.isEmpty ? item.label : item.appName }
    private var detail: String? {
        item.isSystem || item.label.isEmpty || item.label == item.appName ? nil : item.label
    }

    var body: some View {
        HStack(spacing: Orbe.Densite.ecart) {
            Group {
                if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(Orbe.texte2)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                Text(title).orbe(.texte)
                if let detail {
                    Text(detail).orbe(.texteS, Orbe.texte2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Orbe.Space.s3)
            if item.isSystem { OrbeBadge(ton: .neutre, text: "Système") }
        }
        .frame(minHeight: Orbe.Densite.ligne)
        .padding(.horizontal, Orbe.Densite.padPanneau)
        .padding(.vertical, Orbe.Space.s3)
    }
}
