import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = ClipboardStore.shared
    @State private var accessibility = Permissions.accessibility
    @State private var confirmClear = false

    var body: some View {
        PaneForm {
            OrbeSection(title: "Accès",
                        note: "Le raccourci ouvre l'historique par-dessus l'app en cours. ↩ colle, ⌥↩ colle en texte brut, ⌘1 à ⌘9 collent directement l'un des 9 premiers éléments, ⌘P épingle.") {
                OrbeRow(title: "Raccourci") {
                    HotKeyRecorder(combo: $settings.clipboardHotKey)
                }
                OrbeFilet()
                OrbeRow(title: "Coller directement l'élément choisi",
                        detail: "Sinon, l'élément est seulement copié et vous collez vous-même.") {
                    OrbeSwitch(isOn: $settings.clipboardAutoPaste)
                }
                if settings.clipboardAutoPaste && !accessibility {
                    OrbeFilet()
                    OrbeRow(title: "Autorisation Accessibilité manquante",
                            detail: "Sans elle, l'élément est seulement copié.") {
                        OrbeBadge(ton: .alerte, text: "À accorder")
                        Button("Autoriser", action: Permissions.openAccessibilitySettings)
                            .buttonStyle(.orbePlein)
                    }
                }
                OrbeFilet()
                OrbeRow(title: "Historique") {
                    Button("Ouvrir l'historique") { ClipboardPanelController.shared.show() }
                        .buttonStyle(settings.clipboardAutoPaste && !accessibility ? .orbe : .orbePlein)
                }
            }

            OrbeSection(title: "Conservation",
                        note: "Les éléments épinglés ne sont jamais supprimés automatiquement.") {
                OrbeRow(title: "Garder au plus") {
                    OrbeMenuPicker(selection: $settings.clipboardMaxItems,
                                   options: [50, 100, 300, 500, 1000].map { ($0, compte($0, "élément")) })
                }
                OrbeFilet()
                OrbeRow(title: "Supprimer après") {
                    OrbeMenuPicker(selection: $settings.clipboardRetentionDays,
                                   options: [(1, "1 jour"), (7, "7 jours"), (30, "30 jours"),
                                             (90, "90 jours"), (0, "Jamais")])
                }
                OrbeFilet()
                OrbeRow(title: "Garder aussi les images") {
                    OrbeSwitch(isOn: $settings.clipboardCaptureImages)
                }
                OrbeFilet()
                OrbeRow(title: "\(compte(store.items.count, "élément")) dont \(compte(store.pinned.count, "épinglé"))") {
                    Button("Afficher le dossier") {
                        NSWorkspace.shared.open(AppInfo.supportDirectory("Clipboard"))
                    }
                    .buttonStyle(.orbeDiscret)
                    if confirmClear {
                        Button("Garder les épinglés") { store.clear(); confirmClear = false }
                            .buttonStyle(.orbeDanger)
                        Button("Tout effacer") { store.clear(includingPinned: true); confirmClear = false }
                            .buttonStyle(.orbeDanger)
                        Button("Annuler") { confirmClear = false }.buttonStyle(.orbeDiscret)
                    } else {
                        Button("Effacer l'historique") { confirmClear = true }.buttonStyle(.orbeDanger)
                    }
                }
            }

            OrbeSection(title: "Confidentialité",
                        note: "Les gestionnaires de mots de passe signalent les secrets qu'ils copient, et ces copies ne sont pas gardées. Rien n'est enregistré non plus quand une app exclue est au premier plan. L'historique est stocké en clair sur ce Mac, dans un dossier lisible par votre seul compte.") {
                OrbeRow(title: "Ignorer ce que les apps marquent comme confidentiel") {
                    OrbeSwitch(isOn: $settings.clipboardIgnoreSensitive)
                }
                ForEach(settings.clipboardExcludedApps, id: \.self) { id in
                    OrbeFilet()
                    HStack(spacing: Orbe.Densite.ecart) {
                        AppIconView(bundleID: id, kind: .text).frame(width: 18, height: 18)
                        Text(appName(id)).orbe(.texte)
                        if appName(id) != id { Text(id).orbe(.donnee, Orbe.texte2) }
                        Spacer()
                        Button("Retirer") { settings.clipboardExcludedApps.removeAll { $0 == id } }
                            .buttonStyle(OrbeButtonStyle(variante: .discret, compact: true))
                    }
                    .frame(minHeight: Orbe.Densite.ligne)
                    .padding(.horizontal, Orbe.Densite.padPanneau)
                    .padding(.vertical, Orbe.Space.s2)
                }
                OrbeFilet()
                OrbeRow(title: "Apps exclues", detail: compte(settings.clipboardExcludedApps.count, "app")) {
                    Button("Exclure une app", action: addExcludedApp).buttonStyle(.orbe)
                }
            }
        }
        .refreshEverySecond { accessibility = Permissions.accessibility }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclure"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.clipboardExcludedApps.contains(id) {
                settings.clipboardExcludedApps.append(id)
            }
        }
    }
}
