import AppKit
import ApplicationServices
import CoreGraphics

struct ModifierMask: OptionSet, Equatable {
    let rawValue: Int
    static let cmd    = ModifierMask(rawValue: 1 << 0)
    static let ctrl   = ModifierMask(rawValue: 1 << 1)
    static let option = ModifierMask(rawValue: 1 << 2)
    static let shift  = ModifierMask(rawValue: 1 << 3)

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.cmd)    { f.insert(.maskCommand) }
        if contains(.ctrl)   { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift)  { f.insert(.maskShift) }
        return f
    }

    var symbol: String {
        var s = ""
        if contains(.ctrl)   { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift)  { s += "⇧" }
        if contains(.cmd)    { s += "⌘" }
        return s.isEmpty ? "—" : s
    }
}

private enum WindowOp {
    case move(window: AXUIElement, mouseStart: CGPoint, originStart: CGPoint)
    case resize(window: AXUIElement, mouseStart: CGPoint, sizeStart: CGSize)
}

private struct WindowCandidate {
    let pid: pid_t
    let bounds: CGRect
}

final class WindowMover {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var op: WindowOp?
    private var swallowingLeft = false
    private var swallowingRight = false
    // Generation counters per button: every mouseDown bumps the counter so
    // late-arriving async results from a previous click cycle are ignored.
    private var leftGen = 0
    private var rightGen = 0
    private var isEnabled = true
    private let modifierBits: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    // Async coalescing: AX calls are slow (Mach IPC to target app). We keep
    // only the latest pending target and never let more than one call be
    // in-flight, so the window always tracks the most recent cursor position.
    private let axQueue = DispatchQueue(label: "multitool.windowmover.ax",
                                        qos: .userInteractive)
    private var pendingPosition: CGPoint?
    private var pendingSize: CGSize?
    private var pendingWindow: AXUIElement?
    private var axInFlight = false

    func start() -> Bool {
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let mover = Unmanaged<WindowMover>.fromOpaque(userInfo).takeUnretainedValue()
                return mover.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.runLoopSource = source
        isEnabled = Settings.shared.windowMoverEnabled
        CGEvent.tapEnable(tap: tap, enable: isEnabled)
        return true
    }

    func enable() {
        isEnabled = true
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func disable() {
        isEnabled = false
        op = nil
        swallowingLeft = false
        swallowingRight = false
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func pass(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass(event)
        }
        guard isEnabled else { return pass(event) }

        let required = Settings.shared.windowMoverModifiers.cgFlags
        let modifiersHeld = !required.isEmpty &&
            event.flags.intersection(modifierBits) == required

        switch type {
        case .leftMouseDown:
            return handleDown(button: .left, modifiersHeld: modifiersHeld, event: event)
        case .leftMouseDragged:
            return handleDragged(button: .left, event: event)
        case .leftMouseUp:
            return handleUp(button: .left, event: event)
        case .rightMouseDown:
            return handleDown(button: .right, modifiersHeld: modifiersHeld, event: event)
        case .rightMouseDragged:
            return handleDragged(button: .right, event: event)
        case .rightMouseUp:
            return handleUp(button: .right, event: event)
        case .flagsChanged:
            // Modifier released mid-drag aborts the move/resize but we keep
            // swallowing until mouseUp so the receiver doesn't see an orphan up.
            if op != nil && !modifiersHeld { endCurrentOp() }
            return pass(event)
        default:
            return pass(event)
        }
    }

    private enum DragKind { case move, resize }

    private func dragKind(for button: MouseButton) -> DragKind? {
        if Settings.shared.moveButton == button { return .move }
        if Settings.shared.resizeButton == button { return .resize }
        return nil
    }

    private func handleDown(button: MouseButton, modifiersHeld: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard modifiersHeld, let kind = dragKind(for: button) else { return pass(event) }
        let downPoint = event.location

        // Synchronous fast path: ask WindowServer if there's any normal-layer
        // window under the cursor. Doesn't IPC to the target app (~1 ms typical),
        // so safe to run inside the event tap callback. If nothing's there
        // (e.g. desktop click), we let the event through.
        guard let candidate = candidateWindowInfo(at: downPoint) else {
            return pass(event)
        }

        // Commit to swallowing this click cycle now. AX resolution happens
        // async; even if it fails, the click has already been intercepted —
        // better than letting a context menu leak through in slow apps.
        setSwallow(button, true)
        let gen: Int
        switch button {
        case .left:  leftGen += 1; gen = leftGen
        case .right: rightGen += 1; gen = rightGen
        case .unset: return nil
        }

        axQueue.async { [weak self] in
            guard let self = self else { return }
            let window = self.axWindowMatching(pid: candidate.pid, bounds: candidate.bounds)
            let origin = window.flatMap { self.position(of: $0) }
            let sz     = window.flatMap { self.size(of: $0) }

            DispatchQueue.main.async {
                let currentGen = (button == .left) ? self.leftGen : self.rightGen
                guard currentGen == gen, self.isSwallowing(button) else { return }
                guard let window = window, let origin = origin, let sz = sz else { return }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                switch kind {
                case .move:
                    self.op = .move(window: window, mouseStart: downPoint, originStart: origin)
                case .resize:
                    self.op = .resize(window: window, mouseStart: downPoint, sizeStart: sz)
                }
            }
        }

        return nil
    }

    private func handleDragged(button: MouseButton, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isSwallowing(button) else { return pass(event) }
        if op != nil { updateOp(at: event.location) }
        return nil
    }

    private func handleUp(button: MouseButton, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isSwallowing(button) else { return pass(event) }
        setSwallow(button, false)
        endCurrentOp()
        return nil
    }

    private func setSwallow(_ button: MouseButton, _ value: Bool) {
        switch button {
        case .left: swallowingLeft = value
        case .right: swallowingRight = value
        case .unset: break
        }
    }

    private func isSwallowing(_ button: MouseButton) -> Bool {
        switch button {
        case .left: return swallowingLeft
        case .right: return swallowingRight
        case .unset: return false
        }
    }

    private func updateOp(at point: CGPoint) {
        guard let op = op else { return }
        switch op {
        case .move(let window, let mouseStart, let originStart):
            let new = CGPoint(x: originStart.x + (point.x - mouseStart.x),
                              y: originStart.y + (point.y - mouseStart.y))
            pendingWindow = window
            pendingPosition = new
            pumpAX()
        case .resize(let window, let mouseStart, let sizeStart):
            let new = CGSize(width: max(80, sizeStart.width + (point.x - mouseStart.x)),
                             height: max(60, sizeStart.height + (point.y - mouseStart.y)))
            pendingWindow = window
            pendingSize = new
            pumpAX()
        }
    }

    private func endCurrentOp() {
        op = nil
        pendingPosition = nil
        pendingSize = nil
    }

    private func pumpAX() {
        if axInFlight { return }
        guard let window = pendingWindow else { return }
        let pos = pendingPosition
        let size = pendingSize
        if pos == nil && size == nil { return }
        pendingPosition = nil
        pendingSize = nil
        axInFlight = true

        axQueue.async { [weak self] in
            if var p = pos, let v = AXValueCreate(.cgPoint, &p) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
            }
            if var s = size, let v = AXValueCreate(.cgSize, &s) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.axInFlight = false
                self.pumpAX()
            }
        }
    }

    // MARK: - Window discovery

    /// Synchronous; queries WindowServer only (no per-app IPC). Returns the
    /// front-most normal-layer window whose bounds contain `point`.
    private func candidateWindowInfo(at point: CGPoint) -> WindowCandidate? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidNum = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsAny = info[kCGWindowBounds as String]
            else { continue }
            let cfDict = boundsAny as! CFDictionary
            guard let bounds = CGRect(dictionaryRepresentation: cfDict) else { continue }
            if bounds.contains(point) {
                return WindowCandidate(pid: pid_t(pidNum), bounds: bounds)
            }
        }
        return nil
    }

    /// Async-safe; resolves the AXUIElement window of a given app whose frame
    /// matches the WindowServer bounds we recorded. Robust against AX trees
    /// that don't roll up cleanly (Electron, Office) because we never walk
    /// from a child element.
    private func axWindowMatching(pid: pid_t, bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        for window in windows {
            guard let pos = position(of: window), let sz = size(of: window) else { continue }
            if abs(pos.x - bounds.origin.x) < 3,
               abs(pos.y - bounds.origin.y) < 3,
               abs(sz.width - bounds.size.width) < 3,
               abs(sz.height - bounds.size.height) < 3 {
                return window
            }
        }
        // Fallbacks if no exact-match: focused window, then first.
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let focused = ref {
            return (focused as! AXUIElement)
        }
        return windows.first
    }

    // MARK: - AX value helpers

    private func position(of window: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success,
              let v = ref else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &p)
        return p
    }

    private func size(of window: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &ref) == .success,
              let v = ref else { return nil }
        var s = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &s)
        return s
    }

}
