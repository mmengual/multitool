import AppKit
import ApplicationServices

/// One icon of the menu bar, as read through Accessibility.
struct MenuBarItem: Identifiable, Equatable {
    enum Zone { case main, hidden }

    let id: String          // "\(bundleID)#\(index of the icon in its app)"
    let appName: String
    let bundleID: String
    let pid: pid_t
    let label: String       // readable label, may be empty
    let frame: CGRect       // global AX coordinates (origin at the top left)
    let isSystem: Bool      // owned by MenuBarAgent, Control Center or SystemUIServer
    let isOverflowIndicator: Bool // AXIdentifier "menu-bar-overflow-indicator", "-expanded" when open
    var zone: Zone
}

/// Read-only inventory of the menu bar icons. It never acts on the bar: no click,
/// no AXPress, no synthetic event, no status item.
/// `@unchecked Sendable`: its state is only read and written on the main thread
/// (`refresh()` is main actor, the background scan publishes through the main queue).
final class MenuBarInventory: ObservableObject, @unchecked Sendable {
    static let shared = MenuBarInventory()

    /// Sorted by `frame.minX`, the native overflow indicator excluded.
    @Published private(set) var items: [MenuBarItem] = []
    /// nil when macOS doesn't show it.
    @Published private(set) var overflowIndicator: MenuBarItem?
    @Published private(set) var overflowOpen = false
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

    /// Starts a background scan and publishes on the main thread. Ignored while one runs.
    @MainActor
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !scanning else { return }
        guard Permissions.accessibility else {
            publish(items: [], indicator: nil)
            return
        }
        scanning = true
        // Multitool's own icon is read here, from its window: querying our own process
        // through AX from a background thread serves the request in-process on that
        // thread, which crashed before.
        let own = Self.ownItems()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.scan()
            let found = result.items + own
            DispatchQueue.main.async {
                self.scanning = false
                self.publish(items: found, indicator: result.indicator)
            }
        }
    }

    private func publish(items found: [MenuBarItem], indicator: MenuBarItem?) {
        let (list, open) = Self.assignZones(found, indicator: indicator)
        items = list
        overflowIndicator = indicator
        overflowOpen = open
        lastScan = Date()
    }

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

    /// Multitool's own status item windows, in top-left origin coordinates, the chevron
    /// excluded: it is a separator, not an icon.
    @MainActor
    private static func ownItems() -> [MenuBarItem] {
        guard let screenHeight = NSScreen.screens.first?.frame.height else { return [] }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mmengual.multitool"
        let chevron = MenuBarChevron.shared.windowNumber
        let windows = NSApp.windows.filter {
            $0.className.contains("NSStatusBarWindow") && $0.windowNumber != chevron
        }
        return windows.enumerated().map { index, window in
            let f = window.frame
            let frame = CGRect(x: f.minX, y: screenHeight - f.maxY, width: f.width, height: f.height)
            return MenuBarItem(id: "\(bundleID)#\(index)", appName: "Multitool", bundleID: bundleID,
                               pid: ProcessInfo.processInfo.processIdentifier, label: "Multitool",
                               frame: frame, isSystem: false, isOverflowIndicator: false, zone: .main)
        }
    }

    /// Synchronous scan of every other running app. Call off the main thread.
    /// Multitool's own icon is not included (see `refresh()`).
    static func scan() -> (items: [MenuBarItem], indicator: MenuBarItem?) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [MenuBarItem] = []
        var indicator: MenuBarItem?

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            if pid == ownPID || pid <= 0 { continue }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.3)

            var barRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &barRef) == .success,
                  let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { continue }
            let bar = barRef as! AXUIElement
            AXUIElementSetMessagingTimeout(bar, 0.3)

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }

            let bundleID = app.bundleIdentifier ?? "pid\(pid)"
            let appName = app.localizedName ?? bundleID
            for (index, child) in children.enumerated() {
                AXUIElementSetMessagingTimeout(child, 0.3)
                guard let origin = point(child, kAXPositionAttribute),
                      let size = size(child, kAXSizeAttribute) else { continue }
                let identifier = string(child, kAXIdentifierAttribute)
                let label = readableLabel(child, depth: 2)
                let item = MenuBarItem(
                    id: "\(bundleID)#\(index)", appName: appName, bundleID: bundleID, pid: pid,
                    label: label.replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " "),
                    frame: CGRect(origin: origin, size: size),
                    isSystem: systemBundleIDs.contains(bundleID),
                    isOverflowIndicator: isOverflowIdentifier(identifier),
                    zone: .main)
                if item.isOverflowIndicator { indicator = item } else { found.append(item) }
            }
        }
        return (assignZones(found, indicator: indicator).items, indicator)
    }

    // MARK: AX helpers

    /// Description, title or help of the element, else of its first descendant that has
    /// one. The system items (clock, Wi-Fi…) carry their name one or two levels down.
    static func readableLabel(_ element: AXUIElement, depth: Int) -> String {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            let value = string(element, attribute)
            if !value.isEmpty { return value }
        }
        guard depth > 0 else { return "" }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return "" }
        for child in children.prefix(4) {
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
}
