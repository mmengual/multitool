import AppKit
import ApplicationServices

/// Relays a click from the band to an icon evicted into macOS's overflow.
///
/// Measured on macOS 27.2 (series A, B, C of 23/11):
/// - an icon with an `AXMenu`: AXPress opens its menu, AppKit runs it without the
///   app's own code. An entry read while the overflow was open can still be pressed
///   once it is closed.
/// - an icon without a menu: AXPress runs the app's click handler outside a real
///   click. OneDrive ignores it, Sophos Connect crashes. These icons get a simulated
///   click, never an AXPress.
enum MenuBarRelay {
    enum Mode: Equatable { case redrawnMenu, nativeMenu, simulatedClick }

    /// One entry of a menu read through Accessibility, with its element kept for the press.
    struct Entry {
        let title: String
        let enabled: Bool
        let checked: Bool
        let isSeparator: Bool
        let element: AXUIElement
        var submenu: [Entry]
    }

    enum Outcome {
        /// Redrawn menu: show these entries under the band.
        case menu([Entry])
        /// The native menu or the simulated click is on its way: close the band.
        case dispatched(Mode)
        /// Another relay runs (a native menu stays open until it closes).
        case busy
        case failed(String)
    }

    private static let lock = NSLock()
    private static var running = false

    private static func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    private static func release() {
        lock.lock(); running = false; lock.unlock()
    }

    // MARK: Mode

    /// Pure. `entries` nil when the icon has no `AXMenu`, empty when its menu is
    /// filled on opening (Zoom, GlobalProtect), unreadable when one entry has
    /// neither a title nor the shape of a separator (custom view).
    static func mode(entries: [Entry]?, allReadable: Bool) -> Mode {
        guard let entries else { return .simulatedClick }
        return entries.isEmpty || !allReadable ? .nativeMenu : .redrawnMenu
    }

    // MARK: Entry point

    /// Relays a click on `item`. Refuses a second relay while one runs. `outcome`
    /// runs on the main thread, before the native menu or the simulated click starts.
    @MainActor
    static func relay(_ item: MenuBarItem, outcome: @escaping @MainActor (Outcome) -> Void) {
        guard claim() else {
            outcome(.busy)
            return
        }
        MenuBarOverflow.queue.async {
            perform(item) { result in
                DispatchQueue.main.async { MainActor.assumeIsolated { outcome(result) } }
            }
            release()
        }
    }

    /// Synchronous relay, on `MenuBarOverflow.queue` in the app, on the main thread in
    /// the CLI. `report` is called once, before the native menu or the click.
    static func perform(_ item: MenuBarItem, report: (Outcome) -> Void) {
        let start = DispatchTime.now()
        if case .failed(let cause) = MenuBarOverflow.openSync() {
            Log.menuBar.info("relay \(item.id, privacy: .public): overflow not opened: \(cause, privacy: .public)")
            report(.failed(cause))
            return
        }
        guard let element = waitReadable(item) else {
            Log.menuBar.info("relay \(item.id, privacy: .public): icon not readable after \(MenuBarOverflow.elapsedMS(since: start)) ms")
            MenuBarOverflow.closeIfHeldSync()
            report(.failed("icône illisible"))
            return
        }
        Log.menuBar.info("relay \(item.id, privacy: .public): icon readable in \(MenuBarOverflow.elapsedMS(since: start)) ms")

        let menu = MenuBarInventory.menu(of: element)
        let read = menu.map { readEntries($0, depth: 0) }
        let mode = mode(entries: read?.entries, allReadable: read?.allReadable ?? false)
        Log.menuBar.info("relay \(item.id, privacy: .public): mode \(String(describing: mode), privacy: .public), \(read?.entries.count ?? -1) entries")

        switch mode {
        case .redrawnMenu:
            MenuBarOverflow.closeIfHeldSync()
            report(.menu(read?.entries ?? []))
        case .nativeMenu:
            report(.dispatched(.nativeMenu))
            Thread.sleep(forTimeInterval: 0.05)   // the band closes first
            pressNativeMenu(element, menu: menu, item: item)
            MenuBarOverflow.closeIfHeldSync()
        case .simulatedClick:
            report(.dispatched(.simulatedClick))
            Thread.sleep(forTimeInterval: 0.05)
            simulateClick(on: element, item: item)
            Thread.sleep(forTimeInterval: 0.3)
            MenuBarOverflow.closeIfHeldSync()
        }
    }

    /// Presses a redrawn menu entry, on the overflow queue: never while a relay opens it.
    static func press(_ entry: Entry) {
        let element = entry.element
        let title = entry.title
        MenuBarOverflow.queue.async {
            AXUIElementSetMessagingTimeout(element, 2)
            let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
            Log.menuBar.info("redrawn entry \(title, privacy: .public): AXError \(error.rawValue)")
        }
    }

    // MARK: Steps

    /// The icon's element once the overflow shows it: same pid, same index, else the
    /// app's only icon. Reads that app alone, never the whole bar.
    private static func waitReadable(_ item: MenuBarItem) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(MenuBarOverflow.readableTimeout)
        repeat {
            let children = MenuBarInventory.barChildren(pid: item.pid)
            let candidate = children.indices.contains(item.index) ? children[item.index]
                : (children.count == 1 ? children[0] : nil)
            if let candidate, MenuBarInventory.frame(candidate) != nil { return candidate }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return nil
    }

    /// Reads a menu: title, enabled, check mark, one level of submenu. An entry with
    /// no title and no child is a separator; with children, a custom view: unreadable.
    static func readEntries(_ menu: AXUIElement, depth: Int) -> (entries: [Entry], allReadable: Bool) {
        var all = true
        var entries: [Entry] = []
        for child in MenuBarInventory.children(menu) {
            AXUIElementSetMessagingTimeout(child, 0.3)
            let title = MenuBarInventory.string(child, kAXTitleAttribute)
            let submenuElement = MenuBarInventory.menu(of: child)
            if title.isEmpty {
                if MenuBarInventory.children(child).isEmpty {
                    entries.append(Entry(title: "", enabled: false, checked: false, isSeparator: true,
                                         element: child, submenu: []))
                } else {
                    all = false
                }
                continue
            }
            var submenu: [Entry] = []
            if let submenuElement, depth == 0 {
                let sub = readEntries(submenuElement, depth: 1)
                submenu = sub.entries
                all = all && sub.allReadable
            }
            let mark = MenuBarInventory.string(child, kAXMenuItemMarkCharAttribute)
            entries.append(Entry(title: title,
                                 enabled: MenuBarInventory.bool(child, kAXEnabledAttribute) ?? true,
                                 checked: !mark.isEmpty, isSeparator: false,
                                 element: child, submenu: submenu))
        }
        return (entries, all)
    }

    /// AXPress on an icon with a menu. It returns when the menu closes, or -25204 at
    /// the AX timeout while the menu is still open: then the end of the menu is read
    /// from the app's pop-up menu windows (layer 101, measured with Teams), 30 s at most.
    /// The `AXMenu` frame isn't used: it may keep a size once the menu is closed.
    private static func pressNativeMenu(_ element: AXUIElement, menu: AXUIElement?, item: MenuBarItem) {
        let start = DispatchTime.now()
        AXUIElementSetMessagingTimeout(element, 30)
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        AXUIElementSetMessagingTimeout(element, 0.3)
        Log.menuBar.info("relay \(item.id, privacy: .public): native menu AXPress returned AXError \(error.rawValue) after \(MenuBarOverflow.elapsedMS(since: start)) ms")
        guard error == .cannotComplete, menu != nil else { return }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, hasMenuWindow(pid: item.pid) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        Log.menuBar.info("relay \(item.id, privacy: .public): native menu gone after \(MenuBarOverflow.elapsedMS(since: start)) ms")
    }

    /// True while `pid` shows a window at the pop-up menu level.
    private static func hasMenuWindow(pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == level
        }
    }

    /// A left click at the center of the icon, cursor put back. The frame is read
    /// again just before, and the click is dropped if the icon left the overflow.
    private static func simulateClick(on element: AXUIElement, item: MenuBarItem) {
        guard let frame = MenuBarInventory.frame(element) else {
            Log.menuBar.info("relay \(item.id, privacy: .public): no frame, click dropped")
            return
        }
        if let indicator = MenuBarOverflow.findIndicator(),
           let indicatorFrame = MenuBarInventory.frame(indicator), frame.minX >= indicatorFrame.minX {
            Log.menuBar.info("relay \(item.id, privacy: .public): icon no longer in the overflow, click dropped")
            return
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let start = DispatchTime.now()
        click(at: point)
        Log.menuBar.info("relay \(item.id, privacy: .public): simulated click at \(Int(point.x)),\(Int(point.y)) in \(MenuBarOverflow.elapsedMS(since: start)) ms")
    }

    /// Down and up at `point` (global, top-left origin), no modifier, cursor put back.
    static func click(at point: CGPoint) {
        let saved = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        // Without this, macOS freezes the mouse for about 0.25 s after the warp.
        source?.localEventsSuppressionInterval = 0
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: point, mouseButton: .left)
            // A ⌘ held while clicking in the band would turn this into a ⌘-drag.
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
        if let saved { CGWarpMouseCursorPosition(saved) }
    }
}
