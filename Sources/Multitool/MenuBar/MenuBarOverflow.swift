import AppKit
import ApplicationServices

/// Opens and closes macOS's own menu bar overflow, by `AXPress` on its indicator
/// (`menu-bar-overflow-indicator`). No synthetic event, no full inventory scan.
enum MenuBarOverflow {
    /// Serial, so 2 quick clicks never press the indicator at the same time.
    private static let queue = DispatchQueue(label: "com.mmengual.multitool.menubar.overflow",
                                             qos: .userInitiated)

    /// Looks for the native indicator. Synchronous: off the main thread in the app, on
    /// the main thread in the CLI commands (no AX request targets our own process).
    /// Tries `com.apple.MenuBarAgent` first, then the other system apps of
    /// `MenuBarInventory.systemBundleIDs`. Never walks every running app.
    static func findIndicator() -> AXUIElement? {
        let first = "com.apple.MenuBarAgent"
        let order = [first] + MenuBarInventory.systemBundleIDs.subtracting([first]).sorted()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for bundleID in order {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let pid = app.processIdentifier
                guard pid > 0, pid != ownPID else { continue }
                if let indicator = indicator(in: pid) { return indicator }
            }
        }
        return nil
    }

    private static func indicator(in pid: pid_t) -> AXUIElement? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &barRef) == .success,
              let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return nil }
        let bar = barRef as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, 0.3)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.3)
            if MenuBarInventory.isOverflowIdentifier(MenuBarInventory.string(child, kAXIdentifierAttribute)) {
                return child
            }
        }
        return nil
    }

    /// AXPress on the indicator, on a background queue. `completion` runs on the main
    /// thread: `true` if the action was accepted, `false` if the indicator is missing,
    /// the permission is missing or the action was refused.
    static func toggle(completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let cause = toggleSync()
            if let cause {
                Log.menuBar.info("overflow toggle failed: \(cause, privacy: .public)")
            } else {
                Log.menuBar.info("overflow toggle: AXPress accepted")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(cause == nil) }
            }
        }
    }

    /// Synchronous variant, for `--menubar-toggle`. nil when accepted, else the cause.
    static func toggleSync() -> String? {
        guard Permissions.accessibility else { return "Accessibilité absente" }
        guard let indicator = findIndicator() else { return "indicateur absent" }
        let error = AXUIElementPerformAction(indicator, kAXPressAction as CFString)
        return error == .success ? nil : "AXPress refusé (AXError \(error.rawValue))"
    }
}
