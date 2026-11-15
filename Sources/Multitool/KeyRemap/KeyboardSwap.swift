import Foundation
import Combine
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// A keyboard plugged in, as macOS sees it.
struct ConnectedKeyboard: Identifiable, Equatable {
    let vendorID: Int
    let productID: Int
    let name: String
    let builtIn: Bool
    /// Also exposes a mouse: a wireless receiver, often used for a mouse only.
    let isReceiver: Bool
    /// Cmd and Option are swapped in this keyboard's macOS setting.
    let swapped: Bool

    /// Same suffix as the macOS preference key, e.g. "1130-275-0".
    var id: String { "\(vendorID)-\(productID)-0" }
}

/// Swaps Cmd and Option through the macOS "Modifier Keys" setting
/// (System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys), one
/// keyboard at a time.
///
/// macOS stores that setting per keyboard in the global domain, current host,
/// under `com.apple.keyboard.modifiermapping.<vendor>-<product>-0`, and applies
/// it every time the keyboard is plugged in, whether Multitool runs or not. The
/// swap happens before any app sees the key: it works in password fields and
/// games, and only on that keyboard. Multitool writes the same entry, then
/// pushes it to the plugged-in keyboard so it takes effect at once.
final class KeyboardSwap: ObservableObject {
    static let shared = KeyboardSwap()

    @Published private(set) var keyboards: [ConnectedKeyboard] = []
    @Published private(set) var lastError: String?

    private var manager: IOHIDManager?
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    // HID usages (page 7) of the modifiers, in the form macOS stores them.
    private static let leftOption: Int64 = 0x7_0000_00E2
    private static let leftCommand: Int64 = 0x7_0000_00E3
    private static let rightOption: Int64 = 0x7_0000_00E6
    private static let rightCommand: Int64 = 0x7_0000_00E7
    private static let swapPairs: [(Int64, Int64)] = [
        (leftOption, leftCommand), (leftCommand, leftOption),
        (rightOption, rightCommand), (rightCommand, rightOption),
    ]
    private static let srcKey = kIOHIDKeyboardModifierMappingSrcKey as String
    private static let dstKey = kIOHIDKeyboardModifierMappingDstKey as String

    /// Watches keyboards being plugged in and out to keep the list current.
    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matching: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let swap = Unmanaged<KeyboardSwap>.fromOpaque(context).takeUnretainedValue()
            // The HID event system lists the new service a moment after the device.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { swap.refresh() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, selfPtr)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        refresh()
    }

    /// Re-reads the plugged-in keyboards and their setting. Cheap: called when
    /// a pane appears, so a change made in System Settings shows up.
    func refresh() {
        var seen = Set<String>()
        var list: [ConnectedKeyboard] = []
        let pointers = Set(allServices()
            .filter { IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0 }
            .map { "\(Self.int($0, kIOHIDVendorIDKey))-\(Self.int($0, kIOHIDProductIDKey))-0" })
        for service in keyboardServices() {
            let vendor = Self.int(service, kIOHIDVendorIDKey)
            let product = Self.int(service, kIOHIDProductIDKey)
            let id = "\(vendor)-\(product)-0"
            guard seen.insert(id).inserted else { continue }
            let name = IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String ?? "Clavier"
            let builtIn = Self.int(service, kIOHIDBuiltInKey) != 0
            list.append(ConnectedKeyboard(vendorID: vendor, productID: product, name: name,
                                          builtIn: builtIn, isReceiver: !builtIn && pointers.contains(id),
                                          swapped: Self.isSwapped(Self.pairs(for: id))))
        }
        // Keyboards first, then receivers, then the built-in one.
        func rank(_ k: ConnectedKeyboard) -> Int { k.builtIn ? 2 : k.isReceiver ? 1 : 0 }
        list.sort { (rank($0), $0.name) < (rank($1), $1.name) }
        if list != keyboards { keyboards = list }
    }

    /// Turns the swap on or off for one keyboard. Other remappings of that
    /// keyboard (Caps Lock, Control…) are kept.
    func setSwapped(_ swapped: Bool, for keyboard: ConnectedKeyboard) {
        let modifierUsages = Set([Self.leftOption, Self.leftCommand, Self.rightOption, Self.rightCommand])
        var pairs = Self.pairs(for: keyboard.id).filter { pair in
            guard let src = (pair[Self.srcKey] as? NSNumber)?.int64Value else { return true }
            return !modifierUsages.contains(src)
        }
        if swapped {
            pairs += Self.swapPairs.map { [Self.srcKey: NSNumber(value: $0.0), Self.dstKey: NSNumber(value: $0.1)] }
        }

        let key = "com.apple.keyboard.modifiermapping.\(keyboard.id)" as CFString
        CFPreferencesSetValue(key, pairs.isEmpty ? nil : pairs as CFArray,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)

        // Apply now: macOS only reads the preference when the keyboard is plugged in.
        var applied = false
        for service in keyboardServices()
        where Self.int(service, kIOHIDVendorIDKey) == keyboard.vendorID
            && Self.int(service, kIOHIDProductIDKey) == keyboard.productID {
            applied = IOHIDServiceClientSetProperty(service, kIOHIDKeyboardModifierMappingPairsKey as CFString,
                                                    pairs as CFArray) || applied
        }
        lastError = applied ? nil : "Réglage enregistré, il s'appliquera au prochain branchement du clavier."
        Log.keyRemap.info("swap=\(swapped) keyboard=\(keyboard.id, privacy: .public) applied=\(applied)")
        refresh()
    }

    /// One line for the popover and the general pane.
    var summary: String {
        let external = keyboards.filter { !$0.builtIn }
        let swapped = keyboards.filter(\.swapped)
        if external.isEmpty && swapped.isEmpty { return "Aucun clavier externe branché" }
        if swapped.isEmpty { return "Aucun clavier inversé" }
        if swapped.count == 1 { return "Inversé sur \(swapped[0].name)" }
        return "Inversé sur \(compte(swapped.count, "clavier"))"
    }

    /// The keyboard the popover switch acts on: the only external keyboard,
    /// receivers aside, or the only receiver when there is no other.
    var soleExternal: ConnectedKeyboard? {
        let keyboards = keyboards.filter { !$0.builtIn && !$0.isReceiver }
        if keyboards.count == 1 { return keyboards[0] }
        let receivers = self.keyboards.filter(\.isReceiver)
        return keyboards.isEmpty && receivers.count == 1 ? receivers[0] : nil
    }

    // MARK: - Helpers

    private func allServices() -> [IOHIDServiceClient] {
        IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
    }

    private func keyboardServices() -> [IOHIDServiceClient] {
        allServices().filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }
    }

    private static func int(_ service: IOHIDServiceClient, _ key: String) -> Int {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func pairs(for id: String) -> [[String: Any]] {
        let key = "com.apple.keyboard.modifiermapping.\(id)" as CFString
        let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return value as? [[String: Any]] ?? []
    }

    private static func isSwapped(_ pairs: [[String: Any]]) -> Bool {
        let map = Dictionary(pairs.compactMap { pair -> (Int64, Int64)? in
            guard let src = (pair[srcKey] as? NSNumber)?.int64Value,
                  let dst = (pair[dstKey] as? NSNumber)?.int64Value else { return nil }
            return (src, dst)
        }, uniquingKeysWith: { _, last in last })
        return map[leftOption] == leftCommand && map[leftCommand] == leftOption
    }
}
