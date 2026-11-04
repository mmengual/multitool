import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultClipboard = KeyCombo(keyCode: UInt32(kVK_ANSI_V),
                                           modifiers: UInt32(cmdKey | shiftKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a combo from a key event. Returns nil when no "real" modifier
    /// (⌘, ⌃ or ⌥) is held: a global shortcut on a bare key would eat typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Espace"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return layoutCharacter(code) ?? "#\(code)"
        }
    }

    /// The character the key produces on the current keyboard layout
    /// (so a French AZERTY shows "A" where a QWERTY shows "Q").
    private static func layoutCharacter(_ code: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).uppercased()
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        }
    }
}

/// Registers system-wide shortcuts through Carbon's `RegisterEventHotKey`,
/// which needs no permission and swallows the keystroke for other apps.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        var combo: KeyCombo
        var handler: () -> Void
        var ref: EventHotKeyRef?
    }

    private var entries: [UInt32: Entry] = [:]
    private var ids: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private var suspended = false
    private let signature: OSType = 0x4D544F4C // 'MTOL'

    /// Registers (or replaces) the shortcut known as `name`. Passing nil removes it.
    func register(_ name: String, combo: KeyCombo?, handler: @escaping () -> Void) {
        unregister(name)
        guard let combo else { return }
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        ids[name] = id
        entries[id] = Entry(combo: combo, handler: handler, ref: nil)
        if !suspended { activate(id) }
    }

    func unregister(_ name: String) {
        guard let id = ids.removeValue(forKey: name) else { return }
        if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
        entries[id] = nil
    }

    /// Temporarily releases every shortcut, so a shortcut recorder can
    /// capture a combination that is already in use.
    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        for id in entries.keys {
            if value {
                if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
                entries[id]?.ref = nil
            } else {
                activate(id)
            }
        }
    }

    private func activate(_ id: UInt32) {
        guard let combo = entries[id]?.combo else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            entries[id]?.ref = ref
        } else {
            Log.app.error("RegisterEventHotKey failed (\(status)) for \(combo.displayString, privacy: .public)")
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.entries[id]?.handler() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
