import SwiftUI

struct MonitorPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var helper = HelperClient.shared
    @ObservedObject private var monitor = ResourceMonitor.shared

    var body: some View {
        PaneForm {
            OrbeSection(title: "Moniteur",
                        note: "La surveillance mesure le Mac toutes les 5 s en arrière-plan. Une anomalie qui dure colore l'icône de la barre des menus, sans notification.") {
                OrbeRow(title: "État", detail: monitor.summary) {
                    Button("Ouvrir le moniteur") { MonitorWindowController.shared.show() }
                        .buttonStyle(.orbePlein)
                }
            }

            OrbeSection(title: "Lecture complète",
                        note: "macOS cache les compteurs des processus système à un utilisateur normal. Le service de lecture est lancé par macOS avec les droits système, ne répond qu'à Multitool signé par le même certificat, et ne fait que lire : il ne peut rien modifier ni arrêter. Il s'arrête seul après 5 minutes sans demande.") {
                OrbeRow(title: "Service de lecture", detail: detail) {
                    badge
                    switch helper.state {
                    case .notInstalled:
                        Button("Activer") { helper.install() }.buttonStyle(.orbePlein)
                    case .needsApproval:
                        Button("Ouvrir les réglages") { helper.openApprovalSettings() }.buttonStyle(.orbePlein)
                    case .enabled:
                        Button("Désactiver") { helper.uninstall() }.buttonStyle(.orbe)
                    case .unavailable:
                        EmptyView()
                    }
                }
                if let error = helper.lastError {
                    OrbeFilet()
                    OrbeRow(title: "Refusé par macOS", detail: error) { OrbeBadge(ton: .baisse, text: "Erreur") }
                }
            }
        }
        .refreshEverySecond { helper.refresh() }
    }

    private var detail: String {
        switch helper.state {
        case .notInstalled: return "Inactif : \(compte(monitor.unreadable, "processus illisible", "processus illisibles")) à la dernière mesure."
        case .needsApproval: return "À autoriser dans Réglages Système → Général → Ouverture et extensions, section Autoriser en arrière-plan."
        case .enabled: return monitor.privileged ? "Actif : tous les processus sont lus." : "Autorisé, démarrage en cours."
        case .unavailable(let reason): return reason
        }
    }

    @ViewBuilder private var badge: some View {
        switch helper.state {
        case .enabled: OrbeBadge(ton: .hausse, text: "Actif")
        case .needsApproval: OrbeBadge(ton: .alerte, text: "En attente")
        case .notInstalled: OrbeBadge(ton: .neutre, text: "Inactif")
        case .unavailable: OrbeBadge(ton: .baisse, text: "Indisponible")
        }
    }
}
