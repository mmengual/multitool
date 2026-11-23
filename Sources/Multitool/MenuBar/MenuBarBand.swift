import AppKit
import SwiftUI
import Combine

/// The band's panel: borderless, non-activating, key for Échap.
final class MenuBarBandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// What the band shows.
@MainActor
final class MenuBarBandModel: ObservableObject {
    enum Phase: Equatable { case list, empty, noAccess, reading, failed(String) }

    @Published var phase: Phase = .reading
    @Published var items: [MenuBarItem] = []
    /// Icon whose relay runs.
    @Published var pendingID: String?
    /// Icon whose relay failed, shown for a second.
    @Published var failedID: String?

    var onPick: (MenuBarItem) -> Void = { _ in }
}

/// The band drawn under the menu bar, right-aligned under the clock, with the icons
/// macOS evicted into its overflow. The chevron opens and closes it.
@MainActor
final class MenuBarBand: NSObject, NSWindowDelegate {
    static let shared = MenuBarBand()

    // Geometry, Orbe tokens.
    nonisolated static let cell: CGFloat = 28
    nonisolated static let spacing: CGFloat = Orbe.Space.s2
    nonisolated static let padding: CGFloat = Orbe.Space.s3
    /// Gap between the menu bar and the band.
    nonisolated static let gap: CGFloat = Orbe.Space.s2

    private var panel: MenuBarBandPanel?
    private let model = MenuBarBandModel()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private let inventory = MenuBarInventory.shared

    var isVisible: Bool { panel?.isVisible ?? false }

    private override init() {
        super.init()
        model.onPick = { [weak self] item in self?.pick(item) }
        inventory.$evicted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.syncItems() } }
            .store(in: &cancellables)
    }

    // MARK: Open and close

    func toggle() { isVisible ? close() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.pendingID = nil
        model.failedID = nil
        guard Permissions.accessibility else {
            model.phase = .noAccess
            present(panel)
            return
        }
        syncItems()
        if inventory.lastFullScan == nil { model.phase = .reading }
        present(panel)
        // A light scan first: it says whether anything is evicted and checks the cache.
        inventory.refresh { [weak self] in
            guard let self, self.isVisible else { return }
            guard self.inventory.overflowIndicator != nil, self.inventory.cacheStale else {
                self.syncItems()
                return
            }
            self.model.phase = .reading
            self.layout()
            self.inventory.fullScan { [weak self] cause in
                guard let self else { return }
                if let cause {
                    Log.menuBar.info("band: full scan failed: \(cause, privacy: .public)")
                    self.model.phase = .failed(cause)
                    self.layout()
                    return
                }
                self.syncItems()
            }
        }
        Log.menuBar.info("band opened")
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        panel.orderOut(nil)
        Log.menuBar.info("band closed")
    }

    private func present(_ panel: MenuBarBandPanel) {
        layout()
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    private func syncItems() {
        model.items = inventory.evicted
        if model.phase != .noAccess {
            if inventory.lastFullScan == nil && inventory.overflowIndicator != nil {
                model.phase = .reading
            } else {
                model.phase = model.items.isEmpty ? .empty : .list
            }
        }
        if isVisible { layout() }
    }

    // MARK: Panel

    private func makePanel() -> MenuBarBandPanel {
        let panel = MenuBarBandPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        let host = NSHostingView(rootView: MenuBarBandView(model: model))
        panel.contentView = host
        return panel
    }

    /// Sizes the panel to its content and pins its top right corner under the clock.
    private func layout() {
        guard let panel, let host = panel.contentView as? NSHostingView<MenuBarBandView>,
              let screen = NSScreen.screens.first else { return }
        let size: CGSize
        if model.phase == .list {
            size = Self.listSize(count: model.items.count)
        } else {
            size = host.fittingSize
        }
        // The clock is the rightmost system icon (its label depends on the language).
        let clockMaxX = inventory.items.filter(\.isSystem).map(\.frame.maxX).max()
        let frame = Self.frame(size: size, screenFrame: screen.frame,
                               barHeight: Self.barHeight(of: screen), rightEdge: clockMaxX)
        panel.setFrame(frame, display: true)
    }

    /// Pure. Width of the list for `count` icons.
    nonisolated static func listSize(count: Int) -> CGSize {
        let n = CGFloat(max(count, 1))
        return CGSize(width: padding * 2 + n * cell + (n - 1) * spacing, height: padding * 2 + cell)
    }

    /// Pure. Cocoa frame (bottom-left origin) of the band. `rightEdge` is the clock's
    /// right edge, nil to use the screen edge minus a margin.
    nonisolated static func frame(size: CGSize, screenFrame: CGRect, barHeight: CGFloat, rightEdge: CGFloat?) -> CGRect {
        let right = min(rightEdge ?? (screenFrame.maxX - Orbe.Space.s3), screenFrame.maxX - Orbe.Space.s2)
        let top = screenFrame.maxY - barHeight - gap
        return CGRect(x: max(screenFrame.minX + Orbe.Space.s3, right - size.width), y: top - size.height,
                      width: size.width, height: size.height)
    }

    /// Height of the menu bar. 0 from `visibleFrame` when the bar hides itself, so the
    /// max with the bar thickness and the notch inset.
    static func barHeight(of screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness, screen.safeAreaInsets.top)
    }

    /// Screen rect (bottom-left origin) of the cell at `index`, for anchoring a menu.
    private func cellRect(index: Int) -> CGRect? {
        guard let panel else { return nil }
        let x = panel.frame.minX + Self.padding + CGFloat(index) * (Self.cell + Self.spacing)
        return CGRect(x: x, y: panel.frame.minY + Self.padding, width: Self.cell, height: Self.cell)
    }

    // MARK: Closing triggers

    private func installMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        // Clicks in other apps. The chevron's own click is local: it toggles.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.pendingID == nil else { return }
                self.close()
            }
        }) { monitors.append(global) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 53 else { return event }
            self.close()
            return nil
        }) { monitors.append(keys) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    // MARK: Relay

    private func pick(_ item: MenuBarItem) {
        guard model.pendingID == nil else { return }
        let index = model.items.firstIndex { $0.id == item.id } ?? 0
        let anchor = cellRect(index: index)

        // Our own icon: no AX request to our own process, the popover opens here.
        if item.pid == ProcessInfo.processInfo.processIdentifier {
            close()
            if let anchor { (NSApp.delegate as? AppDelegate)?.showPopover(anchoredAt: anchor) }
            return
        }

        model.pendingID = item.id
        MenuBarRelay.relay(item) { [weak self] outcome in
            guard let self else { return }
            self.model.pendingID = nil
            switch outcome {
            case .menu(let entries):
                self.close()
                self.popUp(entries, at: anchor)
            case .dispatched:
                self.close()
            case .busy:
                // A native menu is still open: not a failure of this icon.
                Log.menuBar.info("band: relay of \(item.id, privacy: .public) refused, another relay runs")
            case .failed(let cause):
                Log.menuBar.info("band: relay of \(item.id, privacy: .public) failed: \(cause, privacy: .public)")
                self.model.failedID = item.id
                // The cache may be wrong: the next opening reads the overflow again.
                self.inventory.markStale("relay failed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.model.failedID == item.id { self?.model.failedID = nil }
                    }
                }
            }
        }
    }

    /// Shows the redrawn menu under the cell. Each entry presses the element it was read from.
    private func popUp(_ entries: [MenuBarRelay.Entry], at anchor: CGRect?) {
        let menu = Self.makeMenu(entries)
        let point = anchor.map { NSPoint(x: $0.minX, y: $0.minY - Self.padding - Self.gap) } ?? NSEvent.mouseLocation
        // `popUp` tracks the menu until it closes. Run from the run loop, not from a
        // main queue block: the main queue stays free for the other main-actor work.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { _ = menu.popUp(positioning: nil, at: point, in: nil) }
        }
    }

    private static func makeMenu(_ entries: [MenuBarRelay.Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            if entry.submenu.isEmpty {
                item.target = RelayMenuTarget.shared
                item.action = #selector(RelayMenuTarget.pressed(_:))
                item.representedObject = EntryBox(entry)
            } else {
                item.submenu = makeMenu(entry.submenu)
            }
            menu.addItem(item)
        }
        return menu
    }
}

/// Holds an entry in `NSMenuItem.representedObject`.
private final class EntryBox: NSObject {
    let entry: MenuBarRelay.Entry
    init(_ entry: MenuBarRelay.Entry) { self.entry = entry }
}

/// Target of the redrawn menu entries.
@MainActor
private final class RelayMenuTarget: NSObject {
    static let shared = RelayMenuTarget()

    @objc func pressed(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? EntryBox else { return }
        MenuBarRelay.press(box.entry)
    }
}
