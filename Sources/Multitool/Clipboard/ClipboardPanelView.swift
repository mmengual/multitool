import AppKit
import SwiftUI

/// The history panel: a floating Orbe panel (level 3, translucent) with a
/// search field, the list on the left and the selected item on the right.
struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @ObservedObject private var store = ClipboardStore.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle().fill(Orbe.filet).frame(height: 1)
            if model.visible.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 330)
                    Rectangle().fill(Orbe.filet).frame(width: 1)
                    ClipboardPreview(item: model.selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Rectangle().fill(Orbe.filet).frame(height: 1)
            footer
        }
        .background(
            ZStack {
                VisualEffect(material: .hudWindow)
                Orbe.surfaceHaute.opacity(0.86)
            }
        )
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(Orbe.accent)
        .onChange(of: model.focusToken) { _ in searchFocused = true }
        .onAppear { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: Orbe.Space.s4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Orbe.texte2)
            TextField("", text: $model.query, prompt: Text("Rechercher dans l'historique").foregroundColor(Orbe.texte2))
                .textFieldStyle(.plain)
                .font(Orbe.font(.titre3))
                .foregroundStyle(Orbe.texte)
                .focused($searchFocused)
            Text(compte(store.items.count, "élément")).orbe(.donnee, Orbe.texte2)
        }
        .padding(.horizontal, Orbe.Space.s6)
        .padding(.top, Orbe.Space.s6)
        .padding(.bottom, Orbe.Space.s5)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Orbe.Space.s1) {
                    if !model.pinned.isEmpty {
                        sectionLabel("Épinglés")
                        rows(model.pinned, offset: 0)
                        sectionLabel("Historique").padding(.top, Orbe.Space.s3)
                    }
                    rows(model.recent, offset: model.pinned.count)
                }
                .padding(Orbe.Space.s3)
            }
            .onChange(of: model.selectedID) { id in
                if let id { withAnimation(Orbe.animation(Orbe.Duree.rapide)) { proxy.scrollTo(id) } }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).orbe(.label, Orbe.texte2)
            .padding(.horizontal, Orbe.Space.s3)
            .padding(.vertical, Orbe.Space.s2)
    }

    @ViewBuilder
    private func rows(_ items: [ClipboardItem], offset: Int) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            ClipboardRow(item: item,
                         shortcut: offset + index < 9 ? offset + index + 1 : nil,
                         selected: item.id == model.selected?.id)
                .id(item.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.selectedID = item.id; model.pick() }
                .onTapGesture { model.selectedID = item.id }
                .contextMenu {
                    Button("Coller") { model.selectedID = item.id; model.pick() }
                    Button("Coller en texte brut") { model.selectedID = item.id; model.pick(plainText: true) }
                    Button(item.pinned ? "Désépingler" : "Épingler") { store.togglePin(item) }
                    Divider()
                    Button("Supprimer") { store.delete(item) }
                }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Orbe.Space.s4) {
            OrbeMark(size: 36)
            Text(model.query.isEmpty ? "Historique vide" : "Aucun résultat").orbe(.titre3)
            Text(model.query.isEmpty
                 ? "Ce que vous copiez dans n'importe quelle app arrive ici."
                 : "Aucun élément ne contient « \(model.query) ». Esc efface la recherche.")
                .orbe(.texte, Orbe.texte2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: Orbe.Space.s5) {
            hint("↩", "Coller")
            hint("⌥↩", "Texte brut")
            hint("⌘1-9", "Coller l'élément")
            hint("⌘P", "Épingler")
            hint("⌘⌫", "Supprimer")
            Spacer()
            hint("esc", "Fermer")
        }
        .padding(.horizontal, Orbe.Space.s6)
        .padding(.vertical, Orbe.Space.s3)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: Orbe.Space.s3) {
            OrbeKey(key)
            Text(label).orbe(.texteS, Orbe.texte2)
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let shortcut: Int?
    let selected: Bool
    @State private var hover = false

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: Orbe.Space.s4) {
            AppIconView(bundleID: item.sourceBundleID, kind: item.kind)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                Text(item.title).orbe(.texte).lineLimit(1).truncationMode(.tail)
                Text(Self.relative.localizedString(for: item.date, relativeTo: Date())).orbe(.texteS, Orbe.texte2)
            }
            Spacer(minLength: Orbe.Space.s2)
            if item.pinned {
                Image(systemName: "pin").font(.system(size: 11)).foregroundStyle(Orbe.accent)
            }
            if let shortcut {
                Text("⌘\(shortcut)").orbe(.donnee, selected ? Orbe.accent : Orbe.texte2)
            }
        }
        .padding(.horizontal, Orbe.Space.s3)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: Orbe.Rayon.s)
                .fill(Orbe.accent.opacity(selected ? Orbe.Etat.actif : hover ? Orbe.Etat.survol : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Orbe.Rayon.s)
                .strokeBorder(selected ? Orbe.accent.opacity(0.3) : .clear, lineWidth: 1)
        )
        .onHover { hover = $0 }
        .animation(Orbe.animation(Orbe.Duree.rapide), value: selected)
    }
}

struct ClipboardPreview: View {
    let item: ClipboardItem?

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                content(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Orbe.filet).frame(height: 1)
                metadata(item)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(item.text ?? "")
                    .orbe(looksLikeCode(item.text) ? .code : .texteL)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Orbe.Space.s6)
            }
        case .image:
            if let url = ClipboardStore.shared.imageURL(for: item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Orbe.Rayon.m))
                    .padding(Orbe.Space.s6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Image introuvable sur le disque").orbe(.texte, Orbe.texte2).padding(Orbe.Space.s6)
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: Orbe.Space.s4) {
                    ForEach(item.filePaths ?? [], id: \.self) { path in
                        HStack(spacing: Orbe.Space.s4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                                Text((path as NSString).lastPathComponent).orbe(.texte)
                                Text((path as NSString).deletingLastPathComponent).orbe(.donnee, Orbe.texte2)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .padding(Orbe.Space.s6)
            }
        }
    }

    private func metadata(_ item: ClipboardItem) -> some View {
        HStack(spacing: Orbe.Space.s5) {
            if let app = item.sourceAppName { Text(app).orbe(.texteS, Orbe.texte2) }
            Text(item.date.formatted(date: .abbreviated, time: .shortened)).orbe(.donnee, Orbe.texte2)
            if item.kind == .text, let text = item.text {
                Text(compte(text.count, "caractère")).orbe(.donnee, Orbe.texte2)
            }
            if item.kind == .text, item.rtf != nil { Text("Texte enrichi").orbe(.texteS, Orbe.lagon) }
            Spacer()
        }
        .padding(.horizontal, Orbe.Space.s6)
        .padding(.vertical, Orbe.Space.s3)
    }

    private func looksLikeCode(_ text: String?) -> Bool {
        guard let text else { return false }
        let markers = ["{", "}", ";", "=>", "func ", "def ", "  ", "\t", "</"]
        return markers.filter { text.contains($0) }.count >= 2
    }
}

/// The icon of the app an item was copied from, with a fallback per kind.
struct AppIconView: View {
    let bundleID: String?
    let kind: ClipboardItem.Kind

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = icon {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: kind == .image ? "photo" : kind == .files ? "doc" : "text.alignleft")
                .foregroundStyle(.secondary)
        }
    }

    private var icon: NSImage? {
        guard let bundleID else { return nil }
        if let cached = Self.cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache[bundleID] = image
        return image
    }
}

/// NSVisualEffectView for SwiftUI backgrounds.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
