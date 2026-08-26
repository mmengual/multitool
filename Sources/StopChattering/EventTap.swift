import AppKit
import CoreGraphics

final class EventTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastKeyDown: [Int64: UInt64] = [:]
    private let stateQueue = DispatchQueue(label: "stopchattering.eventtap.state")
    private var isEnabled = true

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
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
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled, type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = DispatchTime.now().uptimeNanoseconds
        let thresholdNs = UInt64(Settings.shared.thresholdMs) * 1_000_000

        var shouldDrop = false
        var previousNs: UInt64?
        stateQueue.sync {
            previousNs = lastKeyDown[keyCode]
            if let last = previousNs, now - last < thresholdNs {
                shouldDrop = true
                // Do NOT update lastKeyDown on drop, so the debounce window
                // extends from the first accepted press (prevents chained chatter).
            } else {
                lastKeyDown[keyCode] = now
            }
        }

        if let last = previousNs {
            let intervalMs = Double(now - last) / 1_000_000.0
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
}
