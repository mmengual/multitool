import SwiftUI

struct WindowMoverPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        PaneForm {
            OrbeSection(title: "Geste",
                        note: "Maintenez les touches choisies, puis glissez avec le bouton de souris associé n'importe où dans une fenêtre. Un même bouton ne sert qu'à une action.") {
                OrbeRow(title: "Touches à maintenir") {
                    HStack(spacing: Orbe.Space.s2) {
                        chip(.ctrl, "⌃")
                        chip(.option, "⌥")
                        chip(.shift, "⇧")
                        chip(.cmd, "⌘")
                    }
                }
                OrbeFilet()
                OrbeRow(title: "Déplacer", icon: "arrow.up.and.down.and.arrow.left.and.right") {
                    buttonPicker(button: $settings.moveButton, other: $settings.resizeButton)
                }
                OrbeFilet()
                OrbeRow(title: "Redimensionner", icon: "arrow.up.left.and.arrow.down.right") {
                    buttonPicker(button: $settings.resizeButton, other: $settings.moveButton)
                }
            }
            .disabled(!settings.windowMoverEnabled)
            .opacity(settings.windowMoverEnabled ? 1 : 0.55)
        }
    }

    private func chip(_ mask: ModifierMask, _ symbol: String) -> some View {
        let isOn = settings.windowMoverModifiers.contains(mask)
        return Button {
            if isOn { settings.windowMoverModifiers.remove(mask) } else { settings.windowMoverModifiers.insert(mask) }
        } label: {
            Text(symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Orbe.surAccent : Orbe.texte2)
                .frame(width: 32, height: 28)
                .background(isOn ? Orbe.accent : .clear, in: RoundedRectangle(cornerRadius: Orbe.Rayon.xs))
                .overlay(RoundedRectangle(cornerRadius: Orbe.Rayon.xs)
                    .strokeBorder(isOn ? .clear : Orbe.filetFort, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(Orbe.animation(Orbe.Duree.rapide), value: isOn)
    }

    private func buttonPicker(button: Binding<MouseButton>, other: Binding<MouseButton>) -> some View {
        OrbeSegmented(selection: Binding(
            get: { button.wrappedValue },
            set: { value in
                if value != .unset, other.wrappedValue == value { other.wrappedValue = .unset }
                button.wrappedValue = value
            }
        ), options: [(.unset, "Aucun"), (.left, "Clic gauche"), (.right, "Clic droit")])
    }
}

struct RegionSharePane: View {
    @ObservedObject private var share = RegionShareController.shared
    @State private var screenRecording = Permissions.screenRecording

    var body: some View {
        PaneForm {
            OrbeSection(title: "Partage",
                        note: "Choisissez une zone de l'écran : Multitool la diffuse dans une fenêtre nommée « \(ShareWindowController.titleSentinel) ». Dans Teams, Zoom ou Meet, partagez cette fenêtre plutôt que tout l'écran.") {
                OrbeRow(title: "Zone partagée") {
                    OrbeBadge(ton: RegionShareStatus.ton(share), text: RegionShareStatus.text(share))
                    RegionShareButton()
                }
                if case .sharing = share.state {
                    OrbeFilet(inset: 0)
                    SampleBufferPreviewView(publisher: share.framePublisher.eraseToAnyPublisher())
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Orbe.Rayon.m))
                        .padding(Orbe.Space.s4)
                }
            }

            OrbeSection(title: "Autorisation") {
                OrbeRow(title: "Enregistrement de l'écran") {
                    OrbeBadge(ton: screenRecording ? .hausse : .alerte,
                              text: screenRecording ? "Autorisé" : "Non autorisé")
                    if !screenRecording {
                        Button("Autoriser", action: Permissions.openScreenRecordingSettings)
                            .buttonStyle(.orbePlein)
                    }
                }
            }
        }
        .refreshEverySecond { screenRecording = Permissions.screenRecording }
    }
}

/// Start, cancel or stop, depending on the share state. Used by the pane and the popover.
struct RegionShareButton: View {
    @ObservedObject private var share = RegionShareController.shared
    var compact = false

    var body: some View {
        switch share.state {
        case .idle, .error:
            Button("Choisir une zone") { share.startSelection() }
                .buttonStyle(OrbeButtonStyle(variante: .contour, compact: compact))
        case .selecting:
            Button("Annuler") { share.cancelSelection() }
                .buttonStyle(OrbeButtonStyle(variante: .discret, compact: compact))
        case .starting:
            ProgressView().controlSize(.small)
        case .sharing:
            Button("Arrêter") { Task { await share.stop() } }
                .buttonStyle(OrbeButtonStyle(variante: .danger, compact: compact))
        }
    }
}

enum RegionShareStatus {
    @MainActor
    static func text(_ share: RegionShareController) -> String {
        switch share.state {
        case .idle: return "Aucun partage"
        case .selecting: return "Tracez un rectangle, esc pour annuler"
        case .starting: return "Démarrage de la capture"
        case .sharing:
            if let r = share.currentRegion { return "\(Int(r.width)) × \(Int(r.height)) en cours" }
            return "En cours"
        case .error(let message): return message
        }
    }

    @MainActor
    static func ton(_ share: RegionShareController) -> OrbeBadge.Ton {
        switch share.state {
        case .sharing: return .hausse
        case .selecting, .starting: return .info
        case .error: return .baisse
        case .idle: return .neutre
        }
    }
}
