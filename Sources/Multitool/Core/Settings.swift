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

/// Every persisted preference of the app, one `UserDefaults` key per property.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // MARK: Chatter Blocker

    @Published var thresholdMs: Int = 30 {
        didSet { defaults.set(thresholdMs, forKey: "thresholdMs") }
    }
    @Published var enabled: Bool = true {
        didSet { defaults.set(enabled, forKey: "enabled") }
    }
    @Published var pauseInGame: Bool = true {
        didSet { defaults.set(pauseInGame, forKey: "pauseInGame") }
    }

    // MARK: Window Mover

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

    // MARK: Key remap

    @Published var swapCmdOptionMode: SwapMode = .off {
        didSet { defaults.set(swapCmdOptionMode.rawValue, forKey: "swapCmdOptionMode") }
    }

    // MARK: Clipboard

    @Published var clipboardEnabled: Bool = true {
        didSet { defaults.set(clipboardEnabled, forKey: "clipboard.enabled") }
    }
    @Published var clipboardHotKey: KeyCombo? = KeyCombo.defaultClipboard {
        didSet { saveCodable(clipboardHotKey, forKey: "clipboard.hotKey") }
    }
    @Published var clipboardMaxItems: Int = 300 {
        didSet { defaults.set(clipboardMaxItems, forKey: "clipboard.maxItems") }
    }
    /// 0 = keep forever.
    @Published var clipboardRetentionDays: Int = 30 {
        didSet { defaults.set(clipboardRetentionDays, forKey: "clipboard.retentionDays") }
    }
    @Published var clipboardIgnoreSensitive: Bool = true {
        didSet { defaults.set(clipboardIgnoreSensitive, forKey: "clipboard.ignoreSensitive") }
    }
    @Published var clipboardCaptureImages: Bool = true {
        didSet { defaults.set(clipboardCaptureImages, forKey: "clipboard.captureImages") }
    }
    @Published var clipboardAutoPaste: Bool = true {
        didSet { defaults.set(clipboardAutoPaste, forKey: "clipboard.autoPaste") }
    }
    @Published var clipboardExcludedApps: [String] = Settings.defaultExcludedApps {
        didSet { defaults.set(clipboardExcludedApps, forKey: "clipboard.excludedApps") }
    }

    static let thresholdRange: ClosedRange<Int> = 20...200
    static let defaultExcludedApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    private init() {
        Self.migrateFromStopChattering(into: defaults)

        if let v = defaults.object(forKey: "thresholdMs") as? Int {
            thresholdMs = min(max(v, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        }
        if let v = defaults.object(forKey: "enabled") as? Bool { enabled = v }
        if let v = defaults.object(forKey: "pauseInGame") as? Bool { pauseInGame = v }
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

        if let v = defaults.object(forKey: "clipboard.enabled") as? Bool { clipboardEnabled = v }
        if defaults.object(forKey: "clipboard.hotKey") != nil {
            // A stored `null` means the user cleared the shortcut on purpose.
            clipboardHotKey = loadCodable(KeyCombo?.self, forKey: "clipboard.hotKey") ?? nil
        }
        if let v = defaults.object(forKey: "clipboard.maxItems") as? Int { clipboardMaxItems = max(10, v) }
        if let v = defaults.object(forKey: "clipboard.retentionDays") as? Int { clipboardRetentionDays = max(0, v) }
        if let v = defaults.object(forKey: "clipboard.ignoreSensitive") as? Bool { clipboardIgnoreSensitive = v }
        if let v = defaults.object(forKey: "clipboard.captureImages") as? Bool { clipboardCaptureImages = v }
        if let v = defaults.object(forKey: "clipboard.autoPaste") as? Bool { clipboardAutoPaste = v }
        if let v = defaults.object(forKey: "clipboard.excludedApps") as? [String] { clipboardExcludedApps = v }
    }

    private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The app used to be called StopChattering (bundle id com.mmengual.stopchattering).
    /// Copy its preferences once so the rename doesn't reset the user's settings.
    private static func migrateFromStopChattering(into defaults: UserDefaults) {
        let doneKey = "migratedFromStopChattering"
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        guard let old = UserDefaults(suiteName: "com.mmengual.stopchattering") else { return }
        let keys = ["thresholdMs", "enabled", "pauseInGame", "windowMoverEnabled",
                    "windowMoverModifiers", "moveButton", "resizeButton", "swapCmdOptionMode"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let v = old.object(forKey: key) { defaults.set(v, forKey: key) }
        }
    }
}
