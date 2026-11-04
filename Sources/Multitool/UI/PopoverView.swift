import AppKit
import SwiftUI

/// Quick access from the menu bar icon: one row per module, the region
/// share controls, and the way into the full settings window.
struct PopoverView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var chatter = ChatterDetector.shared
    @ObservedObject private var share = RegionShareController.shared
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var keyboard = KeyboardDetector.shared
    let openSettings: (SettingsPane?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Orbe.chromeFilet).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                row(.clipboard, status: clipboardStatus) {
                    if settings.clipboardEnabled {
                        Button("Ouvrir") { ClipboardPanelController.shared.show() }
                            .buttonStyle(OrbeButtonStyle(variante: .contour, compact: true))
                    }
                    OrbeSwitch(isOn: $settings.clipboardEnabled)
                }
                OrbeFilet(inset: 0)
                row(.chatter, status: chatterStatus) { OrbeSwitch(isOn: $settings.enabled) }
                OrbeFilet(inset: 0)
                row(.windowMover, status: windowMoverStatus) { OrbeSwitch(isOn: $settings.windowMoverEnabled) }
                OrbeFilet(inset: 0)
                row(.keyRemap, status: remapStatus) {
                    OrbeSegmented(selection: $settings.swapCmdOptionMode,
                                  options: [(.off, "Non"), (.auto, "Auto"), (.on, "Oui")])
                }
                OrbeFilet(inset: 0)
                row(.regionShare, status: RegionShareStatus.text(share)) {
                    RegionShareButton(compact: true)
                }
                if case .sharing = share.state {
                    SampleBufferPreviewView(publisher: share.framePublisher.eraseToAnyPublisher())
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: Orbe.Rayon.m))
                        .padding(.bottom, Orbe.Space.s4)
                }
            }
            .padding(.horizontal, Orbe.Space.s5)
            .background(Orbe.surfaceHaute)
            Rectangle().fill(Orbe.filet).frame(height: 1)
            footer
        }
        .frame(width: 380)
        .background(Orbe.surfaceHaute)
        .preferredColorScheme(.dark)
        .tint(Orbe.accent)
    }

    private var header: some View {
        HStack(spacing: Orbe.Space.s3) {
            OrbeMark(size: 14)
            Text("Multitool").orbe(.titre3, Orbe.chromeTexte)
            Spacer()
            Text(AppInfo.version).orbe(.donnee, Orbe.chromeTexte2)
        }
        .padding(.horizontal, Orbe.Space.s5)
        .frame(height: 44)
        .background(Orbe.chrome)
    }

    private func row<Trailing: View>(_ pane: SettingsPane, status: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        let category = SettingsCatalog.category(pane)
        return HStack(spacing: Orbe.Densite.ecart) {
            Image(systemName: category?.symbol ?? "square")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(Orbe.accent)
                .frame(width: 20)
            Button { openSettings(pane) } label: {
                VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                    Text(category?.title ?? "").orbe(.texte)
                    Text(status).orbe(.texteS, Orbe.texte2).lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Ouvrir les réglages du module")
            Spacer(minLength: Orbe.Space.s3)
            trailing()
        }
        .frame(minHeight: 48)
    }

    private var footer: some View {
        HStack {
            Button { openSettings(nil) } label: {
                Label("Ouvrir les réglages", systemImage: "gearshape")
            }
            .buttonStyle(OrbeButtonStyle(variante: .discret, compact: true))
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("Quitter", systemImage: "power")
            }
            .buttonStyle(OrbeButtonStyle(variante: .discret, compact: true))
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, Orbe.Space.s4)
        .padding(.vertical, Orbe.Space.s3)
    }

    private var clipboardStatus: String {
        guard settings.clipboardEnabled else { return "Désactivé" }
        let shortcut = settings.clipboardHotKey.map { " · \($0.displayString)" } ?? ""
        return compte(store.items.count, "élément") + shortcut
    }

    private var chatterStatus: String {
        guard settings.enabled else { return "Désactivé" }
        return "Seuil \(settings.thresholdMs) ms · \(compte(chatter.totalDropped, "blocage"))"
    }

    private var windowMoverStatus: String {
        guard settings.windowMoverEnabled else { return "Désactivé" }
        var keys = ""
        if settings.windowMoverModifiers.contains(.ctrl) { keys += "⌃" }
        if settings.windowMoverModifiers.contains(.option) { keys += "⌥" }
        if settings.windowMoverModifiers.contains(.shift) { keys += "⇧" }
        if settings.windowMoverModifiers.contains(.cmd) { keys += "⌘" }
        return "\(keys) et glisser"
    }

    private var remapStatus: String {
        switch settings.swapCmdOptionMode {
        case .off: return "Inactive"
        case .on: return "Active"
        case .auto: return keyboard.hasLogitechKeyboard ? "Active, Logitech branché" : "En attente d'un Logitech"
        }
    }
}
