import AppKit

@main
enum Main {
    /// Opens the overflow if needed to find the icon, then relays as the band would.
    static func relayFromCommandLine(bundleID: String) -> Int32 {
        guard Permissions.accessibility else { print("relay: Accessibilité absente"); return 1 }
        let opened = MenuBarOverflow.openSync()
        if case .failed(let cause) = opened { print("relay: déroulé : \(cause)") }
        let found = MenuBarInventory.stableScan().items.first { $0.bundleID == bundleID }
        MenuBarOverflow.closeIfHeldSync()
        guard let item = found else { print("relay: aucune icône pour \(bundleID)"); return 1 }
        print("relay: \(item.id), zone \(item.zone == .hidden ? "cachée" : "principale"), menu \(item.hasMenu ? "oui" : "non")")
        Thread.sleep(forTimeInterval: 0.3)
        let start = DispatchTime.now()
        var code: Int32 = 0
        MenuBarRelay.perform(item) { outcome in
            switch outcome {
            case .menu(let entries):
                print("relay: menu redessiné, \(entries.count) entrées en \(MenuBarOverflow.elapsedMS(since: start)) ms")
                for entry in entries {
                    print(entry.isSeparator ? "  ───" : "  \(entry.checked ? "✓" : " ") \(entry.title)\(entry.enabled ? "" : " (inactive)")\(entry.submenu.isEmpty ? "" : " ▸ \(entry.submenu.count)")")
                }
            case .dispatched(let mode):
                print("relay: \(mode) lancé en \(MenuBarOverflow.elapsedMS(since: start)) ms")
            case .busy:
                print("relay: un autre relais est en cours")
                code = 1
            case .failed(let cause):
                print("relay: échec : \(cause)")
                code = 1
            }
        }
        print("relay: terminé en \(MenuBarOverflow.elapsedMS(since: start)) ms")
        return code
    }

    static func main() {
        // `--menubar-dump`: prints the menu bar inventory and exits, without starting the app.
        if CommandLine.arguments.contains("--menubar-dump") {
            let (items, indicator) = MenuBarInventory.scan()
            for item in items {
                let zone = item.zone == .main ? "main  " : "hidden"
                let x = String(format: "%7.1f", item.frame.minX)
                let width = String(format: "%6.1f", item.frame.width)
                let menu = item.hasMenu ? "menu " : "     "
                print("\(zone)  \(x)  \(width)  \(menu) \(item.appName)  \(item.label)\(item.isSystem ? "  [système]" : "")")
            }
            let open = items.contains { $0.zone == .hidden }
            print("indicateur: \(indicator == nil ? "absent" : "présent"), déroulé: \(open ? "ouvert" : "fermé"), total: \(items.count)")
            if let f = indicator?.frame {
                print(String(format: "cadre de l'indicateur: x %.1f, y %.1f, largeur %.1f, hauteur %.1f",
                             f.minX, f.minY, f.width, f.height))
            }
            // The first screen carries the menu bar (NSScreen.main follows the key window).
            let leftLimit = NSScreen.screens.first.flatMap(MenuBarChevron.leftLimit(of:))
            print("limite gauche: \(leftLimit.map { String(format: "%.1f", $0) } ?? "aucune (écran sans encoche)")")
            if let leftmost = items.first(where: { $0.zone == .main }) {
                let length = MenuBarChevron.targetLength(chevronMaxX: leftmost.frame.minX, leftLimit: leftLimit,
                                                         reserve: MenuBarChevron.reserve,
                                                         glyph: MenuBarChevron.glyphLength)
                print(String(format: "largeur d'un chevron posé à gauche de %@ (x %.1f): %.1f",
                             leftmost.appName, leftmost.frame.minX, length))
            }
            if !Permissions.accessibility { print("Accessibilité : absente") }
            exit(0)
        }
        // `--menubar-layout`: prints macOS's position table, from the right of the bar to
        // the left, with the visible icon paired to each entry. Read-only.
        if CommandLine.arguments.contains("--menubar-layout") {
            guard let table = MenuBarLayoutStore.read() else {
                print("layout: table illisible (accès complet au disque ou dossier choisi requis)")
                exit(1)
            }
            let items = MenuBarInventory.withLayoutKeys(MenuBarInventory.scan().items, table: table)
            for (key, weight) in table.sorted(by: { $0.value < $1.value }) {
                let paired = items.filter { $0.layoutKeys.contains(key) }
                    .map { "\($0.appName) (x \(Int($0.frame.minX))\($0.layoutKeys.count > 1 ? ", ambigu" : ""))" }
                print(String(format: "%8.1f  ", weight) + key + (paired.isEmpty ? "" : "  ← " + paired.joined(separator: ", ")))
            }
            let unpaired = items.filter { $0.layoutKeys.isEmpty && !$0.isOverflowIndicator }
            if !unpaired.isEmpty { print("sans entrée : " + unpaired.map(\.appName).joined(separator: ", ")) }
            exit(0)
        }
        // `--menubar-toggle`: opens or closes the native overflow by AXPress, without starting the app.
        if CommandLine.arguments.contains("--menubar-toggle") {
            if let cause = MenuBarOverflow.toggleSync() {
                print("toggle: \(cause)")
                exit(1)
            }
            print("toggle: ok")
            exit(0)
        }
        // `--menubar-relay <bundleID>`: relays a click to that app's first icon, without
        // starting the app. The redrawn menu needs the app: its entries are only printed.
        if let i = CommandLine.arguments.firstIndex(of: "--menubar-relay") {
            guard CommandLine.arguments.indices.contains(i + 1) else { print("relay: bundle ID manquant"); exit(64) }
            exit(relayFromCommandLine(bundleID: CommandLine.arguments[i + 1]))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
