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
                    ForEach(model.items) { item in
                        MenuBarBandCell(item: item,
                                        pending: model.pendingID == item.id,
                                        failed: model.failedID == item.id) { model.onPick(item) }
                    }
                }
                .padding(MenuBarBand.padding)
            case .empty:
                message("Aucune icône cachée")
            case .reading:
                message("Lecture des icônes cachées…")
            case .failed(let cause):
                message("Icônes cachées illisibles : \(cause)")
            case .noAccess:
                HStack(spacing: Orbe.Space.s3) {
                    OrbeBadge(ton: .alerte, text: "Autorisation Accessibilité manquante")
                    Button("Autoriser", action: Permissions.openAccessibilitySettings)
                        .buttonStyle(.orbePlein)
                }
                .padding(.horizontal, Orbe.Space.s4)
                .padding(.vertical, MenuBarBand.padding)
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

/// One evicted icon: its application's icon, a fixed image.
private struct MenuBarBandCell: View {
    let item: MenuBarItem
    let pending: Bool
    let failed: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                MenuBarItemIcon(item: item)
                .frame(width: 18, height: 18)
                .opacity(pending ? 0.5 : 1)
                .frame(width: MenuBarBand.cell, height: MenuBarBand.cell)
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Orbe.alerte)
                }
            }
            .background(hover ? Orbe.surfaceHaute : .clear, in: RoundedRectangle(cornerRadius: Orbe.Rayon.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(title)
        .accessibilityLabel(title)
    }

    private var title: String {
        item.isSystem && !item.label.isEmpty ? item.label : item.appName
    }
}
