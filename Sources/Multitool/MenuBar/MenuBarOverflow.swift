import AppKit
import ApplicationServices

/// Sole owner of macOS's own menu bar overflow (`menu-bar-overflow-indicator`).
/// Every press on the indicator goes through `queue`, and every press re-reads the
/// indicator state first: macOS also closes the overflow on its own, for instance
/// when an app comes to the front. No synthetic event here.
enum MenuBarOverflow {
    /// Serial: the ⌥-click, the full scan and the relay never press at the same time.
    static let queue = DispatchQueue(label: "com.mmengual.multitool.menubar.overflow",
                                     qos: .userInitiated)

    /// Measured on macOS 27.2: an evicted icon is readable 30 to 54 ms after the press.
    static let readableTimeout: TimeInterval = 0.5

    private static let lock = NSLock()
    private static var held = false

    /// True while Multitool keeps open an overflow it opened itself. Any thread.
    /// The chevron doesn't recalculate its length meanwhile (the bar moves).
    static var heldOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    private static func setHeld(_ value: Bool) {
        lock.lock(); held = value; lock.unlock()
    }

    // MARK: Indicator

    /// Looks for the native indicator. Synchronous: on `queue` in the app, on the main
    /// thread in the CLI commands (no AX request targets our own process).
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

    /// The identifier ends with "-expanded" while the overflow is open.
    static func isExpanded(_ indicator: AXUIElement) -> Bool {
        MenuBarInventory.string(indicator, kAXIdentifierAttribute).hasSuffix("-expanded")
    }

    // MARK: Open and close (on `queue`, or the main thread in the CLI)

    enum OpenResult {
        case alreadyOpen, opened
        case failed(String)
    }

    /// Opens the overflow if it is closed. Marks it held only when Multitool opened it.
    static func openSync() -> OpenResult {
        guard Permissions.accessibility else { return .failed("Accessibilité absente") }
        guard let indicator = findIndicator() else { return .failed("indicateur absent") }
        if isExpanded(indicator) { return .alreadyOpen }
        let error = AXUIElementPerformAction(indicator, kAXPressAction as CFString)
        guard error == .success else { return .failed("AXPress refusé (AXError \(error.rawValue))") }
        setHeld(true)
        return .opened
    }

    /// Closes the overflow only if Multitool opened it and it is still open.
    /// `held` stays true until the indicator reads closed: a light scan during the
    /// closing animation would see a half-open bar.
    static func closeIfHeldSync() {
        guard heldOpen else { return }
        defer { setHeld(false) }
        guard let indicator = findIndicator(), isExpanded(indicator) else {
            Log.menuBar.info("overflow already closed by macOS")
            return
        }
        let start = DispatchTime.now()
        let error = AXUIElementPerformAction(indicator, kAXPressAction as CFString)
        let deadline = Date().addingTimeInterval(readableTimeout)
        while Date() < deadline, isExpanded(indicator) { Thread.sleep(forTimeInterval: 0.01) }
        Log.menuBar.info("overflow closed: AXError \(error.rawValue) in \(elapsedMS(since: start)) ms")
    }

    // MARK: Toggle (⌥-click on the chevron, `--menubar-toggle`)

    /// Opens or closes the overflow on `queue`. An overflow opened here belongs to
    /// the user: it is not held. `completion` runs on the main thread.
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

    /// Synchronous variant. nil when accepted, else the cause.
    static func toggleSync() -> String? {
        guard Permissions.accessibility else { return "Accessibilité absente" }
        guard let indicator = findIndicator() else { return "indicateur absent" }
        let error = AXUIElementPerformAction(indicator, kAXPressAction as CFString)
        setHeld(false)
        return error == .success ? nil : "AXPress refusé (AXError \(error.rawValue))"
    }

    static func elapsedMS(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
