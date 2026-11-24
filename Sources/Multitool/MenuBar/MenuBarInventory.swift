import AppKit
import ApplicationServices

/// One icon of the menu bar, as read through Accessibility.
struct MenuBarItem: Identifiable, Equatable {
    let id: String          // "\(bundleID)#\(index of the icon in its app)"
    let appName: String
    let bundleID: String
    let pid: pid_t
    let index: Int          // index among the children of the app's AXExtrasMenuBar
    let label: String       // readable label, may be empty
    let frame: CGRect       // global AX coordinates (origin at the top left)
    let isSystem: Bool      // owned by MenuBarAgent, Control Center or SystemUIServer
    let isOverflowIndicator: Bool // AXIdentifier "menu-bar-overflow-indicator", "-expanded" when open
}

/// Read-only inventory of the menu bar icons: no press, no event, no status item.
///
/// An app whose icon is switched off in macOS's per-app switches still reports its
/// icon here, with its old frame (measured on 24/11): this inventory says which apps
/// have an icon, never whether it is drawn. `MenuBarVisibility` knows that.
///
/// `@unchecked Sendable`: its state is only read and written on the main thread.
final class MenuBarInventory: ObservableObject, @unchecked Sendable {
    static let shared = MenuBarInventory()

    /// Sorted by `frame.minX`, the native overflow indicator excluded.
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var lastScan: Date?

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

    private init() {}

    /// Starts a background scan and publishes on the main thread. Ignored while one runs.
    @MainActor
    func refresh(completion: (@MainActor () -> Void)? = nil) {
        guard !scanning else { completion?(); return }
        guard Permissions.accessibility else {
            items = []
            lastScan = Date()
            completion?()
            return
        }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan().items
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    self.items = found
                    self.lastScan = Date()
                    completion?()
                }
            }
        }
    }

    // MARK: AX scan

    /// Apps that didn't answer within the AX timeout, skipped until the date. Measured
    /// on 23/11: 3 of 155 apps (web content processes) cost 300 ms each, and none
    /// has a menu bar icon. Any thread, under `unresponsiveLock`.
    private static var unresponsive: [pid_t: Date] = [:]
    private static let unresponsiveLock = NSLock()
    private static let unresponsiveDelay: TimeInterval = 60

    /// Synchronous scan of every other running app, in parallel. Call off the main
    /// thread. Multitool's own icons are not included: no Accessibility request to
    /// our own process. Background-only apps are skipped: none of the 63 measured on
    /// 23/11 had a menu bar icon.
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
                item(child, index: index, pid: pid, bundleID: bundleID, appName: appName)
            }
            lock.lock(); perApp[i] = items; lock.unlock()
        }
        var found: [MenuBarItem] = []
        var indicator: MenuBarItem?
        for item in perApp.joined() {
            if item.isOverflowIndicator { indicator = item } else { found.append(item) }
        }
        return (found.sorted { $0.frame.minX < $1.frame.minX }, indicator)
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

    private static func item(_ child: AXUIElement, index: Int, pid: pid_t,
                             bundleID: String, appName: String) -> MenuBarItem? {
        guard let frame = frame(child) else { return nil }
        let identifier = string(child, kAXIdentifierAttribute)
        let label = readableLabel(child, depth: 2)
        return MenuBarItem(
            id: "\(bundleID)#\(index)", appName: appName, bundleID: bundleID, pid: pid, index: index,
            label: label.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " "),
            frame: frame,
            isSystem: systemBundleIDs.contains(bundleID),
            isOverflowIndicator: isOverflowIdentifier(identifier))
    }

    // MARK: AX helpers

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
