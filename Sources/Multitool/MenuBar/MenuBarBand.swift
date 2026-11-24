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
    enum Phase: Equatable { case list, empty, unavailable }

    @Published var phase: Phase = .empty
    @Published var apps: [MenuBarApp] = []
    var onPick: (MenuBarApp) -> Void = { _ in }
}

/// The band drawn under the menu bar, under the chevron: the apps whose icon is
/// switched off in the bar and classified « Barre cachée », by their application's
/// icon. A click switches the icon back on and clicks it (`MenuBarVisibility.relay`).
@MainActor
final class MenuBarBand: NSObject {
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
    private let visibility = MenuBarVisibility.shared

    var isVisible: Bool { panel?.isVisible ?? false }

    private override init() {
        super.init()
        model.onPick = { [weak self] app in self?.pick(app) }
    }

    // MARK: Open and close

    func toggle() { isVisible ? close() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.apps = visibility.bandApps
        if visibility.loaded && visibility.switches == nil {
            model.phase = .unavailable
        } else {
            model.phase = model.apps.isEmpty ? .empty : .list
        }
        layout()
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        Log.menuBar.info("band opened: \(self.model.apps.count) apps")
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
        panel.contentView = NSHostingView(rootView: MenuBarBandView(model: model))
        return panel
    }

    /// Sizes the panel to its content and puts it under the menu bar, its right edge
    /// under the chevron's.
    private func layout() {
        guard let panel, let host = panel.contentView as? NSHostingView<MenuBarBandView>,
              let screen = NSScreen.screens.first else { return }
        let size = model.phase == .list ? Self.listSize(count: model.apps.count) : host.fittingSize
        let frame = Self.frame(size: size, screenFrame: screen.frame, barHeight: Self.barHeight(of: screen),
                               rightEdge: MenuBarChevron.shared.screenFrame?.maxX)
        panel.setFrame(frame, display: true)
    }

    /// Pure. Size of the list for `count` icons.
    nonisolated static func listSize(count: Int) -> CGSize {
        let n = CGFloat(max(count, 1))
        return CGSize(width: padding * 2 + n * cell + (n - 1) * spacing, height: padding * 2 + cell)
    }

    /// Pure. Cocoa frame (bottom-left origin) of the band. `rightEdge` nil: the screen
    /// edge minus a margin. The band never leaves the screen.
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

    // MARK: Closing triggers

    private func installMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        // Clicks in other apps. The chevron's own click is local: it toggles.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
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

    /// The band closes first: the icon comes back in the bar and its menu or window
    /// opens under it. A failure beeps and is logged.
    private func pick(_ app: MenuBarApp) {
        close()
        visibility.relay(app.bundleID) { outcome in
            if case .failed(let cause) = outcome {
                Log.menuBar.info("band: relay of \(app.bundleID, privacy: .public) failed: \(cause, privacy: .public)")
                NSSound.beep()
            }
        }
    }
}
