import AppKit
import CoreGraphics

/// Swaps Cmd ↔ Option (both sides). macOS tracks the modifier state from the
/// physical keycode, not from our modified flags, so we must touch BOTH the
/// flagsChanged (keycode + flags) AND every subsequent keyDown/keyUp (flags
/// only) to keep apps consistent with the user's intent.
final class KeyRemap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isEnabled = false

    // Device-specific modifier bits (from <IOKit/hidsystem/IOLLEvent.h>) that
    // some apps use to distinguish left/right modifiers. Swap these too for
    // full compatibility.
    private let lcmdBit: UInt64 = 0x00000008
    private let rcmdBit: UInt64 = 0x00000010
    private let laltBit: UInt64 = 0x00000020
    private let raltBit: UInt64 = 0x00000040

    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
                 | (1 << CGEventType.rightMouseDown.rawValue)
                 | (1 << CGEventType.rightMouseUp.rawValue)
                 | (1 << CGEventType.rightMouseDragged.rawValue)
                 | (1 << CGEventType.otherMouseDown.rawValue)
                 | (1 << CGEventType.otherMouseUp.rawValue)
                 | (1 << CGEventType.otherMouseDragged.rawValue)
                 | (1 << CGEventType.scrollWheel.rawValue)
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
                let remap = Unmanaged<KeyRemap>.fromOpaque(userInfo).takeUnretainedValue()
                return remap.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    func enable() {
        if !isEnabled { Log.keyRemap.info("enable()") }
        isEnabled = true
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func disable() {
        if isEnabled { Log.keyRemap.info("disable()") }
        isEnabled = false
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let cause = (type == .tapDisabledByTimeout) ? "timeout" : "userInput"
            // Only re-enable if WE wanted it enabled; otherwise leave it off.
            if isEnabled, let tap = tap {
                Log.keyRemap.warning("tap disabled by \(cause, privacy: .public) — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                Log.keyRemap.notice("tap disabled by \(cause, privacy: .public) — leaving off (intentional)")
            }
            return Unmanaged.passUnretained(event)
        }
        guard isEnabled, !SyntheticEvents.isOurs(event) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let swapped: Int64?
            switch keycode {
            case 54: swapped = 61   // Right ⌘ → Right ⌥
            case 55: swapped = 58   // Left  ⌘ → Left  ⌥
            case 58: swapped = 55   // Left  ⌥ → Left  ⌘
            case 61: swapped = 54   // Right ⌥ → Right ⌘
            default: swapped = nil
            }
            if let newKey = swapped {
                event.setIntegerValueField(.keyboardEventKeycode, value: newKey)
            }
            event.flags = swapFlags(event.flags)

        case .keyDown, .keyUp,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel:
            event.flags = swapFlags(event.flags)

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func swapFlags(_ flags: CGEventFlags) -> CGEventFlags {
        var raw = flags.rawValue

        // General bits (maskCommand ↔ maskAlternate).
        let cmdMask = CGEventFlags.maskCommand.rawValue
        let altMask = CGEventFlags.maskAlternate.rawValue
        let hadCmd = (raw & cmdMask) != 0
        let hadAlt = (raw & altMask) != 0
        raw &= ~(cmdMask | altMask)
        if hadCmd { raw |= altMask }
        if hadAlt { raw |= cmdMask }

        // Device-specific left/right bits.
        let hadLCmd = (raw & lcmdBit) != 0
        let hadRCmd = (raw & rcmdBit) != 0
        let hadLAlt = (raw & laltBit) != 0
        let hadRAlt = (raw & raltBit) != 0
        raw &= ~(lcmdBit | rcmdBit | laltBit | raltBit)
        if hadLCmd { raw |= laltBit }
        if hadRCmd { raw |= raltBit }
        if hadLAlt { raw |= lcmdBit }
        if hadRAlt { raw |= rcmdBit }

        return CGEventFlags(rawValue: raw)
    }
}
