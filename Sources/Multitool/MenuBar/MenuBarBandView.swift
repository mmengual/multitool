import AppKit
import SwiftUI

/// Content of the band, Orbe tokens only.
struct MenuBarBandView: View {
    @ObservedObject var model: MenuBarBandModel

    var body: some View {
        Group {
            switch model.phase {
            case .list:
                HStack(spacing: MenuBarBand.spacing) {
                    ForEach(model.apps) { app in
                        MenuBarBandCell(app: app) { model.onPick(app) }
                    }
                }
                .padding(MenuBarBand.padding)
            case .empty:
                message("Aucune icône dans la barre cachée")
            case .unavailable:
                message("Masquage indisponible dans cette version")
            }
        }
        .background(Orbe.surface, in: RoundedRectangle(cornerRadius: Orbe.Rayon.s))
        .overlay(RoundedRectangle(cornerRadius: Orbe.Rayon.s).strokeBorder(Orbe.filet, lineWidth: 1))
        .fixedSize()
    }

    private func message(_ text: String) -> some View {
        Text(text).orbe(.texteS, Orbe.texte2)
            .padding(.horizontal, Orbe.Space.s4)
            .frame(minHeight: MenuBarBand.cell + MenuBarBand.padding * 2)
    }
}

/// One hidden app: its application's icon, a fixed image.
private struct MenuBarBandCell: View {
    let app: MenuBarApp
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            MenuBarAppIcon(bundleID: app.bundleID)
                .frame(width: 18, height: 18)
                .frame(width: MenuBarBand.cell, height: MenuBarBand.cell)
                .background(hover ? Orbe.surfaceHaute : .clear, in: RoundedRectangle(cornerRadius: Orbe.Rayon.xs))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(app.name)
        .accessibilityLabel(app.name)
    }
}

/// The application's icon, from the running app or from its bundle on disk.
struct MenuBarAppIcon: View {
    let bundleID: String

    var body: some View {
        if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
            Image(nsImage: icon).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(Orbe.texte2)
        }
    }
}
