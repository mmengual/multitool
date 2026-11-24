import AppKit

@main
enum Main {
    static func main() {
        // `--menubar-dump`: prints the menu bar inventory and exits, without starting the app.
        if CommandLine.arguments.contains("--menubar-dump") {
            let (items, indicator) = MenuBarInventory.scan()
            for item in items {
                let x = String(format: "%7.1f", item.frame.minX)
                let width = String(format: "%6.1f", item.frame.width)
                print("\(x)  \(width)  \(item.appName)  \(item.label)\(item.isSystem ? "  [système]" : "")")
            }
            print("indicateur natif: \(indicator == nil ? "absent" : "présent"), total: \(items.count)")
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
