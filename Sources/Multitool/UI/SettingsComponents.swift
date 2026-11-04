import AppKit
import SwiftUI

/// Standard layout of a pane: Orbe sections stacked in a scroll view,
/// capped to a readable width.
struct PaneForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Orbe.Space.s7) { content }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(Orbe.Densite.marge)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Records a global shortcut. Every registered shortcut is released while
/// recording, so the current one can be typed again.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: Orbe.Space.s3) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Tapez le raccourci" : (combo?.displayString ?? "Aucun"))
                    .font(recording ? Orbe.font(.texte) : Orbe.font(.donnee))
                    .frame(minWidth: 120)
            }
            .buttonStyle(OrbeButtonStyle(variante: recording ? .plein : .contour))
            if combo != nil, !recording {
                Button { combo = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.orbeDiscret)
                    .help("Supprimer le raccourci")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // esc cancels
            if let new = KeyCombo(event: event) {
                combo = new
                stop()
            } else {
                NSSound.beep() // needs ⌘, ⌃ or ⌥
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKeyCenter.shared.setSuspended(false) }
        recording = false
    }
}

/// Refreshes a view every second, for states macOS doesn't notify
/// (permissions, login item).
struct PeriodicRefresh: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: action)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in action() }
    }
}

extension View {
    func refreshEverySecond(_ action: @escaping () -> Void) -> some View {
        modifier(PeriodicRefresh(action: action))
    }
}
