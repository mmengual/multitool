import AppKit

@main
enum Main {
    static func main() {
        // `--menubar-dump`: prints the menu bar inventory and exits, without starting the app.
        if CommandLine.arguments.contains("--menubar-dump") {
            let (items, indicator) = MenuBarInventory.scan()
            for item in items {
                let zone = item.zone == .main ? "main  " : "hidden"
                let x = String(format: "%7.1f", item.frame.minX)
                let width = String(format: "%6.1f", item.frame.width)
                print("\(zone)  \(x)  \(width)  \(item.appName)  \(item.label)\(item.isSystem ? "  [système]" : "")")
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
        // `--menubar-toggle`: opens or closes the native overflow by AXPress, without starting the app.
        if CommandLine.arguments.contains("--menubar-toggle") {
            if let cause = MenuBarOverflow.toggleSync() {
                print("toggle: \(cause)")
                exit(1)
            }
            print("toggle: ok")
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
