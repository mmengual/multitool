import AppKit
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var settings = Settings.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        PaneForm {
            OrbeSection(title: "Démarrage",
                        note: "macOS ne l'accepte que pour l'app installée dans /Applications.") {
                OrbeRow(title: "Ouvrir Multitool à l'ouverture de session") {
                    OrbeSwitch(isOn: Binding(
                        get: { launchAtLogin },
                        set: { value in
                            launchError = LaunchAtLogin.set(value)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    ))
                }
                if let launchError {
                    OrbeFilet()
                    OrbeRow(title: "Refusé par macOS", detail: launchError) {
                        OrbeBadge(ton: .baisse, text: "Erreur")
                    }
                }
            }

            OrbeSection(title: "Modules") {
                moduleRow(.clipboard) { OrbeSwitch(isOn: $settings.clipboardEnabled) }
                OrbeFilet()
                moduleRow(.chatter) { OrbeSwitch(isOn: $settings.enabled) }
                OrbeFilet()
                moduleRow(.keyRemap) {
                    Text(remapState).orbe(.texteS, Orbe.texte2)
                }
                OrbeFilet()
                moduleRow(.windowMover) { OrbeSwitch(isOn: $settings.windowMoverEnabled) }
                OrbeFilet()
                moduleRow(.regionShare) {
                    Text("À la demande").orbe(.texteS, Orbe.texte2)
                }
            }
        }
        .refreshEverySecond { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private var remapState: String {
        switch settings.swapCmdOptionMode {
        case .off: return "Désactivée"
        case .auto: return "Automatique"
        case .on: return "Toujours"
        }
    }

    private func moduleRow<Trailing: View>(_ pane: SettingsPane,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        let category = SettingsCatalog.category(pane)
        return OrbeRow(title: category?.title ?? "", detail: category?.summary, icon: category?.symbol) {
            trailing()
            Button { navigation.selection = pane } label: { Image(systemName: "chevron.right") }
                .buttonStyle(OrbeButtonStyle(variante: .discret, compact: true))
                .help("Ouvrir les réglages du module")
        }
    }
}

struct PermissionsPane: View {
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording

    var body: some View {
        PaneForm {
            OrbeSection(title: "Autorisations macOS",
                        note: "L'app est signée localement : après une mise à jour, macOS peut garder une ancienne entrée qui ne fonctionne plus. Dans ce cas, retirez Multitool de la liste dans Réglages Système, puis relancez l'app.") {
                permissionRow(
                    title: "Accessibilité",
                    granted: accessibility,
                    usedBy: "Chatter Blocker, Inversion ⌘ / ⌥, Window Mover, collage automatique du presse-papiers",
                    open: Permissions.openAccessibilitySettings
                )
                OrbeFilet()
                permissionRow(
                    title: "Enregistrement de l'écran",
                    granted: screenRecording,
                    usedBy: "Partage de zone",
                    open: Permissions.openScreenRecordingSettings
                )
            }
        }
        .refreshEverySecond {
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
        }
    }

    private func permissionRow(title: String, granted: Bool, usedBy: String,
                               open: @escaping () -> Void) -> some View {
        OrbeRow(title: title, detail: "Utilisée par : \(usedBy)") {
            OrbeBadge(ton: granted ? .hausse : .alerte, text: granted ? "Autorisée" : "Non autorisée")
            if !granted {
                Button("Autoriser", action: open).buttonStyle(.orbePlein)
            }
        }
    }
}

struct AboutPane: View {
    var body: some View {
        PaneForm {
            OrbePanel {
                HStack(spacing: Orbe.Space.s5) {
                    OrbeMark(size: 40)
                    VStack(alignment: .leading, spacing: Orbe.Space.s2) {
                        Text("Multitool").orbe(.display)
                        Text("Version \(AppInfo.version)").orbe(.donnee, Orbe.texte2)
                    }
                }
                .padding(Orbe.Densite.padPanneau)
            }

            OrbeSection(title: "À venir") {
                OrbeRow(title: "Processus et ressources",
                        detail: "Ce qui tourne, ce qui consomme, ce qui se lance au démarrage.", icon: "cpu")
                OrbeFilet()
                OrbeRow(title: "Barre des menus",
                        detail: "Garder un nombre fixe d'icônes visibles, ranger les autres.", icon: "menubar.rectangle")
                OrbeFilet()
                OrbeRow(title: "Captures d'écran",
                        detail: "Capture et retouche, dans l'esprit de Shottr.", icon: "camera.viewfinder")
            }

            OrbeSection(title: "Diagnostic",
                        note: "Commande à lancer dans le Terminal pour suivre le journal de l'app.") {
                Text(#"log stream --predicate 'subsystem == "com.mmengual.multitool"'"#)
                    .orbe(.code, Orbe.texte)
                    .textSelection(.enabled)
                    .padding(Orbe.Densite.padPanneau)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Orbe.chrome)
            }
        }
    }
}
