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
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
