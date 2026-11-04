import AppKit
import SwiftUI
import Combine

/// A floating panel that takes the keyboard without activating Multitool:
/// the app the user was typing in stays frontmost, so ⌘V lands there.
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// State shared by the panel's SwiftUI view and its keyboard handling.
@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" { didSet { selectFirstIfNeeded() } }
    @Published var selectedID: UUID?
    @Published var focusToken = UUID()

    let store = ClipboardStore.shared
    var onPick: (ClipboardItem, _ plainText: Bool) -> Void = { _, _ in }
    private var cancellables: Set<AnyCancellable> = []

    init() {
        store.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.selectFirstIfNeeded() } }
            .store(in: &cancellables)
    }

    var pinned: [ClipboardItem] { store.pinned.filter { $0.matches(query) } }
    var recent: [ClipboardItem] { store.recent.filter { $0.matches(query) } }
    /// Keyboard order: pinned first, then the history.
    var visible: [ClipboardItem] { pinned + recent }
    var selected: ClipboardItem? { visible.first { $0.id == selectedID } ?? visible.first }

    func reset() {
        query = ""
        selectedID = visible.first?.id
        focusToken = UUID()
    }

    func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = list[min(max(current + delta, 0), list.count - 1)].id
    }

    func pick(plainText: Bool = false) {
        guard let item = selected else { return }
        onPick(item, plainText)
    }

    func pick(index: Int) {
        let list = visible
        guard index < list.count else { return }
        onPick(list[index], false)
    }

    func togglePinSelected() {
        guard let item = selected else { return }
        store.togglePin(item)
    }

    func deleteSelected() {
        guard let item = selected else { return }
        move(1)
        if selectedID == item.id { move(-1) }
        store.delete(item)
    }

    private func selectFirstIfNeeded() {
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }
}

/// Opens and closes the panel, and handles its keyboard shortcuts.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()

    private var panel: ClipboardPanel?
    private let model = ClipboardPanelModel()
    private var keyMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    override init() {
        super.init()
        model.onPick = { [weak self] item, plain in self?.paste(item, plainText: plain) }
    }

    func toggle() { isVisible ? close() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.reset()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        ClipboardMonitor.shared.write(item, plainText: plainText)
        close()
        guard Settings.shared.clipboardAutoPaste, Permissions.accessibility else { return }
        // Give the target app a moment to get the keyboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { SyntheticEvents.postPaste() }
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 560, height: 320)
        panel.setFrameAutosaveName("MultitoolClipboardPanel")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ClipboardPanelView(model: model))
        return panel
    }

    /// Centers the panel in the upper part of the screen under the mouse.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width - 40)
        frame.size.height = min(frame.height, visible.height - 40)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.minY + (visible.height - frame.height) * 0.62
        panel.setFrame(frame, display: false)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was handled here.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        switch event.keyCode {
        case 125: model.move(1); return true                       // ↓
        case 126: model.move(-1); return true                      // ↑
        case 36, 76: model.pick(plainText: flags.contains(.option)); return true // ↩
        case 53:                                                    // ⎋
            if model.query.isEmpty { close() } else { model.query = "" }
            return true
        case 51 where cmd: model.deleteSelected(); return true     // ⌘⌫
        default: break
        }
        if cmd, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "p" { model.togglePinSelected(); return true }
            if chars == "w" { close(); return true }
        }
        // ⌘1…⌘9 by key code, so it also works on AZERTY where the row types &é"'…
        if cmd, let index = Self.digitRow.firstIndex(of: event.keyCode) {
            model.pick(index: index); return true
        }
        return false
    }

    /// Key codes of the 1…9 keys of the top row, layout-independent.
    private static let digitRow: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
}
