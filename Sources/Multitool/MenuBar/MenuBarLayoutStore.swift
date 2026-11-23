import AppKit

/// macOS 27's own table of menu bar positions:
/// `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`,
/// key `TrailingItemPreferredPositions`.
///
/// One entry per icon: `status:<bundleID or process name>::<name>` or `module:<name>`
/// for a system icon. The value is a weight that grows from right to left (clock 0):
/// the order of the weights is the order on screen (measured on 23/11, macOS 27.2).
/// Read and written through the preferences service, never the file itself.
///
/// MenuBarAgent applies a write only once a status item of the writing process is
/// laid out again: `MenuBarArranger` changes the chevron's length after each write.
enum MenuBarLayoutStore {
    static let directory = NSHomeDirectory() + "/Library/Group Containers/com.apple.MenuBar/Library/Preferences"
    private static let domain = (directory + "/com.apple.MenuBar") as CFString
    private static let tableKey = "TrailingItemPreferredPositions" as CFString
    private static let bookmarkKey = "menuBar.layoutBookmark"

    private static let lock = NSLock()
    private static var scopedURL: URL?

    // MARK: Access

    /// True when the table can be read: Full Disk Access, or a folder the user picked.
    static var hasAccess: Bool { read() != nil }

    /// Takes back the access to a folder picked on an earlier launch. Any thread.
    static func resumeAccess() {
        lock.lock(); defer { lock.unlock() }
        guard scopedURL == nil, let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
    }

    /// Asks the user to pick the preferences folder of the menu bar. Not proven to be
    /// enough for the preferences service: the caller checks `hasAccess` afterwards.
    @MainActor
    static func requestAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: directory)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = "Accès à la disposition de la barre des menus"
        panel.message = "Choisissez le dossier « Preferences » proposé, sans rien changer, puis cliquez sur Autoriser."
        panel.prompt = "Autoriser"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        lock.lock()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        lock.unlock()
        let ok = hasAccess
        Log.menuBar.info("layout access after the panel: \(ok)")
        return ok
    }

    @MainActor
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Read and write

    /// The whole table, nil without access.
    static func read() -> [String: Double]? {
        resumeAccess()
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let raw = CFPreferencesCopyValue(tableKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String: Any] else { return nil }
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Changes only `weights` in the table. False without access or if the read-back differs.
    static func write(_ weights: [String: Double]) -> Bool {
        resumeAccess()
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard var raw = CFPreferencesCopyValue(tableKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String: Any] else { return false }
        backupOnce(raw)
        for (key, weight) in weights { raw[key] = weight }
        CFPreferencesSetValue(tableKey, raw as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
        let after = read() ?? [:]
        return weights.allSatisfy { after[$0.key] == $0.value }
    }

    // MARK: Backup

    static var backupURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Multitool/menubar-layout-origin.plist")
    }

    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    /// The very first table seen before Multitool wrote anything. Never overwritten.
    private static func backupOnce(_ raw: [String: Any]) {
        guard !hasBackup else { return }
        try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        (raw as NSDictionary).write(to: backupURL, atomically: true)
        Log.menuBar.info("layout table backed up")
    }

    /// Writes the original weights back. The entries created since are left alone.
    static func restoreBackup() -> Bool {
        guard let saved = NSDictionary(contentsOf: backupURL) as? [String: Any] else { return false }
        return write(saved.compactMapValues { ($0 as? NSNumber)?.doubleValue })
    }

    // MARK: Keys

    /// Owner part of a `status:` key: "status:notion.id::Item-0" gives "notion.id".
    static func owner(of key: String) -> String? {
        guard key.hasPrefix("status:"), let range = key.range(of: "::") else { return nil }
        return String(key[key.index(key.startIndex, offsetBy: 7)..<range.lowerBound])
    }

    /// `module:` entries of the system icons whose Accessibility identifier is known.
    static let moduleKeys: [String: String] = [
        "com.apple.menuextra.wifi": "module:WiFi",
        "com.apple.menuextra.battery": "module:Battery",
        "com.apple.menuextra.clock": "module:Clock",
        "com.apple.menuextra.controlcenter": "module:BentoBox-0",
        "com.apple.menuextra.bluetooth": "module:Bluetooth",
        "com.apple.menuextra.sound": "module:Sound",
        "com.apple.menuextra.focusmode": "module:FocusModes",
        "com.apple.menuextra.nowplaying": "module:NowPlaying",
        "com.apple.menuextra.userswitcher": "module:UserSwitcher",
        "com.apple.menuextra.audiovideo": "module:AudioVideoModule",
    ]

    /// Pure. Pairs each icon with its table entry. `items` in screen order, left to right.
    /// An app with as many entries as icons is paired by rank (highest weight leftmost).
    /// With more entries than icons (stale ones), an entry is kept only if it is the
    /// single one whose weight fits between the weights of the paired neighbours.
    static func match(items: [(id: String, owners: [String], axIdentifier: String)],
                      table: [String: Double]) -> [String: [String]] {
        var result: [String: String] = [:]
        var byOwner: [String: [String]] = [:]
        for key in table.keys {
            if let owner = owner(of: key) { byOwner[owner, default: []].append(key) }
        }
        // Rank among the icons of the same owner, left to right.
        var groups: [String: [Int]] = [:]
        var ownerOf: [Int: String] = [:]
        for (i, item) in items.enumerated() {
            if let key = moduleKeys[item.axIdentifier], table[key] != nil { result[item.id] = key; continue }
            guard let owner = item.owners.first(where: { byOwner[$0] != nil }) else { continue }
            ownerOf[i] = owner
            groups[owner, default: []].append(i)
        }
        var pending: [String] = []
        var used: Set<String> = []
        for (owner, indexes) in groups {
            let keys = (byOwner[owner] ?? []).filter { !$0.hasSuffix("::" + MenuBarChevron.autosaveName) }
                .sorted { (table[$0] ?? 0) > (table[$1] ?? 0) }
            if keys.count == indexes.count {
                for (rank, i) in indexes.enumerated() { result[items[i].id] = keys[rank] }
            } else {
                pending.append(owner)
            }
        }
        for owner in pending {
            let keys = (byOwner[owner] ?? []).filter { !$0.hasSuffix("::" + MenuBarChevron.autosaveName) }
            for i in groups[owner] ?? [] {
                // Nearest paired neighbours: weights decrease from left to right.
                let left = items[..<i].last { result[$0.id] != nil }.flatMap { table[result[$0.id]!] } ?? .infinity
                let right = items[(i + 1)...].first { result[$0.id] != nil }.flatMap { table[result[$0.id]!] } ?? -.infinity
                let fitting = keys.filter { key in
                    guard let w = table[key] else { return false }
                    return w <= left && w >= right
                }
                if fitting.count == 1, used.insert(fitting[0]).inserted { result[items[i].id] = fitting[0] }
            }
        }
        var all = result.mapValues { [$0] }
        // Ambiguous single icon: every entry of its app. Writing a stale entry has no effect.
        for owner in pending where groups[owner]?.count == 1 {
            let i = groups[owner]![0]
            if all[items[i].id] == nil {
                all[items[i].id] = (byOwner[owner] ?? []).filter { !$0.hasSuffix("::" + MenuBarChevron.autosaveName) }
            }
        }
        return all
    }
}
