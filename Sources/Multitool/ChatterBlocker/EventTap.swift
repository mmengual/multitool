import AppKit
import CoreGraphics

final class EventTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Per-key debounce state, measured from the last accepted key-up
    // (logic ported from G915-Stutter-Fix, BlockRepress mode).
    private var lastKeyUp: [Int64: UInt64] = [:]
    private var isPressed: Set<Int64> = []
    private var swallowNextUp: Set<Int64> = []
    // Caps Lock toggles on each event, it has no meaningful up/down pair.
    private static let excludedKeys: Set<Int64> = [57]
    private let stateQueue = DispatchQueue(label: "multitool.eventtap.state")
    private var isEnabled = true

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
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
                let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        isEnabled = Settings.shared.enabled
        if !isEnabled {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        return true
    }

    func enable() {
        isEnabled = true
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func disable() {
        isEnabled = false
        stateQueue.sync {
            isPressed.removeAll()
            swallowNextUp.removeAll()
        }
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled, !SyntheticEvents.isOurs(event) else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if Self.excludedKeys.contains(keyCode) {
            return Unmanaged.passUnretained(event)
        }

        let isDown: Bool
        switch type {
        case .keyDown:
            isDown = true
        case .keyUp:
            isDown = false
        case .flagsChanged:
            // Modifiers have no down/up event type: derive it from the
            // device-specific flag bit of the key that changed.
            guard let nowPressed = Self.modifierDown(flags: event.flags, keyCode: keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            let wasPressed = stateQueue.sync { isPressed.contains(keyCode) }
            if nowPressed == wasPressed {
                return Unmanaged.passUnretained(event)
            }
            isDown = nowPressed
        default:
            return Unmanaged.passUnretained(event)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let thresholdNs = UInt64(Settings.shared.thresholdMs) * 1_000_000

        var shouldDrop = false
        var intervalNs: UInt64?
        stateQueue.sync {
            if isDown {
                // Still held: autorepeat, let it through.
                if isPressed.contains(keyCode) { return }
                if let last = lastKeyUp[keyCode] {
                    intervalNs = now - last
                    if now - last < thresholdNs {
                        // Bounce: drop the press and its matching release.
                        // lastKeyUp is NOT updated, so the debounce window
                        // stays anchored on the last accepted release.
                        shouldDrop = true
                        swallowNextUp.insert(keyCode)
                        return
                    }
                }
                isPressed.insert(keyCode)
                swallowNextUp.remove(keyCode)
            } else {
                if swallowNextUp.remove(keyCode) != nil {
                    shouldDrop = true
                    return
                }
                lastKeyUp[keyCode] = now
                isPressed.remove(keyCode)
            }
        }

        if let intervalNs = intervalNs {
            let intervalMs = Double(intervalNs) / 1_000_000.0
            let wasDropped = shouldDrop
            DispatchQueue.main.async {
                ChatterDetector.shared.record(
                    keyCode: keyCode,
                    intervalMs: intervalMs,
                    wasDropped: wasDropped
                )
            }
        }

        return shouldDrop ? nil : Unmanaged.passUnretained(event)
    }

    /// Left/right device bits (NX_DEVICE*KEYMASK) for the modifier key codes.
    /// Returns nil for a key code that is not a known modifier.
    private static func modifierDown(flags: CGEventFlags, keyCode: Int64) -> Bool? {
        let raw = flags.rawValue
        switch keyCode {
        case 56: return (raw & 0x0000_0002) != 0 // left shift
        case 60: return (raw & 0x0000_0004) != 0 // right shift
        case 59: return (raw & 0x0000_0001) != 0 // left control
        case 62: return (raw & 0x0000_2000) != 0 // right control
        case 58: return (raw & 0x0000_0020) != 0 // left option
        case 61: return (raw & 0x0000_0040) != 0 // right option
        case 55: return (raw & 0x0000_0008) != 0 // left command
        case 54: return (raw & 0x0000_0010) != 0 // right command
        default: return nil
        }
    }
}
