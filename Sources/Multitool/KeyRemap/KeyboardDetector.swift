import Foundation
import Combine
import IOKit
import IOKit.hid

final class KeyboardDetector: ObservableObject {
    static let shared = KeyboardDetector()

    @Published private(set) var hasLogitechKeyboard: Bool = false
    @Published private(set) var detectedVendorNames: [String] = []

    private var manager: IOHIDManager?
    private let logitechVID = 0x046d

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matching: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey:     kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        guard result == kIOReturnSuccess else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let ctx = context else { return }
            DispatchQueue.main.async {
                Unmanaged<KeyboardDetector>.fromOpaque(ctx).takeUnretainedValue().refresh()
            }
        }, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let ctx = context else { return }
            DispatchQueue.main.async {
                Unmanaged<KeyboardDetector>.fromOpaque(ctx).takeUnretainedValue().refresh()
            }
        }, selfPtr)

        self.manager = manager
        refresh()
    }

    private func refresh() {
        guard let manager = manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var foundLogitech = false
        var names: [String] = []
        for device in devices {
            let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            if vid == logitechVID { foundLogitech = true }
            if let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
                names.append(name)
            }
        }
        if hasLogitechKeyboard != foundLogitech {
            Log.detector.info("logitech presence \(self.hasLogitechKeyboard) -> \(foundLogitech, privacy: .public), devices=\(names.joined(separator: ","), privacy: .public)")
            hasLogitechKeyboard = foundLogitech
        }
        if detectedVendorNames != names { detectedVendorNames = names }
    }
}
