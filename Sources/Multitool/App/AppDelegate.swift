import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: EventTap?
    private var windowMover: WindowMover?
    private let popover = NSPopover()
    private var popoverMonitor: Any?
    /// Invisible window the popover hangs from when our icon is evicted and the band shows it.
    private var popoverAnchor: NSWindow?
    private var permissionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Orbe, theme `sombre`: every window, popover and alert is dark.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.make(target: self)
        HangWatchdog.start()
        setUpStatusItem()

        KeyboardSwap.shared.start()
        GameDetector.shared.start()
        ClipboardModule.shared.start()
        HelperClient.shared.refresh()
        UpdateController.shared.start()

        bindModules()
        startInputModules()
        handleDevArguments()
    }

    // MARK: - Accessibility

    /// The chatter filter and Window Mover need the Accessibility permission. Without
    /// it, macOS shows its own prompt (and lists Multitool in the settings), and
    /// we retry every 2 s: the modules start as soon as the permission is granted,
    /// without relaunching. The clipboard history works in the meantime.
    private func startInputModules() {
        if eventTap == nil {
            let tap = EventTap()
            if tap.start() { eventTap = tap }
        }
        if windowMover == nil {
            let mover = WindowMover()
            if mover.start() { windowMover = mover }
        }

        let ready = eventTap != nil && windowMover != nil
        if ready {
            permissionTimer?.invalidate()
            permissionTimer = nil
            applyChatterState()
            applyWindowMoverState()
            Log.app.info("input modules started")
        } else if permissionTimer == nil {
            Log.app.info("accessibility missing: prompting and waiting")
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard AXIsProcessTrusted() else { return }
                    self?.startInputModules()
                }
            }
        }
    }

    /// Development shortcuts: `--settings <pane>` opens the settings window
    /// on a pane, `--clipboard` opens the history panel, `--popover` the menu bar popover,
    /// `--update-in-background` checks for an update and installs it on quit.
    private func handleDevArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--settings") {
            let pane = args.indices.contains(i + 1) ? SettingsPane(rawValue: args[i + 1]) : nil
            openSettings(pane)
        }
        if args.contains("--clipboard") { ClipboardPanelController.shared.show() }
        if args.contains("--monitor") { MonitorWindowController.shared.show() }
        // `--stress-resize`: resizes the frontmost window 10 times a second for 30 s,
        // to reproduce layout freezes.
        if args.contains("--stress-resize") {
            var step = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                step += 1
                guard step < 300, let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal })
                else { timer.invalidate(); return }
                var frame = window.frame
                frame.size.width = 860 + CGFloat((step * 37) % 500)
                frame.size.height = 580 + CGFloat((step * 23) % 300)
                window.setFrame(frame, display: true)
            }
        }
        // `--snapshot <file.png>`: after 12 s, draws the frontmost window into a PNG
        // (no Screen Recording permission needed, it is our own window).
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                guard let view = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal })?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        if args.contains("--update-in-background") { UpdateController.shared.checkInBackground() }
        if args.contains("--popover") {
            // The status item needs a run loop pass to get its place in the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let button = self?.statusItem.button { self?.showPopover(from: button) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardModule.shared.stop()
    }

    // MARK: - Modules

    private func bindModules() {
        let settings = Settings.shared

        ChatterDetector.shared.$totalDropped
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.statusItem.button?.title = count > 0 ? " \(count)" : "" }
            .store(in: &cancellables)

        settings.$monitorEnabled
            .receive(on: DispatchQueue.main)
            .sink { enabled in ResourceMonitor.shared.setBackgroundEnabled(enabled) }
            .store(in: &cancellables)

        // An anomaly tints the menu bar icon, without any notification.
        ResourceMonitor.shared.$anomalies
            .combineLatest(settings.$monitorEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] anomalies, enabled in
                let flagged = enabled && anomalies.contains { $0.severity != .info }
                self?.statusItem.button?.contentTintColor = flagged ? NSColor(Orbe.alerte) : nil
                self?.statusItem.button?.toolTip = flagged ? anomalies.first?.title : "Multitool"
            }
            .store(in: &cancellables)

        settings.$enabled
            .combineLatest(settings.$pauseInGame, GameDetector.shared.$inGame)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in DispatchQueue.main.async { self?.applyChatterState() } }
            .store(in: &cancellables)

        settings.$windowMoverEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyWindowMoverState() } }
            .store(in: &cancellables)

        // The chevron doesn't need the Accessibility permission, only its click does.
        settings.$menuBarEnabled
            .receive(on: DispatchQueue.main)
            .sink { enabled in enabled ? MenuBarChevron.shared.start() : MenuBarChevron.shared.stop() }
            .store(in: &cancellables)
    }

    // Published values are read after the change lands (hence the async hop above).

    private func applyChatterState() {
        let s = Settings.shared
        let inGame = GameDetector.shared.inGame
        let active = s.enabled && !(s.pauseInGame && inGame)
        Log.app.info("chatter filter enabled=\(s.enabled) pauseInGame=\(s.pauseInGame) inGame=\(inGame) -> active=\(active)")
        active ? eventTap?.enable() : eventTap?.disable()
    }

    private func applyWindowMoverState() {
        Settings.shared.windowMoverEnabled ? windowMover?.enable() : windowMover?.disable()
    }

    // MARK: - Status item and popover

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        MenuBarInventory.ownStatusItem = statusItem
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wrench.and.screwdriver",
                                   accessibilityDescription: "Multitool")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PopoverView { [weak self] pane in
            self?.openSettings(pane)
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        popover.isShown ? closePopover() : showPopover(from: sender)
    }

    /// Our icon is evicted and was clicked in the band: the popover opens under the
    /// band's cell (`rect` in screen coordinates), not under the hidden button.
    func showPopover(anchoredAt rect: NSRect) {
        closePopover()
        let anchor = popoverAnchor ?? NSWindow(contentRect: rect, styleMask: [.borderless],
                                                backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.backgroundColor = .clear
        anchor.isOpaque = false
        anchor.ignoresMouseEvents = true
        anchor.level = .statusBar
        anchor.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        anchor.setFrame(rect, display: false)
        anchor.orderFront(nil)
        popoverAnchor = anchor
        guard let view = anchor.contentView else { return }
        presentPopover(relativeTo: view.bounds, of: view)
    }

    private func showPopover(from button: NSStatusBarButton) {
        presentPopover(relativeTo: button.bounds, of: button)
    }

    private func presentPopover(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
        // An .accessory app doesn't take focus on its own: bring it forward
        // so the SwiftUI controls get their events.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        // No focus ring on the first control: the popover is used with the mouse.
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        popoverAnchor?.orderOut(nil)
        if let monitor = popoverMonitor {
            NSEvent.removeMonitor(monitor)
            popoverMonitor = nil
        }
    }

    // MARK: - Settings

    @objc func openSettingsFromMenu(_ sender: Any?) { openSettings(nil) }
    @objc func checkForUpdatesFromMenu(_ sender: Any?) { UpdateController.shared.checkForUpdates() }

    func openSettings(_ pane: SettingsPane?) {
        closePopover()
        SettingsWindowController.shared.show(pane)
    }
}

/// A minimal main menu. The app shows no menu bar of its own, but without
/// these items ⌘C / ⌘V / ⌘A don't work in text fields and ⌘W doesn't close
/// the settings window.
enum MainMenu {
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Multitool")
        let settings = NSMenuItem(title: "Réglages…", action: #selector(AppDelegate.openSettingsFromMenu(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(settings)
        let updates = NSMenuItem(title: "Rechercher les mises à jour…", action: #selector(AppDelegate.checkForUpdatesFromMenu(_:)), keyEquivalent: "")
        updates.target = target
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Multitool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Fenêtre")
        window.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Placer dans le Dock", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }
}
