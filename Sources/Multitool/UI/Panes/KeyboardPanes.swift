import SwiftUI

struct ChatterPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var detector = ChatterDetector.shared
    @ObservedObject private var game = GameDetector.shared

    var body: some View {
        PaneForm {
            OrbeSection(title: "Filtre",
                        note: "Une frappe de la même touche arrivant moins de \(settings.thresholdMs) ms après son relâchement est bloquée. Trop bas, les rebonds passent. Trop haut, une double lettre volontaire tapée vite est mangée. Un jeu est reconnu par sa catégorie App Store, son support du Mode Jeu ou une installation Steam.") {
                VStack(alignment: .leading, spacing: Orbe.Space.s3) {
                    HStack {
                        Text("Seuil").orbe(.texte)
                        Spacer()
                        Text("\(settings.thresholdMs) ms").orbe(.donnee)
                    }
                    Slider(value: Binding(get: { Double(settings.thresholdMs) },
                                          set: { settings.thresholdMs = Int($0.rounded()) }),
                           in: Double(Settings.thresholdRange.lowerBound)...Double(Settings.thresholdRange.upperBound))
                        .controlSize(.small)
                    HStack {
                        Text("\(Settings.thresholdRange.lowerBound) ms")
                        Spacer()
                        Text("\(Settings.thresholdRange.upperBound) ms")
                    }
                    .orbe(.donnee, Orbe.texte2)
                }
                .padding(.horizontal, Orbe.Densite.padPanneau)
                .padding(.vertical, Orbe.Space.s4)
                OrbeFilet()
                OrbeRow(title: "Suspendre pendant un jeu") {
                    OrbeBadge(ton: game.inGame ? .info : .neutre, text: gameStatus)
                    OrbeSwitch(isOn: $settings.pauseInGame)
                }
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.55)

            OrbeSection(title: "Depuis le lancement") {
                HStack(alignment: .bottom, spacing: Orbe.Space.s8) {
                    OrbeStat(label: "Bloquées", value: "\(detector.totalDropped)", color: Orbe.baisse)
                    OrbeStat(label: "Laissées passer", value: "\(detector.totalPassed)")
                    Spacer()
                    Button("Remettre à zéro") { detector.reset() }.buttonStyle(.orbe)
                }
                .padding(Orbe.Densite.padPanneau)
            }

            OrbeSection(title: "Touches les plus bloquées") {
                if perKey.isEmpty {
                    OrbeRow(title: "Aucun blocage pour l'instant",
                            detail: "Les touches dont le switch rebondit apparaîtront ici.")
                } else {
                    ForEach(Array(perKey.prefix(12).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { OrbeFilet() }
                        HStack {
                            Text(row.name).orbe(.texte).frame(width: 120, alignment: .leading)
                            Text(compte(row.drops, "blocage")).orbe(.donnee, Orbe.baisse)
                            Spacer()
                            Text("min \(ms(row.minInterval))").orbe(.donnee, Orbe.texte2)
                        }
                        .frame(height: Orbe.Densite.ligne)
                        .padding(.horizontal, Orbe.Densite.padPanneau)
                    }
                }
            }

            OrbeSection(title: "Intervalles récents, sous \(Int(ChatterDetector.observationWindowMs)) ms") {
                if recent.isEmpty {
                    OrbeRow(title: "Rien d'enregistré pour l'instant")
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, e in
                        if index > 0 { OrbeFilet() }
                        HStack(spacing: Orbe.Space.s5) {
                            Text(Self.time.string(from: e.timestamp)).orbe(.donnee, Orbe.texte2)
                            Text(KeyCodeMap.name(for: e.keyCode)).orbe(.texte).frame(width: 110, alignment: .leading)
                            Spacer()
                            Text(String(format: "%.1f ms", e.intervalMs)).orbe(.donnee)
                            OrbeBadge(ton: e.wasDropped ? .baisse : .neutre, text: e.wasDropped ? "Bloquée" : "Passée")
                                .frame(width: 90, alignment: .leading)
                        }
                        .frame(height: Orbe.Densite.ligne)
                        .padding(.horizontal, Orbe.Densite.padPanneau)
                    }
                }
            }
        }
    }

    private var gameStatus: String {
        guard game.inGame else { return "Aucun jeu au premier plan" }
        let name = game.gameName ?? "Un jeu"
        return settings.pauseInGame ? "\(name) : filtre suspendu" : "\(name) au premier plan"
    }

    private struct KeyRow { let id: Int64; let name: String; let drops: Int; let minInterval: Double? }

    private var perKey: [KeyRow] {
        detector.perKey
            .filter { $0.value.drops > 0 }
            .map { KeyRow(id: $0.key, name: KeyCodeMap.name(for: $0.key), drops: $0.value.drops,
                          minInterval: $0.value.minInterval) }
            .sorted { $0.drops > $1.drops }
    }

    private var recent: [KeyEvent] { Array(detector.recentEvents.suffix(30).reversed()) }

    private func ms(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f ms", v)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

struct KeyRemapPane: View {
    @ObservedObject private var swap = KeyboardSwap.shared

    var body: some View {
        PaneForm {
            OrbeSection(title: "Claviers branchés",
                        note: "Les claviers pensés pour Windows placent Option là où un clavier Mac met Commande. L'interrupteur modifie le réglage Touches de modification de macOS pour ce clavier : macOS le garde et l'applique à chaque branchement, même quand Multitool est fermé. L'inversion a lieu avant les apps, donc aussi dans les champs de mot de passe et les jeux.") {
                if swap.keyboards.isEmpty {
                    OrbeRow(title: "Aucun clavier détecté")
                } else {
                    ForEach(Array(swap.keyboards.enumerated()), id: \.element.id) { index, keyboard in
                        if index > 0 { OrbeFilet() }
                        OrbeRow(title: keyboard.name,
                                detail: keyboard.builtIn ? "Clavier intégré"
                                    : keyboard.isReceiver ? "Récepteur sans fil, partagé avec une souris" : nil,
                                icon: "keyboard") {
                            OrbeSwitch(isOn: Binding(get: { keyboard.swapped },
                                                     set: { swap.setSwapped($0, for: keyboard) }))
                        }
                    }
                }
                if let error = swap.lastError {
                    OrbeFilet()
                    OrbeRow(title: error) { OrbeBadge(ton: .alerte, text: "En attente") }
                }
            }

            OrbeSection(title: "Réglage macOS") {
                OrbeRow(title: "Touches de modification",
                        detail: "Réglages Système → Clavier → Raccourcis clavier → Touches de modification") {
                    Button("Ouvrir") { Permissions.openKeyboardSettings() }
                        .buttonStyle(.orbe)
                }
            }
        }
        .onAppear { swap.refresh() }
        .refreshEverySecond { swap.refresh() }
    }
}
