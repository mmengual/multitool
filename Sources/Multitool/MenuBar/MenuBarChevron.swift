import AppKit

/// The chevron status item that splits the menu bar in 2. Its length fills the free
/// space left of it, so macOS evicts the icons on its left into its own overflow.
/// A click opens or closes that native overflow (`MenuBarOverflow`).
///
/// The user places it with a ⌘-drag, macOS keeps the place under `autosaveName`.
@MainActor
final class MenuBarChevron: NSObject {
    static let shared = MenuBarChevron()

    nonisolated static let autosaveName = "MultitoolMenuBarChevron"
    /// Folded length: the glyph alone.
    nonisolated static let glyphLength: CGFloat = 24
    /// Room left for the native overflow indicator, right of the notch.
    // Measured on macOS 27.2.1: the indicator ends 42.5 pt right of the notch edge.
    nonisolated static let reserve: CGFloat = 48

    /// Where macOS stores the place of the item, read and rewritten around `stop()`.
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    /// Notifications are grouped over this delay (a ⌘-drag posts many moves).
    private static let debounce: TimeInterval = 0.3
    /// Below this change, a recalculation writes nothing.
    private static let minimumChange: CGFloat = 1
    /// After an eviction, the next length is capped at the evicted length minus this.
    private static let evictionStep: CGFloat = 20
    /// Capped attempts after an eviction, then the chevron stays at the glyph length.
    private static let maxEvictionRetries = 3

    private var item: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    /// Eviction state, reset when the screens or the setting change.
    private var evictionCap: CGFloat?
    private var evictions = 0
    private var screenKey = ""

    private override init() { super.init() }

    /// Window of the chevron, to keep it out of the inventory.
    var windowNumber: Int? { item?.button?.window?.windowNumber }

    // MARK: Lifecycle

    /// Creates the item, sets its length and watches its moves. Idempotent.
    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: Self.glyphLength)
        // Right after the creation, so macOS restores the place chosen by the user.
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Icônes cachées"
            button.setAccessibilityLabel("Icônes cachées de la barre des menus")
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        self.item = item
        resetEvictions()
        screenKey = Self.screenConfigurationKey()
        drawGlyph(length: Self.glyphLength)
        observe()
        Log.menuBar.info("chevron created")

        // The status item needs a run loop pass to get its place in the menu bar.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.item != nil else { return }
                guard self.item?.button?.window?.screen != nil else {
                    Log.menuBar.info("chevron not placed yet: waiting for a move notification")
                    return
                }
                self.recalculate(reason: "start")
            }
        }
    }

    /// Removes the item and the observers. Idempotent. Keeps the place chosen by the user.
    func stop() {
        guard let item else { return }
        pending?.cancel()
        pending = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []

        // removeStatusItem forgets the place: save it and write it back. Never hide the
        // item with `isVisible = false`, macOS would remember it as removed.
        let defaults = UserDefaults.standard
        let savedPosition = defaults.object(forKey: Self.positionKey)
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        if let savedPosition { defaults.set(savedPosition, forKey: Self.positionKey) }
        resetEvictions()
        Log.menuBar.info("chevron removed")
    }

    // MARK: Click

    @objc private func clicked(_ sender: NSStatusBarButton) {
        Log.menuBar.info("chevron clicked")
        MenuBarOverflow.toggle { accepted in
            Log.menuBar.info("chevron click result: \(accepted ? "accepted" : "refused", privacy: .public)")
        }
    }

    // MARK: Length

    /// Pure, no AppKit: also used by `--menubar-dump`. `leftLimit` nil (no notch) gives
    /// the glyph length. Never below the glyph length.
    nonisolated static func targetLength(chevronMaxX: CGFloat, leftLimit: CGFloat?,
                                         reserve: CGFloat, glyph: CGFloat) -> CGFloat {
        guard let leftLimit else { return glyph }
        return max(glyph, (chevronMaxX - leftLimit - reserve).rounded(.down))
    }

    /// Right edge of the notch on `screen`, nil without a notch. The reference of
    /// `auxiliaryTopRightArea.minX` is not documented, its width is relative to the screen.
    nonisolated static func leftLimit(of screen: NSScreen) -> CGFloat? {
        guard let area = screen.auxiliaryTopRightArea else { return nil }
        return screen.frame.maxX - area.width
    }

    private func recalculate(reason: String) {
        guard let item else { return }
        let key = Self.screenConfigurationKey()
        if key != screenKey {
            screenKey = key
            if evictions > 0 { Log.menuBar.info("screens changed: eviction count reset") }
            resetEvictions()
        }

        let current = item.length
        let window = item.button?.window
        // A glyph-length chevron can't be evicted for being too wide: no screen there
        // only means it isn't placed yet.
        if current > Self.glyphLength + Self.minimumChange, let sign = Self.evictionSign(window) {
            evictions += 1
            if evictions > Self.maxEvictionRetries {
                Log.menuBar.info("chevron evicted \(self.evictions) times (\(sign, privacy: .public)): back to the glyph length until the screens or the setting change")
                setLength(Self.glyphLength)
                return
            }
            let cap = max(Self.glyphLength, current - Self.evictionStep)
            evictionCap = cap
            Log.menuBar.info("chevron evicted at \(Double(current)) pt (\(sign, privacy: .public)), attempt \(self.evictions): length capped at \(Double(cap)) pt")
            setLength(cap)
            scheduleRecalculation(reason: "eviction check")
            return
        }

        guard let window, let screen = window.screen else {
            Log.menuBar.info("chevron has no screen (\(reason, privacy: .public)): length unchanged")
            return
        }
        let chevronMaxX = window.frame.maxX
        let leftLimit = Self.leftLimit(of: screen)
        var target = Self.targetLength(chevronMaxX: chevronMaxX, leftLimit: leftLimit,
                                       reserve: Self.reserve, glyph: Self.glyphLength)
        if leftLimit == nil {
            Log.menuBar.info("screen without a notch: no hiding, glyph length")
        }
        if evictions > Self.maxEvictionRetries {
            target = Self.glyphLength
        } else if let evictionCap {
            target = min(target, evictionCap)
        }
        guard abs(target - current) > Self.minimumChange else { return }

        let limit = leftLimit.map { String(format: "%.1f", Double($0)) } ?? "nil"
        Log.menuBar.info("chevron length \(Double(target)) pt (\(reason, privacy: .public)): maxX \(Double(chevronMaxX)), leftLimit \(limit, privacy: .public), reserve \(Double(Self.reserve))")
        setLength(target)
        // Eviction isn't signalled: look again once macOS has laid the bar out.
        scheduleRecalculation(reason: "after length change")
    }

    private func setLength(_ length: CGFloat) {
        guard let item else { return }
        item.length = length
        drawGlyph(length: length)
    }

    private func resetEvictions() {
        evictions = 0
        evictionCap = nil
    }

    /// Why the chevron looks evicted, nil if it looks in place. macOS 27 gives no proven
    /// signal: these guesses are logged at each notification to be checked on screen.
    private static func evictionSign(_ window: NSWindow?) -> String? {
        guard let window else { return "no window" }
        guard let screen = window.screen else { return "no screen" }
        if !window.occlusionState.contains(.visible) { return "not visible" }
        if !screen.frame.insetBy(dx: -1, dy: -1).contains(window.frame) { return "frame off screen" }
        return nil
    }

    /// Identity of the screen setup: when it changes, the eviction count starts over.
    private static func screenConfigurationKey() -> String {
        NSScreen.screens.map { screen in
            "\(screen.frame)|\(screen.auxiliaryTopRightArea.map { "\($0)" } ?? "-")"
        }.joined(separator: ";")
    }

    // MARK: Glyph

    /// The glyph is drawn at the right edge of an image as wide as the item, so the
    /// whole item stays clickable and the glyph sits next to the visible icons.
    private func drawGlyph(length: CGFloat) {
        guard let button = item?.button else { return }
        let symbol = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        let size = NSSize(width: length, height: NSStatusBar.system.thickness)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let symbol else { return false }
            let glyph = symbol.size
            let inset = max(0, (MenuBarChevron.glyphLength - glyph.width) / 2)
            let origin = NSPoint(x: rect.maxX - inset - glyph.width, y: (rect.height - glyph.height) / 2)
            symbol.draw(in: NSRect(origin: origin, size: glyph))
            return true
        }
        image.isTemplate = true
        button.image = image
    }

    // MARK: Observation

    private func observe() {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let object = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated { self?.windowChanged(name, object: object) }
            })
        }
        let screens = NSApplication.didChangeScreenParametersNotification
        observers.append(center.addObserver(forName: screens, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.menuBar.info("screen parameters changed")
                self?.scheduleRecalculation(reason: "screen parameters")
            }
        })
    }

    private func windowChanged(_ name: Notification.Name, object: ObjectIdentifier?) {
        guard let window = item?.button?.window, object == ObjectIdentifier(window) else { return }
        let screen = window.screen.map { "\($0.frame)" } ?? "nil"
        Log.menuBar.info("chevron \(name.rawValue, privacy: .public): frame \(String(describing: window.frame), privacy: .public), screen \(screen, privacy: .public), occlusionState \(window.occlusionState.rawValue) (visible \(window.occlusionState.contains(.visible)))")
        scheduleRecalculation(reason: name.rawValue)
    }

    private func scheduleRecalculation(reason: String) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.recalculate(reason: reason)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}
