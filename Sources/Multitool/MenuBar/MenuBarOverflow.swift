import AppKit
import ApplicationServices

/// Opens and closes macOS's own menu bar overflow (`menu-bar-overflow-indicator`), by
/// `AXPress` on its indicator. Only for the ⌥-click on the chevron and
/// `--menubar-toggle`: since lot 6 the module hides icons through macOS's per-app
/// switches and no longer needs the overflow.
enum MenuBarOverflow {
    private static let queue = DispatchQueue(label: "com.mmengual.multitool.menubar.overflow",
                                             qos: .userInitiated)

    /// Looks for the native indicator in `com.apple.MenuBarAgent`, then the other
    /// system apps. Never walks every running app.
    static func findIndicator() -> AXUIElement? {
        let first = "com.apple.MenuBarAgent"
        let order = [first] + MenuBarInventory.systemBundleIDs.subtracting([first]).sorted()
        for bundleID in order {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                for child in MenuBarInventory.barChildren(pid: app.processIdentifier)
                where MenuBarInventory.isOverflowIdentifier(MenuBarInventory.string(child, kAXIdentifierAttribute)) {
                    return child
                }
            }
        }
        return nil
    }

    /// Opens or closes the overflow off the main thread. `completion` runs on the main thread.
    static func toggle(completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let cause = toggleSync()
            Log.menuBar.info("overflow toggle: \(cause ?? "AXPress accepted", privacy: .public)")
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(cause == nil) } }
        }
    }

    /// nil when accepted, else the cause.
    static func toggleSync() -> String? {
        guard Permissions.accessibility else { return "Accessibilité absente" }
        guard let indicator = findIndicator() else { return "indicateur absent" }
        let error = AXUIElementPerformAction(indicator, kAXPressAction as CFString)
        return error == .success ? nil : "AXPress refusé (AXError \(error.rawValue))"
    }
}
