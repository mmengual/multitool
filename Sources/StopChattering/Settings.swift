import Foundation
import Combine

enum MouseButton: Int, Equatable {
    case unset = 0
    case left = 1
    case right = 2
}

enum SwapMode: Int, Equatable {
    case off = 0
    case auto = 1
    case on = 2
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var thresholdMs: Int = 30 {
        didSet { defaults.set(thresholdMs, forKey: "thresholdMs") }
    }
    @Published var enabled: Bool = true {
        didSet { defaults.set(enabled, forKey: "enabled") }
    }

    @Published var windowMoverEnabled: Bool = true {
        didSet { defaults.set(windowMoverEnabled, forKey: "windowMoverEnabled") }
    }
    @Published var windowMoverModifiers: ModifierMask = [.cmd, .ctrl] {
        didSet { defaults.set(windowMoverModifiers.rawValue, forKey: "windowMoverModifiers") }
    }
    @Published var moveButton: MouseButton = .left {
        didSet { defaults.set(moveButton.rawValue, forKey: "moveButton") }
    }
    @Published var resizeButton: MouseButton = .right {
        didSet { defaults.set(resizeButton.rawValue, forKey: "resizeButton") }
    }

    @Published var swapCmdOptionMode: SwapMode = .off {
        didSet { defaults.set(swapCmdOptionMode.rawValue, forKey: "swapCmdOptionMode") }
    }

    static let thresholdRange: ClosedRange<Int> = 20...200

    private init() {
        if let v = defaults.object(forKey: "thresholdMs") as? Int {
            thresholdMs = min(max(v, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        }
        if let v = defaults.object(forKey: "enabled") as? Bool { enabled = v }
        if let v = defaults.object(forKey: "windowMoverEnabled") as? Bool { windowMoverEnabled = v }
        if let v = defaults.object(forKey: "windowMoverModifiers") as? Int {
            windowMoverModifiers = ModifierMask(rawValue: v)
        }
        if let v = defaults.object(forKey: "moveButton") as? Int,
           let b = MouseButton(rawValue: v) { moveButton = b }
        if let v = defaults.object(forKey: "resizeButton") as? Int,
           let b = MouseButton(rawValue: v) { resizeButton = b }
        if let v = defaults.object(forKey: "swapCmdOptionMode") as? Int,
           let m = SwapMode(rawValue: v) { swapCmdOptionMode = m }
    }
}
