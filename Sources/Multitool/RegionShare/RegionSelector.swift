import AppKit

/// Fullscreen overlay: user drags a rectangle, mouse up confirms (or escape cancels).
/// `onComplete` is called with the selected rect in display-local **top-left** screen
/// coordinates (what ScreenCaptureKit wants for `SCStreamConfiguration.sourceRect`).
final class RegionSelector: NSObject {
    private var window: SelectorWindow?
    var onComplete: ((CGRect?) -> Void)?

    func show() {
        guard window == nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first!

        let w = SelectorWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.level = .screenSaver
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = false

        let view = SelectorView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.targetScreen = screen
        view.onComplete = { [weak self] rect in
            self?.hide()
            self?.onComplete?(rect)
        }
        w.contentView = view

        window = w
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class SelectorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectorView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    var targetScreen: NSScreen?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            currentPoint = nil
        }
        guard let start = startPoint, let end = currentPoint else {
            onComplete?(nil); return
        }
        let local = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
        guard local.width >= 40, local.height >= 30, let screen = targetScreen else {
            onComplete?(nil); return
        }
        // Window covers full screen, origin matches the screen's origin in the global
        // (bottom-left) NSScreen space. SCStreamConfiguration.sourceRect wants
        // display-local top-left coords.
        let topLeft = CGRect(
            x: local.origin.x,
            y: screen.frame.height - local.maxY,
            width: local.width,
            height: local.height
        )
        onComplete?(topLeft)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // escape
            onComplete?(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim everything, with a transparent hole over the selected rect.
        var hole = NSRect.zero
        if let s = startPoint, let c = currentPoint {
            hole = NSRect(
                x: min(s.x, c.x),
                y: min(s.y, c.y),
                width: abs(s.x - c.x),
                height: abs(s.y - c.y)
            )
        }
        let path = NSBezierPath(rect: bounds)
        if !hole.isEmpty {
            path.appendRect(hole)
        }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        path.fill()

        if !hole.isEmpty {
            NSColor.systemGreen.setStroke()
            let stroke = NSBezierPath(rect: hole)
            stroke.lineWidth = 2
            stroke.stroke()

            // Small size hint in the corner of the selection.
            let label = "\(Int(hole.width)) × \(Int(hole.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.6)
            ]
            label.draw(at: NSPoint(x: hole.minX + 6, y: hole.minY + 4), withAttributes: attrs)
        }
    }
}
