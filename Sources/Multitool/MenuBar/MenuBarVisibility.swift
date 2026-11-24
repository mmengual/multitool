import AppKit
import ApplicationServices
import Combine

/// Zone chosen for an app's menu bar icon. No choice: the icon stays in the bar.
enum MenuBarPlacement: String {
    /// Switched off in the bar, shown in the band.
    case hidden
    /// Switched off in the bar, absent from the band.
    case masked
}

/// macOS 27's per-app menu bar switches (System Settings > Menu Bar), through the
/// `MultitoolVisibility` tool of the bundle. Switching an app off removes its icons
/// from the bar and the bar closes the gap (measured on 24/11: gone in 0.7 to 0.9 s,
/// back in 0.1 s, MenuBarAgent not restarted). Synchronous: call off the main thread.
enum MenuBarVisibilityStore {
    private static var toolURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "MultitoolVisibility") }

    /// bundle ID → allowed in the bar. nil: the tool is missing or macOS refuses it
    /// (a build without a Developer ID signature).
    static func list() -> [String: Bool]? { run(["list"]) }

    /// Applies `changes` in one read-modify-write. Returns the switches read back.
    static func set(_ changes: [String: Bool]) -> [String: Bool]? {
        guard !changes.isEmpty else { return list() }
        return run(["set"] + changes.map { "\($0.key)=\($0.value ? "on" : "off")" })
    }

    private static func run(_ arguments: [String]) -> [String: Bool]? {
        guard let toolURL else { return nil }
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.menuBar.info("visibility tool not launched: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // The tool answers in a few milliseconds: a hung one must not freeze the queue.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let apps = object["apps"] as? [String: Bool] else {
            Log.menuBar.info("visibility tool failed: status \(process.terminationStatus)")
            return nil
        }
        if object["othersChanged"] as? Bool == true {
            Log.menuBar.info("visibility: macOS rewrote other entries during our write")
        }
        return apps
    }
}

/// One line of the settings page, one cell of the band: an app that has a menu bar icon.
struct MenuBarApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let running: Bool
    var id: String { bundleID }
}

/// Applies the choices of the settings page to macOS's switches, and relays a click of
/// the band to an icon that is switched off.
///
/// The journal (`Settings.menuBarSwitchedOff`) lists the apps Multitool itself switched
/// off: it never switches on an app the user switched off in System Settings. Multitool
/// leaves the icons off when it quits, so they don't blink at each login and update:
/// they come back when a box is unchecked or the module is disabled.
@MainActor
final class MenuBarVisibility: ObservableObject {
    static let shared = MenuBarVisibility()

    /// The switches at the last read. nil: hiding is unavailable in this build.
    @Published private(set) var switches: [String: Bool]?
    /// The first read is done.
    @Published private(set) var loaded = false
    /// Apps whose icon is on for a relayed click.
    @Published private(set) var relaying: Set<String> = []
    /// Message under a row of the settings page.
    @Published private(set) var notes: [String: String] = [:]

    /// Every switch change and every relay step, in order: no switch-off between the
    /// switch-on and the click of a relay.
    private static let queue = DispatchQueue(label: "com.mmengual.multitool.menubar.visibility", qos: .userInitiated)

    private let settings = Settings.shared
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.mmengual.multitool"
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var lastWrite = Date.distantPast
    /// Switches read by the settings page while it watches, for `refreshFromBar`.
    private var watched: [String: Bool]?

    private init() {}

    /// Starts following the settings and the app launches. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        migratePlacements()
        settings.$menuBarEnabled.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier,
                      MainActor.assumeIsolated({ self?.placement(of: bundleID) }) != nil else { return }
                // macOS creates the app's entry when its icon appears, sooner or later.
                for delay in [2.0, 5, 10] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self?.apply() } }
                }
            }
            .store(in: &cancellables)
        apply()
    }

    // MARK: Choices

    func placement(of bundleID: String) -> MenuBarPlacement? {
        settings.menuBarPlacements[bundleID].flatMap(MenuBarPlacement.init(rawValue:))
    }

    /// Why an app has no boxes, nil when it can be classified.
    func unclassifiableReason(_ bundleID: String) -> String? {
        if bundleID == ownBundleID { return "Multitool reste dans la barre : son chevron ouvre la bande." }
        if MenuBarInventory.systemBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.apple.") {
            return "Icône du système : elle se règle dans Réglages Système > Barre des menus."
        }
        guard let switches else { return "Masquage indisponible dans cette version." }
        // A classified app keeps its boxes even if macOS dropped its entry: it can be unchecked.
        if switches[bundleID] == nil && placement(of: bundleID) == nil {
            return "macOS ne propose pas d'interrupteur pour cette app."
        }
        return nil
    }

    func set(_ placement: MenuBarPlacement?, for bundleID: String) {
        notes[bundleID] = nil
        settings.menuBarPlacements[bundleID] = placement?.rawValue
        apply()
    }

    /// Apps of the band: classified hidden and running.
    var bandApps: [MenuBarApp] {
        settings.menuBarPlacements.keys.sorted().compactMap { bundleID in
            guard placement(of: bundleID) == .hidden, bundleID != ownBundleID,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
            return MenuBarApp(bundleID: bundleID, name: app.localizedName ?? bundleID, running: true)
        }
    }

    /// Choices of 0.4.x were keyed by an entry of macOS's position table
    /// ("status:<bundleID>::…") or by "app:<bundleID>#<index>", with "main" as a value.
    /// macOS's switch is per app: the most hidden choice of an app wins. Choices on
    /// system modules and on owners named by a process name are dropped.
    private func migratePlacements() {
        let old = settings.menuBarPlacements
        guard old.keys.contains(where: { $0.contains(":") }) || old.values.contains("main") else { return }
        var migrated: [String: String] = [:]
        for (key, value) in old {
            guard let placement = MenuBarPlacement(rawValue: value) else { continue }
            var bundleID = key
            if key.hasPrefix("status:"), let end = key.range(of: "::") {
                bundleID = String(key[key.index(key.startIndex, offsetBy: 7)..<end.lowerBound])
            } else if key.hasPrefix("app:"), let end = key.lastIndex(of: "#") {
                bundleID = String(key[key.index(key.startIndex, offsetBy: 4)..<end])
            } else if key.contains(":") {
                continue
            }
            guard bundleID.contains("."), !bundleID.hasPrefix("com.apple."), bundleID != ownBundleID else { continue }
            if migrated[bundleID] != MenuBarPlacement.masked.rawValue { migrated[bundleID] = placement.rawValue }
        }
        Log.menuBar.info("placements migrated from 0.4.x: \(old.count) choices, \(migrated.count) apps")
        settings.menuBarPlacements = migrated
    }

    // MARK: Applying the choices

    /// Reads the switches and brings them in line with the choices. Safe to call often.
    func apply() {
        Self.queue.async {
            // Read when the block runs, not when it was queued: an earlier block may
            // have changed the journal meanwhile.
            var wantedOff: Set<String> = [], journal: Set<String> = [], held: Set<String> = []
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    if self.settings.menuBarEnabled {
                        wantedOff = Set(self.settings.menuBarPlacements.keys
                            .filter { $0 != self.ownBundleID && !$0.hasPrefix("com.apple.") })
                    }
                    journal = Set(self.settings.menuBarSwitchedOff)
                    held = self.relaying
                }
            }
            guard let current = MenuBarVisibilityStore.list() else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.switches = nil; self.loaded = true } }
                return
            }
            var changes: [String: Bool] = [:]
            var newJournal = journal
            for bundleID in wantedOff where current[bundleID] == true && !held.contains(bundleID) {
                changes[bundleID] = false
                newJournal.insert(bundleID)
            }
            // Only what Multitool switched off is switched back on.
            for bundleID in journal where !wantedOff.contains(bundleID) && !held.contains(bundleID) {
                if current[bundleID] == false { changes[bundleID] = true }
            }
            // The journal is on disk before anything is switched off.
            let added = newJournal.subtracting(journal)
            if !added.isEmpty {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self.writeJournal(Set(self.settings.menuBarSwitchedOff).union(added)) }
                }
            }
            let after = changes.isEmpty ? current : (MenuBarVisibilityStore.set(changes) ?? current)
            // An app leaves the journal once its entry reads on again.
            let finished = newJournal.filter { !wantedOff.contains($0) && after[$0] == true }
            if !changes.isEmpty {
                Log.menuBar.info("visibility: \(changes.map { "\($0.key)=\($0.value ? "on" : "off")" }.sorted().joined(separator: " "), privacy: .public)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !changes.isEmpty { self.lastWrite = Date(); self.watched = nil }
                    if !finished.isEmpty { self.writeJournal(Set(self.settings.menuBarSwitchedOff).subtracting(finished)) }
                    for (bundleID, allowed) in changes where after[bundleID] != allowed {
                        self.notes[bundleID] = "macOS n'a pas appliqué le changement."
                    }
                    self.switches = after
                    self.loaded = true
                }
            }
        }
    }

    private func writeJournal(_ journal: Set<String>) {
        settings.menuBarSwitchedOff = journal.sorted()
        UserDefaults.standard.synchronize()
    }

    /// The bar wins, narrowly: an app Multitool keeps off is found on while the
    /// settings page watches, outside a relay and well after our last write. The user
    /// switched it on in System Settings: its box is unchecked. Never at launch.
    func refreshFromBar() {
        guard settings.menuBarEnabled, loaded, relaying.isEmpty, Date().timeIntervalSince(lastWrite) > 5 else {
            watched = nil
            return
        }
        Self.queue.async {
            guard let now = MenuBarVisibilityStore.list() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.relaying.isEmpty, Date().timeIntervalSince(self.lastWrite) > 5 else { return }
                    // Compared with the previous read of this watch, seconds ago: an
                    // old read would blame the user for what macOS did hours earlier.
                    defer { self.watched = now; self.switches = now }
                    guard let before = self.watched else { return }
                    let journal = Set(self.settings.menuBarSwitchedOff)
                    for bundleID in journal where before[bundleID] == false && now[bundleID] == true
                        && self.placement(of: bundleID) != nil {
                        Log.menuBar.info("visibility: \(bundleID, privacy: .public) switched on outside Multitool, box unchecked")
                        self.settings.menuBarPlacements[bundleID] = nil
                        self.writeJournal(Set(self.settings.menuBarSwitchedOff).subtracting([bundleID]))
                    }
                }
            }
        }
    }

    // MARK: Relayed click

    enum RelayOutcome: Equatable { case clicked, failed(String) }

    /// Time given to the icon to be drawn after the switch-on (measured: 0.1 s).
    private nonisolated static let drawTimeout: TimeInterval = 1.5
    /// The icon stays on at least this long after the click.
    private nonisolated static let minimumShown: TimeInterval = 1.5

    /// Switches the app's icon on, clicks it where it really is, and switches it off
    /// again once the menu or popover it opened is gone. `completion` runs on the main
    /// thread once the click is posted, or the relay failed.
    func relay(_ bundleID: String, completion: @escaping @MainActor (RelayOutcome) -> Void) {
        guard !relaying.contains(bundleID) else { completion(.failed("déjà en cours")); return }
        guard Permissions.accessibility else { completion(.failed("Accessibilité absente")); return }
        relaying.insert(bundleID)
        Self.queue.async {
            let start = DispatchTime.now()
            func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) }
            func finish(_ outcome: RelayOutcome) {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
            }
            guard MenuBarVisibilityStore.set([bundleID: true])?[bundleID] == true else {
                self.endRelay(bundleID)
                return finish(.failed("interrupteur refusé"))
            }
            guard let target = Self.waitDrawn(bundleID) else {
                Log.menuBar.info("relay \(bundleID, privacy: .public): icon not drawn after \(elapsed()) ms")
                self.endRelay(bundleID)
                return finish(.failed("icône non dessinée"))
            }
            Log.menuBar.info("relay \(bundleID, privacy: .public): icon drawn in \(elapsed()) ms at x \(Int(target.point.x))")
            let before = Self.overlayWindows(pid: target.pid)
            Self.click(at: target.point)
            finish(.clicked)
            // Off the serial queue: other relays and choices go on meanwhile.
            DispatchQueue.global(qos: .utility).async {
                Thread.sleep(forTimeInterval: Self.minimumShown)
                // A menu or a popover the click opened: a window of the app above the
                // normal level that wasn't there before. No time limit while it shows.
                // An app that keeps a floating panel forever must not hold the relay: 10 min.
                let limit = Date().addingTimeInterval(600)
                while Date() < limit, !Self.overlayWindows(pid: target.pid).subtracting(before).isEmpty {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                Log.menuBar.info("relay \(bundleID, privacy: .public): hidden again after \(elapsed()) ms")
                self.endRelay(bundleID)
            }
        }
    }

    /// Ends a relay and lets `apply()` switch the icon off again if it is still wanted off.
    private nonisolated func endRelay(_ bundleID: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.relaying.remove(bundleID)
                self.apply()
            }
        }
    }

    /// Center of the app's first icon once the bar really draws it: the element under
    /// that point belongs to the app and is a menu bar item. The app's own frame alone
    /// proves nothing, it stays readable while the icon is off. Read again at each try.
    private nonisolated static func waitDrawn(_ bundleID: String) -> (point: CGPoint, pid: pid_t)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        let deadline = Date().addingTimeInterval(drawTimeout)
        repeat {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let pid = app.processIdentifier
                guard let frame = MenuBarInventory.barChildren(pid: pid).first.flatMap(MenuBarInventory.frame) else { continue }
                let point = CGPoint(x: frame.midX, y: frame.midY)
                var element: AXUIElement?
                var owner: pid_t = 0
                if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
                   let element, AXUIElementGetPid(element, &owner) == .success, owner == pid,
                   MenuBarInventory.string(element, kAXRoleAttribute) == "AXMenuBarItem" {
                    return (point, pid)
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return nil
    }

    /// On-screen windows of `pid` above the normal level: menus, popovers.
    private nonisolated static func overlayWindows(pid: pid_t) -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  (window[kCGWindowLayer as String] as? Int ?? 0) > 0 else { return nil }
            return window[kCGWindowNumber as String] as? Int
        })
    }

    /// Down and up at `point` (global, top-left origin), no modifier, cursor put back.
    private nonisolated static func click(at point: CGPoint) {
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
