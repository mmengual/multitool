import AppKit

/// What is left of lot 4's arrangement: putting back the order of the menu bar as it
/// was before Multitool 0.4.x wrote in macOS's position table
/// (`~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`,
/// key `TrailingItemPreferredPositions`). 0.4.x kept the first table it saw in
/// `backupURL`. Reading and writing the table takes Full Disk Access.
enum MenuBarLayoutStore {
    private static let domain = (NSHomeDirectory()
        + "/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar") as CFString
    private static let tableKey = "TrailingItemPreferredPositions" as CFString

    static var backupURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Multitool/menubar-layout-origin.plist")
    }

    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    /// Writes the saved weights back. False without access to the table. The caller
    /// then makes MenuBarAgent read it again (`MenuBarChevron.forceLayoutRead`).
    static func restoreBackup() -> Bool {
        guard let saved = NSDictionary(contentsOf: backupURL) as? [String: Any] else { return false }
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard var table = CFPreferencesCopyValue(tableKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String: Any] else { return false }
        for (key, value) in saved where value is NSNumber { table[key] = value }
        CFPreferencesSetValue(tableKey, table as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
