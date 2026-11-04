import SwiftUI

struct UpdatesPane: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        PaneForm {
            OrbeSection(title: "Version installée") {
                OrbeRow(title: "Multitool \(AppInfo.version)", detail: "Build \(AppInfo.build)") {
                    if updates.isConfigured {
                        Button("Rechercher maintenant") { updates.checkForUpdates() }
                            .buttonStyle(.orbePlein)
                            .disabled(!updates.canCheck)
                    }
                }
                OrbeFilet()
                OrbeRow(title: "Dernière vérification") {
                    Text(lastCheckText).orbe(.donnee, Orbe.texte2)
                }
            }

            if updates.isConfigured {
                OrbeSection(title: "Automatisme",
                            note: "La vérification a lieu une fois par jour. Une mise à jour téléchargée s'installe à la prochaine fermeture de l'app, puis Multitool redémarre.") {
                    OrbeRow(title: "Vérifier automatiquement") {
                        OrbeSwitch(isOn: $updates.automaticChecks)
                    }
                    OrbeFilet()
                    OrbeRow(title: "Télécharger et installer sans demander") {
                        OrbeSwitch(isOn: $updates.automaticDownloads)
                    }
                    .disabled(!updates.automaticChecks)
                    .opacity(updates.automaticChecks ? 1 : 0.55)
                }
            }

            OrbeSection(title: "Source",
                        note: "Les versions sont publiées dans les releases du dépôt GitHub mmengual/multitool. Chaque version est signée : une archive modifiée est refusée." + (UpdateAccess.token != nil ? " L'app embarque un jeton de lecture limité à ce dépôt." : "")) {
                OrbeRow(title: "Flux") {
                    Text(UpdateAccess.feedURL?.host ?? "Aucun").orbe(.donnee, Orbe.texte2)
                }
                OrbeFilet()
                OrbeRow(title: "État") {
                    if let error = updates.startError {
                        OrbeBadge(ton: .alerte, text: error)
                    } else {
                        OrbeBadge(ton: .hausse, text: "Prêt")
                    }
                }
            }
        }
    }

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return "Jamais" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
