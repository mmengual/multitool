import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: EventTap?
    private var windowMover: WindowMover?
    private var keyRemap: KeyRemap?
    private let popover = NSPopover()
    private var popoverMonitor: Any?
    private var permissionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Orbe, theme `sombre`: every window, popover and alert is dark.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.make(target: self)
        setUpStatusItem()

        KeyboardDetector.shared.start()
        GameDetector.shared.start()
        ClipboardModule.shared.start()
        UpdateController.shared.start()

        bindModules()
        startInputModules()
        handleDevArguments()
    }

    // MARK: - Accessibility

    /// The keyboard and mouse modules need the Accessibility permission. Without
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
        if keyRemap == nil {
            let remap = KeyRemap()
            if remap.start() { keyRemap = remap }
        }

        let ready = eventTap != nil && windowMover != nil && keyRemap != nil
        if ready {
            permissionTimer?.invalidate()
            permissionTimer = nil
            applyChatterState()
            applyWindowMoverState()
            applyRemapState()
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

        settings.$enabled
            .combineLatest(settings.$pauseInGame, GameDetector.shared.$inGame)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in DispatchQueue.main.async { self?.applyChatterState() } }
            .store(in: &cancellables)

        settings.$windowMoverEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyWindowMoverState() } }
            .store(in: &cancellables)

        settings.$swapCmdOptionMode
            .combineLatest(KeyboardDetector.shared.$hasLogitechKeyboard)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.applyRemapState() } }
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

    private func applyRemapState() {
        let mode = Settings.shared.swapCmdOptionMode
        let hasLogi = KeyboardDetector.shared.hasLogitechKeyboard
        let active = mode == .on || (mode == .auto && hasLogi)
        Log.app.info("remap mode=\(String(describing: mode), privacy: .public) logi=\(hasLogi) -> active=\(active)")
        active ? keyRemap?.enable() : keyRemap?.disable()
    }

    // MARK: - Status item and popover

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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

    private func showPopover(from button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
