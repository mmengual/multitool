import AppKit

/// The chevron status item: a 24 pt button that opens and closes the band
/// (`MenuBarBand`). A ⌥-click opens macOS's own overflow (`MenuBarOverflow`).
///
/// Until 0.4.x its length filled the free space of the bar to push icons into macOS's
/// overflow, which left a wide empty gap. Since lot 6 icons are hidden through
/// macOS's per-app switches (`MenuBarVisibility`) and the chevron hides nothing.
@MainActor
final class MenuBarChevron: NSObject {
    static let shared = MenuBarChevron()

    nonisolated static let autosaveName = "MultitoolMenuBarChevron"
    nonisolated static let accessibilityLabel = "Icônes cachées de la barre des menus"
    nonisolated static let length: CGFloat = 24

    /// Where macOS stores the place of the item, read and rewritten around `stop()`.
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    /// Preferred position written when the chevron is born invisible. Measured on
    /// macOS 27.2 with test items: 260 places an item right of the third-party icons,
    /// just left of the system ones. The value is not a distance in points.
    nonisolated static let rescuePosition: Double = 260
    /// Delay between 2 checks that a new chevron is visible.
    private static let birthCheckDelay: TimeInterval = 1
    private static let maxBirthChecks = 10

    private var item: NSStatusItem?
    /// The chevron was recreated once at `rescuePosition` since `start()`.
    private var rescued = false
    private var birthChecks = 0
    private var invisibleBirthReads = 0

    private override init() { super.init() }

    /// Frame of the chevron on screen (Cocoa coordinates), nil when it isn't placed.
    var screenFrame: NSRect? {
        guard let window = item?.button?.window, window.screen != nil else { return nil }
        return window.frame
    }

    // MARK: Lifecycle

    /// Creates the item. Idempotent.
    func start() {
        guard item == nil else { return }
        rescued = false
        create()
    }

    private func create() {
        let item = NSStatusBar.system.statusItem(withLength: Self.length)
        // Right after the creation, so macOS restores the place chosen by the user.
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "Icônes cachées"
            button.setAccessibilityLabel(Self.accessibilityLabel)
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        self.item = item
        birthChecks = 0
        invisibleBirthReads = 0
        Log.menuBar.info("chevron created")
        scheduleBirthCheck()
    }

    /// Removes the item. Idempotent. Keeps the place chosen by the user.
    func stop() {
        guard let item else { return }
        // removeStatusItem forgets the place: save it and write it back. Never hide the
        // item with `isVisible = false`, macOS would remember it as removed.
        let defaults = UserDefaults.standard
        let savedPosition = defaults.object(forKey: Self.positionKey)
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        if let savedPosition { defaults.set(savedPosition, forKey: Self.positionKey) }
        MenuBarBand.shared.close()
        Log.menuBar.info("chevron removed")
    }

    // MARK: Born invisible

    private func scheduleBirthCheck() {
        let checked = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.birthCheckDelay) { [weak self] in
            MainActor.assumeIsolated { self?.checkBirth(of: checked) }
        }
    }

    /// A chevron created in a saturated bar is born in macOS's overflow, invisible:
    /// it is recreated once at `rescuePosition`, without restoring the old place.
    /// Waits for a placed window (a screen), and needs 2 invisible reads in a row: no
    /// screen yet, a hidden bar or a sleeping display don't count.
    private func checkBirth(of checked: NSStatusItem?) {
        // A stop then a start leaves the old chain running: it ends here.
        guard let item, item === checked, !rescued else { return }
        birthChecks += 1
        let window = item.button?.window
        let measurable = window?.screen != nil && Self.barShown && CGDisplayIsAsleep(CGMainDisplayID()) == 0
        guard measurable else {
            invisibleBirthReads = 0
            if birthChecks < Self.maxBirthChecks { scheduleBirthCheck() }
            return
        }
        guard window?.occlusionState.contains(.visible) == false else { return }
        invisibleBirthReads += 1
        if invisibleBirthReads < 2 {
            scheduleBirthCheck()
            return
        }
        rescued = true
        Log.menuBar.info("chevron born invisible: recreated at preferred position \(Self.rescuePosition)")
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        // Written before `autosaveName` is set again, so macOS reads it.
        UserDefaults.standard.set(Self.rescuePosition, forKey: Self.positionKey)
        create()
    }

    /// False while the menu bar is hidden (full screen, auto-hide) or the session locked.
    private static var barShown: Bool {
        guard NSMenu.menuBarVisible() else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) != true
    }

    // MARK: Click

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            Log.menuBar.info("chevron ⌥-clicked: native overflow")
            MenuBarOverflow.toggle { _ in }
        } else {
            Log.menuBar.info("chevron clicked: band")
            MenuBarBand.shared.toggle()
        }
    }

    // MARK: Layout restore (lot 4)

    /// Makes MenuBarAgent read its position table again: it only applies a write once
    /// a status item of the writing process is laid out again (measured on 23/11).
    /// False when the chevron isn't in the bar (module disabled).
    @discardableResult
    func forceLayoutRead() -> Bool {
        guard let item else { return false }
        item.length = Self.length + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.item?.length = Self.length }
        }
        return true
    }
}
