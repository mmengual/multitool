import Foundation

// MultitoolVisibility: reads and writes macOS 27's per-app menu bar switches
// (System Settings > Menu Bar), for the Menu Bar module.
//
//   MultitoolVisibility list
//   MultitoolVisibility set <bundleID>=on|off [<bundleID>=on|off …]
//
// The switches live in the preferences domain `group.com.apple.controlcenter`, key
// `trackedApplications`: a binary plist holding a Swift dictionary as an alternating
// array (key with `bundle`, then value with `isAllowed`). MenuBarAgent applies a
// change at once when it is written through the preferences service under that
// domain, which takes the app-group entitlement this executable is signed with
// (Developer ID). It is a separate executable so the app keeps its own signature:
// if macOS ever refuses the entitlement, only this tool stops, not Multitool.
//
// Output: one JSON object. `list`: {"apps": {bundleID: allowed}}. `set`: the same
// after the write, plus "written" and "othersChanged" (macOS rewrote other entries
// between our read and our read-back). Exit 2: the list can't be read.

let domain = "group.com.apple.controlcenter" as CFString
let key = "trackedApplications" as CFString

/// The raw array. Elements this tool doesn't understand are kept as they are.
func read() -> [Any]? {
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    guard let data = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data
    else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any]
}

func bundleID(_ entry: Any) -> String? { ((entry as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String }
func isAllowed(_ entry: Any) -> Bool? { (entry as? [String: Any])?["isAllowed"] as? Bool }

/// Apple's own apps and system items are never switched by this tool.
func switchable(_ id: String) -> Bool { !id.hasPrefix("com.apple.") }

/// bundle ID → allowed, for the entries keyed by a bundle that carry the switch.
func switches(_ list: [Any]) -> [String: Bool] {
    var result: [String: Bool] = [:]
    for i in stride(from: 0, to: list.count - 1, by: 2) {
        if let id = bundleID(list[i]), let allowed = isAllowed(list[i + 1]) { result[id] = allowed }
    }
    return result
}

func emit(_ object: [String: Any], code: Int32 = 0) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["list", "set"].contains(command) else {
    emit(["error": "usage: list | set <bundleID>=on|off …"], code: 64)
}
guard var list = read() else { emit(["error": "list unreadable"], code: 2) }
let before = switches(list)
if command == "list" { emit(["apps": before]) }

var wanted: [String: Bool] = [:]
for pair in arguments.dropFirst() {
    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2, ["on", "off"].contains(parts[1]), switchable(parts[0]) else {
        emit(["error": "bad argument \(pair)"], code: 64)
    }
    wanted[parts[0]] = parts[1] == "on"
}
var changed = false
for i in stride(from: 0, to: list.count - 1, by: 2) {
    // Only an entry that already carries the switch is changed.
    guard let id = bundleID(list[i]), let allowed = wanted[id], var entry = list[i + 1] as? [String: Any],
          let current = entry["isAllowed"] as? Bool, current != allowed else { continue }
    entry["isAllowed"] = allowed
    list[i + 1] = entry
    changed = true
}
var written = true
if changed {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else {
        emit(["error": "list not serializable"], code: 1)
    }
    CFPreferencesSetValue(key, data as CFData, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    written = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    if !written { emit(["error": "write refused", "apps": before], code: 3) }
}
let after = read().map(switches) ?? [:]
// Entries we didn't ask to change: did macOS rewrite the list meanwhile?
let othersChanged = before.contains { wanted[$0.key] == nil && after[$0.key] != $0.value }
emit(["apps": after, "written": written, "othersChanged": othersChanged])
