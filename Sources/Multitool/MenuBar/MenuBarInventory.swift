import AppKit
import ApplicationServices

/// One icon of the menu bar, as read through Accessibility.
struct MenuBarItem: Identifiable, Equatable {
    enum Zone { case main, hidden }

    let id: String          // "\(bundleID)#\(index of the icon in its app)"
    let appName: String
    let bundleID: String
    let pid: pid_t
    let index: Int          // index among the children of the app's AXExtrasMenuBar
    let label: String       // readable label, may be empty
    let frame: CGRect       // global AX coordinates (origin at the top left)
    let isSystem: Bool      // owned by MenuBarAgent, Control Center or SystemUIServer
    let isOverflowIndicator: Bool // AXIdentifier "menu-bar-overflow-indicator", "-expanded" when open
    var isExpanded = false  // the indicator only: its identifier ends with "-expanded"
    let hasMenu: Bool       // an AXMenu child: AppKit opens it without running the app's code
    var axIdentifier = ""   // its own AXIdentifier, else its first child's ("com.apple.menuextra.wifi")
    /// Its entries in macOS's position table (`MenuBarLayoutStore`). One when the
    /// pairing is sure, several when it is ambiguous, none when it has no entry.
    var layoutKeys: [String] = []
    var zone: Zone

    /// Key of the icon in `Settings.menuBarPlacements`: its table entry when it has
    /// one, stable across launches, else its app.
    var placementKey: String { layoutKeys.count == 1 ? layoutKeys[0] : legacyKey }
    /// Key used while the icon has no sure table entry (no access yet, ambiguous pairing).
    var legacyKey: String { "app:\(bundleID)#\(index)" }
    /// Names the table may know the owner by: the bundle ID, else the process name.
    var owners: [String] { bundleID.hasPrefix("pid") ? [appName] : [bundleID, appName] }
}

/// Inventory of the menu bar icons.
///
/// The light scan (`refresh()`) only reads: no press, no event. Overflow closed, an
/// evicted app loses its whole `AXExtrasMenuBar` (measured on macOS 27.2), so the
/// evicted icons are only known from a full scan (`fullScan`), which opens the native
/// overflow. The result is kept in `evicted`, the cache the band draws.
///
/// `@unchecked Sendable`: its state is only read and written on the main thread.
final class MenuBarInventory: ObservableObject, @unchecked Sendable {
    static let shared = MenuBarInventory()

    /// Sorted by `frame.minX`, the native overflow indicator excluded.
    @Published private(set) var items: [MenuBarItem] = []
    /// nil when macOS doesn't show it.
    @Published private(set) var overflowIndicator: MenuBarItem?
    @Published private(set) var overflowOpen = false
    @Published private(set) var lastScan: Date?

    /// Icons left of the indicator at the last full scan, corrected by the light scans.
    @Published private(set) var evicted: [MenuBarItem] = []
    /// Date of the last full scan, nil before the first one.
    @Published private(set) var lastFullScan: Date?
    /// The cache may miss icons: the next band opening runs a full scan.
    @Published private(set) var cacheStale = true
    /// macOS's position table could be read at the last scan.
    @Published private(set) var layoutAccess = false

    /// Multitool's main status item, set by `AppDelegate`: its window is the only one
    /// read for our own icon (the other `NSStatusBarWindow`s gave fake icons).
    @MainActor static weak var ownStatusItem: NSStatusItem?

    static let systemBundleIDs: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
    ]
    static let overflowIdentifier = "menu-bar-overflow-indicator"

    /// Closed, the indicator is "menu-bar-overflow-indicator". Open, it becomes
    /// "menu-bar-overflow-indicator-expanded" (measured on macOS 27.2.1), same frame.
    static func isOverflowIdentifier(_ identifier: String) -> Bool {
        identifier == overflowIdentifier || identifier == overflowIdentifier + "-expanded"
    }

    private var scanning = false   // main thread only
    /// Bundle IDs of the visible third-party icons at the last scan, for the stale rules.
    private var lastVisible: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.markStale("screens changed")
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.evicted.removeAll { $0.pid == app.processIdentifier }
        })
    }

    /// The next band opening runs a full scan. Main thread.
    func markStale(_ reason: String) {
        guard !cacheStale else { return }
        cacheStale = true
        Log.menuBar.info("evicted cache stale: \(reason, privacy: .public)")
    }

    // MARK: Light scan

    /// Starts a background light scan and publishes on the main thread. Ignored while
    /// one runs, and while Multitool holds the overflow open (a relay is moving the bar).
    @MainActor
    func refresh(completion: (@MainActor () -> Void)? = nil) {
        guard !scanning, !MenuBarOverflow.heldOpen else { completion?(); return }
        guard Permissions.accessibility else {
            publish(items: [], indicator: nil)
            completion?()
            return
        }
        scanning = true
        // Multitool's own icon is read here, on the main thread: querying our own
        // process through AX from a background thread crashed before.
        let own = Self.ownItems()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.scan()
            let table = MenuBarLayoutStore.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    self.layoutAccess = table != nil
                    self.publish(items: Self.withLayoutKeys(result.items + own, table: table), indicator: result.indicator)
                    completion?()
                }
            }
        }
    }

    // MARK: Full scan

    /// Opens the overflow if needed, waits until the bar is stable, reads every icon,
    /// then closes the overflow if Multitool opened it. Fills `evicted`.
    /// `completion` runs on the main thread, with nil or the cause of the failure.
    @MainActor
    func fullScan(completion: @escaping @MainActor (String?) -> Void) {
        guard Permissions.accessibility else { completion("Accessibilité absente"); return }
        let start = DispatchTime.now()
        MenuBarOverflow.queue.async {
            if case .failed(let cause) = MenuBarOverflow.openSync() {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(cause) } }
                return
            }
            let result = Self.stableScan()
            // Our own icon is read on the main thread, overflow still open: evicted,
            // it is only on screen now.
            let own: [MenuBarItem] = DispatchQueue.main.sync {
                MainActor.assumeIsolated { Self.ownItems() }
            }
            MenuBarOverflow.closeIfHeldSync()
            let table = MenuBarLayoutStore.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.layoutAccess = table != nil
                    let (list, _) = Self.assignZones(Self.withLayoutKeys(result.items + own, table: table), indicator: result.indicator)
                    self.evicted = list.filter { $0.zone == .hidden }
                    self.lastFullScan = Date()
                    self.cacheStale = false
                    self.lastVisible = Self.visibleKeys(list.filter { $0.zone == .main })
                    Log.menuBar.info("full scan: \(self.evicted.count) evicted icons in \(MenuBarOverflow.elapsedMS(since: start)) ms")
                    completion(nil)
                }
            }
        }
    }

    /// Scans until 2 reads 20 ms apart agree, `readableTimeout` at most. Off the main thread.
    static func stableScan() -> (items: [MenuBarItem], indicator: MenuBarItem?) {
        let deadline = Date().addingTimeInterval(MenuBarOverflow.readableTimeout)
        var previous = scan()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            let next = scan()
            if signature(next.items) == signature(previous.items) { return next }
            previous = next
        }
        return previous
    }

    private static func signature(_ items: [MenuBarItem]) -> [String] {
        items.map { "\($0.id)@\(Int($0.frame.minX))" }
    }

    private static func visibleKeys(_ items: [MenuBarItem]) -> Set<String> {
        Set(items.filter { !$0.isSystem }.map(\.bundleID))
    }

    // MARK: Publish

    @MainActor
    private func publish(items found: [MenuBarItem], indicator: MenuBarItem?) {
        let (list, _) = Self.assignZones(found, indicator: indicator)
        // Open is what the indicator says, not "an icon left of it": during the closing
        // animation, or with a misplaced frame, icons can sit left of a closed indicator.
        let open = indicator?.isExpanded ?? false
        items = list
        overflowIndicator = indicator
        overflowOpen = open
        lastScan = Date()
        updateCache(list: list, indicator: indicator, open: open)
    }

    /// Light scan → cache. Without an indicator nothing is evicted. Overflow open, the
    /// scan sees everything: it is as good as a full scan. Overflow closed, the stale
    /// rules apply: no icon-by-icon correction, `#index` differs between the 2 states.
    @MainActor
    private func updateCache(list: [MenuBarItem], indicator: MenuBarItem?, open: Bool) {
        let visible = Self.visibleKeys(list.filter { $0.zone == .main })
        defer { lastVisible = visible }
        guard indicator != nil else {
            evicted = []
            lastFullScan = Date()
            cacheStale = false
            return
        }
        if open {
            evicted = list.filter { $0.zone == .hidden }
            lastFullScan = Date()
            cacheStale = false
            return
        }
        evicted.removeAll { NSRunningApplication(processIdentifier: $0.pid) == nil }
        if lastFullScan == nil { cacheStale = true; return }
        let known = lastVisible.union(evicted.map(\.bundleID))
        if let newcomer = visible.subtracting(known).first {
            markStale("new icon \(newcomer)")
        } else if let gone = lastVisible.subtracting(visible).subtracting(evicted.map(\.bundleID)).first(where: { bundleID in
            // An app with one icon evicted loses all of them overflow closed: excluded.
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }) {
            markStale("icon left the visible bar: \(gone)")
        }
    }

    /// Pairs the icons with the entries of macOS's position table. Unchanged without access.
    /// A pairing that was sure once is remembered for the session: the light scan sees
    /// fewer icons than the full scan and may find the same icon ambiguous.
    static func withLayoutKeys(_ found: [MenuBarItem], table: [String: Double]?) -> [MenuBarItem] {
        guard let table else { return found }
        var list = found.sorted { $0.frame.minX < $1.frame.minX }
        let pairs = MenuBarLayoutStore.match(
            // Another Multitool's chevron (seen by the CLI) is a separator, not an icon.
            items: list.filter { $0.label != MenuBarChevron.accessibilityLabel }
                .map { (id: $0.id, owners: $0.owners, axIdentifier: $0.axIdentifier) }, table: table)
        rememberedLock.lock(); defer { rememberedLock.unlock() }
        for i in list.indices {
            let memo = "\(list[i].bundleID)|\(list[i].axIdentifier)|\(list[i].index)"
            let keys = pairs[list[i].id] ?? []
            if keys.count == 1 {
                remembered[memo] = keys
                list[i].layoutKeys = keys
            } else if let known = remembered[memo], known.allSatisfy({ table[$0] != nil }) {
                list[i].layoutKeys = known
            } else {
                list[i].layoutKeys = keys
            }
        }
        return list
    }

    private static var remembered: [String: [String]] = [:]
    private static let rememberedLock = NSLock()

    /// Sorts by `minX` and marks as hidden the icons left of the overflow indicator.
    /// Without an indicator everything is `.main`. `open` is true when one icon is hidden.
    static func assignZones(_ found: [MenuBarItem], indicator: MenuBarItem?) -> (items: [MenuBarItem], open: Bool) {
        var list = found.sorted { $0.frame.minX < $1.frame.minX }
        var open = false
        if let indicator {
            for i in list.indices where list[i].frame.minX < indicator.frame.minX {
                list[i].zone = .hidden
                open = true
            }
        }
        return (list, open)
    }

    /// Multitool's main status item, in top-left origin coordinates, only when its
    /// window is on a screen and visible. The chevron is a separator, not an icon.
    @MainActor
    static func ownItems() -> [MenuBarItem] {
        guard let screenHeight = NSScreen.screens.first?.frame.height,
              let window = ownStatusItem?.button?.window,
              window.screen != nil, window.occlusionState.contains(.visible) else { return [] }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mmengual.multitool"
        let f = window.frame
        let frame = CGRect(x: f.minX, y: screenHeight - f.maxY, width: f.width, height: f.height)
        return [MenuBarItem(id: "\(bundleID)#0", appName: ProcessInfo.processInfo.processName, bundleID: bundleID,
                            pid: ProcessInfo.processInfo.processIdentifier, index: 0, label: "Multitool",
                            frame: frame, isSystem: false, isOverflowIndicator: false, isExpanded: false, hasMenu: false,
                            zone: .main)]
    }

    // MARK: AX scan

    /// Apps that didn't answer within the AX timeout, skipped until the date. Measured
    /// on 23/11: 3 of 155 apps (web content processes) cost 300 ms each, and none
    /// has a menu bar icon. Any thread, under `unresponsiveLock`.
    private static var unresponsive: [pid_t: Date] = [:]
    private static let unresponsiveLock = NSLock()
    private static let unresponsiveDelay: TimeInterval = 60

    /// Synchronous scan of every other running app, in parallel. Call off the main
    /// thread. Multitool's own icon is not included (see `refresh()`). Background-only
    /// apps are skipped: none of the 63 measured on 23/11 had a menu bar icon.
    static func scan() -> (items: [MenuBarItem], indicator: MenuBarItem?) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let now = Date()
        unresponsiveLock.lock()
        unresponsive = unresponsive.filter { $0.value > now }
        let skipped = Set(unresponsive.keys)
        unresponsiveLock.unlock()

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier > 0 && $0.processIdentifier != ownPID
                && $0.activationPolicy != .prohibited && !skipped.contains($0.processIdentifier)
        }
        var perApp = [[MenuBarItem]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            let pid = app.processIdentifier
            let (children, timedOut) = barChildrenReporting(pid: pid)
            if timedOut {
                unresponsiveLock.lock()
                unresponsive[pid] = Date().addingTimeInterval(unresponsiveDelay)
                unresponsiveLock.unlock()
            }
            guard !children.isEmpty else { return }
            let bundleID = app.bundleIdentifier ?? "pid\(pid)"
            let appName = app.localizedName ?? bundleID
            let items = children.enumerated().compactMap { index, child in
                item(child, index: index, app: app, bundleID: bundleID, appName: appName)
            }
            lock.lock(); perApp[i] = items; lock.unlock()
        }
        var found: [MenuBarItem] = []
        var indicator: MenuBarItem?
        for item in perApp.joined() {
            if item.isOverflowIndicator { indicator = item } else { found.append(item) }
        }
        return (assignZones(found, indicator: indicator).items, indicator)
    }

    /// Children of the app's `AXExtrasMenuBar`, empty when it has none.
    static func barChildren(pid: pid_t) -> [AXUIElement] {
        barChildrenReporting(pid: pid).children
    }

    /// Same, and whether the app missed the AX timeout.
    private static func barChildrenReporting(pid: pid_t) -> (children: [AXUIElement], timedOut: Bool) {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var barRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &barRef)
        guard error == .success, let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID()
        else { return ([], error == .cannotComplete) }
        let bar = barRef as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, 0.3)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return ([], false) }
        children.forEach { AXUIElementSetMessagingTimeout($0, 0.3) }
        return (children, false)
    }

    private static func item(_ child: AXUIElement, index: Int, app: NSRunningApplication,
                             bundleID: String, appName: String) -> MenuBarItem? {
        guard let origin = point(child, kAXPositionAttribute),
              let size = size(child, kAXSizeAttribute) else { return nil }
        let identifier = string(child, kAXIdentifierAttribute)
        let label = readableLabel(child, depth: 2)
        return MenuBarItem(
            id: "\(bundleID)#\(index)", appName: appName, bundleID: bundleID, pid: app.processIdentifier,
            index: index,
            label: label.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " "),
            frame: CGRect(origin: origin, size: size),
            isSystem: systemBundleIDs.contains(bundleID),
            isOverflowIndicator: isOverflowIdentifier(identifier),
            isExpanded: identifier.hasSuffix("-expanded"),
            hasMenu: menu(of: child) != nil,
            axIdentifier: identifier.isEmpty ? (children(child).first.map { string($0, kAXIdentifierAttribute) } ?? "") : identifier,
            zone: .main)
    }

    // MARK: AX helpers

    /// The `AXMenu` child of a menu bar icon or of a menu entry, nil without one.
    static func menu(of element: AXUIElement) -> AXUIElement? {
        children(element).first { string($0, kAXRoleAttribute) == "AXMenu" }
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success
        else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    /// Description, title or help of the element, else of its first descendant that has
    /// one. The system items (clock, Wi-Fi…) carry their name one or two levels down.
    static func readableLabel(_ element: AXUIElement, depth: Int) -> String {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            let value = string(element, attribute)
            if !value.isEmpty { return value }
        }
        guard depth > 0 else { return "" }
        // Never into an icon's menu: reading the items of a closed menu makes its app
        // build it, and some apps then take the keyboard focus away from the frontmost
        // app (measured on 23/11: reading Amphetamine's menu items brought another app
        // to the front, at each scan). Reading the role is safe.
        for child in children(element).prefix(4) where string(child, kAXRoleAttribute) != "AXMenu" {
            let value = readableLabel(child, depth: depth - 1)
            if !value.isEmpty { return value }
        }
        return ""
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return "" }
        return (ref as? String) ?? ""
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? Bool) ?? (ref as? NSNumber)?.boolValue
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var value = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &value) ? value : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var value = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &value) ? value : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute),
              let size = size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
