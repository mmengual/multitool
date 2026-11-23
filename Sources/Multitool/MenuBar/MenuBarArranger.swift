import AppKit
import ApplicationServices
import Combine

/// Moves an icon to one side of the chevron: right of it (main bar) or left of it
/// (hidden, shown in the band).
///
/// First by writing the icon's weight in macOS's position table and making
/// MenuBarAgent read it again: no cursor, no overflow. If the icon doesn't follow
/// (no access to the table, no entry, wrong entry), by a simulated ⌘-drag
/// (measured on 23/11: about 680 ms, overflow open first for an evicted icon).
enum MenuBarArranger {
    enum Side: Equatable { case main, hidden }

    enum Outcome: Equatable {
        case alreadyThere
        case moved(String)      // "table" or "drag"
        case failed(String)
    }

    /// Time given to MenuBarAgent to apply a write (measured: under 3 s).
    private static let settleTimeout: TimeInterval = 3
    /// No keyboard or mouse input for this long before a simulated drag starts.
    private static let idleBeforeDrag: TimeInterval = 0.4
    /// A drag waits this long for the user to stop, then gives up.
    private static let idleTimeout: TimeInterval = 10
    /// Room an icon takes in the bar beyond its width.
    static let itemSpacing: CGFloat = 4

    /// Moves `item`. Serialized with the relay and the full scan on the overflow queue.
    @MainActor
    static func move(_ item: MenuBarItem, to side: Side, completion: @escaping @MainActor (Outcome) -> Void) {
        MenuBarOverflow.queue.async {
            MenuBarOverflow.setArranging(true)
            let outcome = perform(item, to: side)
            MenuBarOverflow.closeIfHeldSync()
            MenuBarOverflow.setArranging(false)
            Log.menuBar.info("arrange \(item.placementKey, privacy: .public) to \(String(describing: side), privacy: .public): \(String(describing: outcome), privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MenuBarChevron.shared.arrangementEnded()
                    MenuBarInventory.shared.markStale("icon arranged")
                    completion(outcome)
                }
            }
        }
    }

    // MARK: Steps (on the overflow queue)

    private static func perform(_ item: MenuBarItem, to side: Side) -> Outcome {
        guard chevronFrame() != nil else { return .failed("chevron absent de la barre") }
        if isOn(side, item) == true { return .alreadyThere }

        var tableNote = "pas d'accès à la table"
        if let table = MenuBarLayoutStore.read() {
            if item.layoutKeys.isEmpty {
                tableNote = "icône sans entrée dans la table"
            } else if let chevronWeight = chevronWeight(in: table) {
                let weight = Self.weight(for: side, chevron: chevronWeight,
                                         others: table.filter { !item.layoutKeys.contains($0.key) }.map(\.value))
                let written = MenuBarLayoutStore.write(Dictionary(uniqueKeysWithValues: item.layoutKeys.map { ($0, weight) }))
                Log.menuBar.info("arrange: weight \(weight) written for \(item.layoutKeys.joined(separator: ", "), privacy: .public): \(written)")
                if written {
                    let shrink = side == .main ? item.frame.width + itemSpacing : 0
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated { MenuBarChevron.shared.forceLayoutRead(shrinkBy: shrink) }
                    }
                    if waitUntilOn(side, item) { return .moved("table") }
                    tableNote = "écriture sans effet"
                } else {
                    tableNote = "écriture refusée"
                }
            } else {
                tableNote = "chevron sans entrée dans la table"
            }
        }
        Log.menuBar.info("arrange: \(tableNote, privacy: .public), falling back to the ⌘-drag")

        if let cause = drag(item, to: side) { return .failed("\(tableNote), glisser : \(cause)") }
        return waitUntilOn(side, item) ? .moved("drag") : .failed("\(tableNote), glisser sans effet")
    }

    /// Pure. A weight on the wanted side of the chevron, halfway to its neighbour so
    /// the order of the other icons doesn't change. Weights grow from right to left.
    static func weight(for side: Side, chevron: Double, others: [Double]) -> Double {
        switch side {
        case .main:
            let neighbour = others.filter { $0 < chevron }.max() ?? (chevron - 20)
            return (chevron + neighbour) / 2
        case .hidden:
            let neighbour = others.filter { $0 > chevron }.min() ?? (chevron + 20)
            return (chevron + neighbour) / 2
        }
    }

    /// The chevron's own entry: its autosave name under our bundle ID, else our process name.
    private static func chevronWeight(in table: [String: Double]) -> Double? {
        let suffix = "::" + MenuBarChevron.autosaveName
        let owners = [Bundle.main.bundleIdentifier, ProcessInfo.processInfo.processName].compactMap { $0 }
        for owner in owners {
            if let weight = table["status:\(owner)\(suffix)"] { return weight }
        }
        return nil
    }

    // MARK: Where the icon is

    private static func chevronFrame() -> CGRect? {
        DispatchQueue.main.sync { MainActor.assumeIsolated { MenuBarChevron.shared.frameAX } }
    }

    /// Frame of the icon if the bar draws it now. Our own icon is read from its window,
    /// on the main thread: no Accessibility request to our own process.
    private static func frame(of item: MenuBarItem) -> CGRect? {
        if item.pid == ProcessInfo.processInfo.processIdentifier {
            return DispatchQueue.main.sync { MainActor.assumeIsolated { MenuBarInventory.ownItems().first?.frame } }
        }
        return element(of: item).flatMap(MenuBarInventory.frame)
    }

    /// The icon's element now. Its index among its app's icons changes between the
    /// open and the closed overflow: the identifier first, then the label, then the index.
    private static func element(of item: MenuBarItem) -> AXUIElement? {
        let children = MenuBarInventory.barChildren(pid: item.pid)
        if !item.axIdentifier.isEmpty {
            return children.first { child in
                let own = MenuBarInventory.string(child, kAXIdentifierAttribute)
                let inner = MenuBarInventory.children(child).first.map { MenuBarInventory.string($0, kAXIdentifierAttribute) }
                return own == item.axIdentifier || inner == item.axIdentifier
            }
        }
        if children.count == 1 { return children[0] }
        if !item.label.isEmpty,
           let byLabel = children.first(where: { MenuBarInventory.readableLabel($0, depth: 2) == item.label }) {
            return byLabel
        }
        return children.indices.contains(item.index) ? children[item.index] : nil
    }

    /// nil when the chevron can't be read. Main: drawn right of the chevron. Hidden:
    /// not drawn, or drawn left of the chevron (screen without a notch).
    /// An icon that isn't drawn proves nothing alone (its app may not answer): it
    /// counts as hidden only if its app runs and its weight in the table, when it has
    /// one, is on the hidden side of the chevron's.
    private static func isOn(_ side: Side, _ item: MenuBarItem) -> Bool? {
        guard let chevron = chevronFrame() else { return nil }
        if let frame = frame(of: item) {
            return side == .main ? frame.minX >= chevron.maxX - 2 : frame.maxX <= chevron.minX + 2
        }
        guard side == .hidden, NSRunningApplication(processIdentifier: item.pid) != nil else { return false }
        if let table = MenuBarLayoutStore.read(), let chevronWeight = chevronWeight(in: table),
           let weight = item.layoutKeys.compactMap({ table[$0] }).max() {
            return weight > chevronWeight
        }
        return true
    }

    private static func waitUntilOn(_ side: Side, _ item: MenuBarItem) -> Bool {
        let deadline = Date().addingTimeInterval(settleTimeout)
        var agreeing = 0
        while Date() < deadline {
            // 2 reads in a row: the bar is still moving after a write.
            agreeing = isOn(side, item) == true ? agreeing + 1 : 0
            if agreeing >= 2 { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    // MARK: ⌘-drag

    /// nil when the drag was posted, else why not.
    private static func drag(_ item: MenuBarItem, to side: Side) -> String? {
        guard Permissions.accessibility else { return "Accessibilité absente" }
        guard waitForIdle() else { return "souris ou clavier en usage" }

        var from = frame(of: item)
        if from == nil {
            // Evicted: only the open overflow draws it.
            if case .failed(let cause) = MenuBarOverflow.openSync() { return cause }
            let deadline = Date().addingTimeInterval(MenuBarOverflow.readableTimeout * 2)
            while from == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                from = frame(of: item)
            }
            Thread.sleep(forTimeInterval: 0.2)
            from = frame(of: item) ?? from
        }
        guard let from, let chevron = chevronFrame() else { return "icône illisible" }
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: side == .main ? chevron.maxX + 6 : chevron.minX + 7, y: from.midY)
        commandDrag(from: start, to: end)
        Thread.sleep(forTimeInterval: 0.3)
        MenuBarOverflow.closeIfHeldSync()
        return nil
    }

    private static func waitForIdle() -> Bool {
        let deadline = Date().addingTimeInterval(idleTimeout)
        let any = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
        while Date() < deadline {
            if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) >= idleBeforeDrag { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// A ⌘-drag in about 600 ms, cursor put back.
    private static func commandDrag(from: CGPoint, to: CGPoint) {
        let saved = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        func post(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, from)
        Thread.sleep(forTimeInterval: 0.05)
        post(.leftMouseDown, from)
        Thread.sleep(forTimeInterval: 0.15)
        let steps = 20
        for i in 1...steps {
            let k = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k))
            Thread.sleep(forTimeInterval: 0.015)
        }
        Thread.sleep(forTimeInterval: 0.1)
        post(.leftMouseUp, to)
        if let saved { CGWarpMouseCursorPosition(saved) }
        Log.menuBar.info("arrange: ⌘-drag from x \(Int(from.x)) to x \(Int(to.x))")
    }
}

/// Zone chosen for an icon in the settings.
enum MenuBarPlacement: String {
    case main, hidden, masked

    var side: MenuBarArranger.Side { self == .main ? .main : .hidden }
}

/// Keeps the 2 boxes of the settings page and the bar in agreement. A box that changes
/// moves the icon. An icon the user moved by hand changes its box: the bar wins.
@MainActor
final class MenuBarClassifier: ObservableObject {
    static let shared = MenuBarClassifier()

    /// Message under a row: "Pas assez de place…", "Non déplacée…".
    @Published private(set) var notes: [String: String] = [:]
    /// Rows whose icon is being moved.
    @Published private(set) var busy: Set<String> = []

    private let settings = Settings.shared
    private let inventory = MenuBarInventory.shared
    private var cancellables: Set<AnyCancellable> = []
    private var pendingMainWidth: CGFloat = 0
    private var lastArrangement = Date.distantPast

    private init() {
        inventory.$lastScan
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.syncWithBar() } }
            .store(in: &cancellables)
    }

    /// Icons of the page: the visible bar, then the cache of the evicted ones (an icon
    /// that came back to the visible bar since the cache was read is listed once).
    var rows: [MenuBarItem] {
        let visible = inventory.items.filter { $0.zone == .main }
        let keys = Set(visible.map(\.placementKey))
        return visible + inventory.evicted.filter { !keys.contains($0.placementKey) }
    }

    /// Where the icon is, by the chevron and not by macOS's indicator: an icon drawn
    /// left of the chevron (capped chevron, screen without a notch) is on the hidden side.
    func actualSide(of item: MenuBarItem) -> MenuBarArranger.Side {
        if item.zone == .hidden { return .hidden }
        if let chevron = MenuBarChevron.shared.frameAX, item.frame.maxX <= chevron.minX + 2 { return .hidden }
        return .main
    }

    func placement(of item: MenuBarItem) -> MenuBarPlacement? {
        settings.menuBarPlacements[item.placementKey].flatMap(MenuBarPlacement.init(rawValue:))
    }

    /// Placement shown by the boxes: the choice, else where the icon is.
    func shownPlacement(of item: MenuBarItem) -> MenuBarPlacement {
        placement(of: item) ?? (actualSide(of: item) == .hidden ? .hidden : .main)
    }

    /// Clock and Control Center stay in the main bar: macOS doesn't move them.
    func isFixed(_ item: MenuBarItem) -> Bool {
        ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"].contains(item.axIdentifier)
    }

    func isNew(_ item: MenuBarItem) -> Bool {
        !settings.menuBarPlacements.isEmpty && placement(of: item) == nil && !isFixed(item)
    }

    /// Records where the icon is, without moving it.
    func keep(_ item: MenuBarItem) {
        settings.menuBarPlacements[item.placementKey] = (actualSide(of: item) == .hidden ? MenuBarPlacement.hidden : .main).rawValue
    }

    /// A box changed: records the choice and moves the icon if it is on the wrong side.
    func set(_ placement: MenuBarPlacement, for item: MenuBarItem) {
        let key = item.placementKey
        notes[key] = nil
        let actual = actualSide(of: item)
        if placement.side == .main, actual == .hidden, let free = MenuBarChevron.shared.freeSpace {
            let cost = item.frame.width + MenuBarArranger.itemSpacing
            let missing = cost - (free - pendingMainWidth)
            if missing > 0 {
                notes[key] = "Pas assez de place dans la barre principale, il manque \(Int(missing.rounded(.up))) pt."
                return
            }
        }
        settings.menuBarPlacements[key] = placement.rawValue
        guard placement.side != actual else { return }
        arrange(item, to: placement.side)
    }

    /// Puts every classified icon back in its zone.
    func arrangeAll() {
        for item in rows {
            guard let placement = placement(of: item), !busy.contains(item.placementKey) else { continue }
            if placement.side != actualSide(of: item) { arrange(item, to: placement.side) }
        }
    }

    private func arrange(_ item: MenuBarItem, to side: MenuBarArranger.Side) {
        let key = item.placementKey
        let cost = side == .main ? item.frame.width + MenuBarArranger.itemSpacing : 0
        let before: MenuBarPlacement = actualSide(of: item) == .hidden ? .hidden : .main
        busy.insert(key)
        pendingMainWidth += cost
        MenuBarArranger.move(item, to: side) { [weak self] outcome in
            guard let self else { return }
            self.busy.remove(key)
            self.pendingMainWidth -= cost
            self.lastArrangement = Date()
            if case .failed(let cause) = outcome {
                self.notes[key] = "Non déplacée : \(cause)."
                // The bar wins: the box goes back to where the icon is.
                self.settings.menuBarPlacements[key] = before.rawValue
            }
            self.refreshAfterArrangement()
        }
    }

    /// The moved icon changed zone: the visible bar is scanned, and the evicted cache
    /// read again if it is stale (the overflow opens for about 150 ms).
    private func refreshAfterArrangement() {
        guard busy.isEmpty else { return }
        inventory.refresh { [weak self] in
            guard let self, self.inventory.overflowIndicator != nil, self.inventory.cacheStale else { return }
            self.inventory.fullScan { _ in }
        }
    }

    /// First use: every icon is recorded where it is, silently. Then the bar wins: a
    /// classified icon found on the other side changes its box.
    private func syncWithBar() {
        // Without a notch nothing is hidden: the bar says nothing about the choices.
        guard settings.menuBarEnabled, busy.isEmpty, !MenuBarOverflow.heldOpen,
              MenuBarChevron.shared.freeSpace != nil,
              Date().timeIntervalSince(lastArrangement) > 5 else { return }
        // The hidden side is only known from a fresh full scan.
        let hiddenKnown = inventory.overflowIndicator == nil || (inventory.lastFullScan != nil && !inventory.cacheStale)
        var placements = settings.menuBarPlacements
        let firstUse = placements.isEmpty
        if firstUse && !hiddenKnown { return }
        for item in rows where !isFixed(item) {
            if item.zone == .hidden && !hiddenKnown { continue }
            let key = item.placementKey
            let actual: MenuBarPlacement = actualSide(of: item) == .hidden ? .hidden : .main
            // The icon got a sure table entry since it was classified: the choice follows.
            if key != item.legacyKey, placements[key] == nil, let old = placements.removeValue(forKey: item.legacyKey) {
                placements[key] = old
            }
            guard let chosen = placements[key].flatMap(MenuBarPlacement.init(rawValue:)) else {
                if firstUse { placements[key] = actual.rawValue }
                continue
            }
            if chosen.side != actual.side {
                Log.menuBar.info("classifier: \(key, privacy: .public) found in \(actual.rawValue, privacy: .public), box updated")
                placements[key] = actual.rawValue
            }
        }
        if placements != settings.menuBarPlacements { settings.menuBarPlacements = placements }
    }
}
