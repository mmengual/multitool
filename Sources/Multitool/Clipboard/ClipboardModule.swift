import AppKit
import Combine

/// Wires the clipboard pieces to the settings: the monitor and the global
/// shortcut only exist while the module is enabled.
@MainActor
final class ClipboardModule {
    static let shared = ClipboardModule()
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        _ = ClipboardStore.shared
        let s = Settings.shared
        s.$clipboardEnabled.combineLatest(s.$clipboardHotKey)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, combo in self?.apply(enabled: enabled, combo: combo) }
            .store(in: &cancellables)
    }

    func stop() {
        ClipboardStore.shared.saveNow()
    }

    private func apply(enabled: Bool, combo: KeyCombo?) {
        if enabled {
            ClipboardMonitor.shared.start()
            HotKeyCenter.shared.register("clipboard", combo: combo) {
                ClipboardPanelController.shared.toggle()
            }
        } else {
            ClipboardMonitor.shared.stop()
            HotKeyCenter.shared.unregister("clipboard")
            ClipboardPanelController.shared.close()
        }
    }
}
