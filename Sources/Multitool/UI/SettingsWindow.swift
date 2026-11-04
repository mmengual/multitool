import AppKit
import SwiftUI

/// The panes of the settings window.
enum SettingsPane: String, Hashable, CaseIterable {
    case general, permissions, updates, about
    case chatter, keyRemap
    case windowMover, regionShare
    case clipboard
}

/// One sidebar entry: its name, glyph, and the sentence the content header
/// shows to say what the pane decides.
struct SettingsCategory: Identifiable, Hashable {
    let pane: SettingsPane
    let title: String
    let symbol: String
    let summary: String
    var id: SettingsPane { pane }
}

struct SettingsCategoryGroup: Identifiable, Hashable {
    let title: String
    let categories: [SettingsCategory]
    var id: String { title }
}

/// The map of the settings, and the only place that decides what lives where.
/// Adding a module = one entry here + one case in `SettingsRootView.pane`.
enum SettingsCatalog {
    static let groups: [SettingsCategoryGroup] = [
        SettingsCategoryGroup(title: "Multitool", categories: [
            SettingsCategory(pane: .general, title: "Général", symbol: "gearshape",
                             summary: "Démarrage de l'app et vue d'ensemble des modules."),
            SettingsCategory(pane: .permissions, title: "Autorisations", symbol: "lock.shield",
                             summary: "Ce que macOS autorise Multitool à faire, et quels modules en dépendent."),
            SettingsCategory(pane: .updates, title: "Mises à jour", symbol: "arrow.down.circle",
                             summary: "Vérification et installation des nouvelles versions, depuis le dépôt GitHub."),
            SettingsCategory(pane: .about, title: "À propos", symbol: "info.circle",
                             summary: "Version, modules disponibles et à venir."),
        ]),
        SettingsCategoryGroup(title: "Clavier", categories: [
            SettingsCategory(pane: .chatter, title: "Chatter Blocker", symbol: "keyboard",
                             summary: "Filtre les doubles frappes d'un switch mécanique défectueux."),
            SettingsCategory(pane: .keyRemap, title: "Inversion ⌘ / ⌥", symbol: "command",
                             summary: "Échange Commande et Option, toujours ou seulement avec un clavier Logitech."),
        ]),
        SettingsCategoryGroup(title: "Fenêtres et écran", categories: [
            SettingsCategory(pane: .windowMover, title: "Window Mover", symbol: "macwindow",
                             summary: "Déplacer ou redimensionner une fenêtre en la saisissant n'importe où."),
            SettingsCategory(pane: .regionShare, title: "Partage de zone", symbol: "rectangle.dashed",
                             summary: "Diffuser une partie de l'écran dans Teams, Zoom ou Meet."),
        ]),
        SettingsCategoryGroup(title: "Productivité", categories: [
            SettingsCategory(pane: .clipboard, title: "Presse-papiers", symbol: "doc.on.clipboard",
                             summary: "Historique de ce que vous copiez, à recoller au clavier."),
        ]),
    ]

    static var categories: [SettingsCategory] { groups.flatMap(\.categories) }
    static func category(_ pane: SettingsPane) -> SettingsCategory? {
        categories.first { $0.pane == pane }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsPane = .general
}

/// A regular, resizable window (not a popover): the panes need room.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.selection = pane }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Réglages Multitool"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 780, height: 520)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Orbe.fond)
        window.contentViewController = NSHostingController(rootView: SettingsRootView(navigation: navigation))
        window.setContentSize(NSSize(width: 940, height: 660))
        window.center()
        window.setFrameAutosaveName("MultitoolSettings")
        window.delegate = self
        return window
    }
}

struct SettingsRootView: View {
    @ObservedObject var navigation: SettingsNavigation

    private var category: SettingsCategory? { SettingsCatalog.category(navigation.selection) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Orbe.navigationWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Orbe.chrome)
            Rectangle().fill(Orbe.chromeFilet).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(Orbe.filet).frame(height: 1)
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Orbe.fond)
        }
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 520)
        .preferredColorScheme(.dark)
        .tint(Orbe.accent)
    }

    // MARK: Navigation (chrome)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Orbe.Space.s3) {
                OrbeMark(size: 16)
                Text("Multitool").orbe(.titre3, Orbe.chromeTexte)
            }
            .padding(.horizontal, Orbe.Space.s5)
            .padding(.top, 46) // under the traffic lights
            .padding(.bottom, Orbe.Space.s6)

            ScrollView {
                VStack(alignment: .leading, spacing: Orbe.Space.s5) {
                    ForEach(SettingsCatalog.groups) { group in
                        VStack(alignment: .leading, spacing: Orbe.Space.s1) {
                            Text(group.title).orbe(.label, Orbe.chromeTexte2)
                                .padding(.horizontal, Orbe.Space.s4)
                                .padding(.bottom, Orbe.Space.s2)
                            ForEach(group.categories) { navItem($0) }
                        }
                    }
                }
                .padding(.horizontal, Orbe.Space.s3)
            }
        }
    }

    private func navItem(_ category: SettingsCategory) -> some View {
        let active = navigation.selection == category.pane
        return Button {
            navigation.selection = category.pane
        } label: {
            HStack(spacing: Orbe.Space.s4) {
                Image(systemName: category.symbol)
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(active ? Orbe.accent : Orbe.chromeTexte2)
                    .frame(width: 18)
                Text(category.title)
                    .font(active ? Orbe.texteMedium : Orbe.font(.texte))
                    .foregroundStyle(active ? Orbe.chromeTexte : Orbe.chromeTexte2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Orbe.Space.s4)
            .frame(height: Orbe.Densite.controle)
            .background(active ? Orbe.accent.opacity(Orbe.Etat.actif) : .clear,
                        in: RoundedRectangle(cornerRadius: Orbe.Rayon.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .animation(Orbe.animation(Orbe.Duree.rapide), value: active)
    }

    // MARK: Content

    private var header: some View {
        HStack(alignment: .center, spacing: Orbe.Space.s5) {
            VStack(alignment: .leading, spacing: Orbe.Space.s2) {
                Text(category?.title ?? "Réglages").orbe(.titre2)
                if let summary = category?.summary {
                    Text(summary).orbe(.texte, Orbe.texte2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Orbe.Space.s4)
            ModuleHeaderToggle(pane: navigation.selection)
        }
        .padding(.horizontal, Orbe.Densite.marge)
        .padding(.top, 40)
        .padding(.bottom, Orbe.Space.s6)
    }

    @ViewBuilder
    private var pane: some View {
        switch navigation.selection {
        case .general: GeneralPane(navigation: navigation)
        case .permissions: PermissionsPane()
        case .updates: UpdatesPane()
        case .about: AboutPane()
        case .chatter: ChatterPane()
        case .keyRemap: KeyRemapPane()
        case .windowMover: WindowMoverPane()
        case .regionShare: RegionSharePane()
        case .clipboard: ClipboardPane()
        }
    }
}

/// The on/off switch shown in the header of a module's pane, when the
/// module has one.
struct ModuleHeaderToggle: View {
    let pane: SettingsPane
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        if let binding {
            Toggle(isOn: binding) {
                Text(binding.wrappedValue ? "Activé" : "Désactivé").orbe(.texteS, Orbe.texte2)
            }
            .toggleStyle(.orbe)
        }
    }

    private var binding: Binding<Bool>? {
        switch pane {
        case .chatter: return $settings.enabled
        case .windowMover: return $settings.windowMoverEnabled
        case .clipboard: return $settings.clipboardEnabled
        default: return nil
        }
    }
}
