import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: EventTap?
    private var windowMover: WindowMover?
    private var keyRemap: KeyRemap?
    private var statsWindowController: NSWindowController?
    private let popover = NSPopover()
    private var popoverMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis",
                                   accessibilityDescription: "StopChattering")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 580)
        popover.contentViewController = NSHostingController(rootView: PreferencesView())

        let tap = EventTap()
        if tap.start() {
            eventTap = tap
        } else {
            promptForAccessibility()
        }

        let mover = WindowMover()
        if mover.start() {
            windowMover = mover
        }

        let remap = KeyRemap()
        if remap.start() {
            keyRemap = remap
        }
        KeyboardDetector.shared.start()

        ChatterDetector.shared.$totalDropped
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.updateStatusTitle(dropped: count)
            }
            .store(in: &cancellables)

        Settings.shared.$enabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                on ? self?.eventTap?.enable() : self?.eventTap?.disable()
            }
            .store(in: &cancellables)

        Settings.shared.$windowMoverEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                on ? self?.windowMover?.enable() : self?.windowMover?.disable()
            }
            .store(in: &cancellables)

        Settings.shared.$swapCmdOptionMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRemapState() }
            .store(in: &cancellables)

        KeyboardDetector.shared.$hasLogitechKeyboard
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRemapState() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .openStatsWindow, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showStatsWindow() }
        }
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover(from: sender)
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // The popover doesn't pull focus on its own in an .accessory app — bring
        // the app forward so SwiftUI controls receive interaction events cleanly.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        // Close on outside clicks (transient handles this, but a global monitor
        // covers cases where the click is on another app's window).
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = popoverMonitor {
            NSEvent.removeMonitor(monitor)
            popoverMonitor = nil
        }
    }

    private func updateRemapState() {
        let mode = Settings.shared.swapCmdOptionMode
        let hasLogi = KeyboardDetector.shared.hasLogitechKeyboard
        let active = mode == .on || (mode == .auto && hasLogi)
        Log.app.info("updateRemapState mode=\(String(describing: mode), privacy: .public) logi=\(hasLogi) -> active=\(active)")
        active ? keyRemap?.enable() : keyRemap?.disable()
    }

    private func updateStatusTitle(dropped: Int) {
        guard let button = statusItem.button else { return }
        button.title = dropped > 0 ? " \(dropped)" : ""
    }

    // MARK: - Stats window

    func showStatsWindow() {
        if statsWindowController == nil {
            let host = NSHostingController(rootView: StatsView())
            let window = NSWindow(contentViewController: host)
            window.title = "StopChattering — Stats"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 720, height: 600))
            window.center()
            window.isReleasedWhenClosed = false
            statsWindowController = NSWindowController(window: window)
        }
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        statsWindowController?.showWindow(nil)
        statsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Accessibility

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility access required"
        alert.informativeText = """
        StopChattering needs Accessibility permission to filter keyboard events and resize/move windows.

        Open System Settings → Privacy & Security → Accessibility, enable StopChattering, then relaunch.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }
}
