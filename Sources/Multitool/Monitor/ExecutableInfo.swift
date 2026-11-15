import AppKit
import Security
import MultitoolShared

/// Who a process belongs to, from its executable path: the app that contains
/// it, its signer, and whether something about it deserves a look.
struct ExecutableInfo {
    /// Groups processes: the outermost .app containing the executable, or the
    /// executable itself.
    let groupKey: String
    let displayName: String
    let appPath: String?
    let signer: Signer
    /// Why this executable looks unusual, nil when it doesn't.
    let suspicion: String?

    /// The owner app's identity for grouping, keeping this executable's own
    /// signer and suspicion.
    func asGroup(keeping own: ExecutableInfo) -> ExecutableInfo {
        ExecutableInfo(groupKey: groupKey, displayName: displayName, appPath: appPath,
                       signer: signer, suspicion: own.suspicion)
    }

    enum Signer: Equatable {
        case apple
        case developer(String)   // "Google LLC (EQHXZ8M8AV)"
        case adHoc
        case unsigned
        case unknown             // not readable without privileges

        var label: String {
            switch self {
            case .apple: return "Apple"
            case .developer(let name): return name
            case .adHoc: return "Signature locale (ad hoc)"
            case .unsigned: return "Non signé"
            case .unknown: return "Inconnu"
            }
        }
    }
}

/// Resolves and caches `ExecutableInfo` by path. Signing information is read
/// from the file once per path, without validating the whole bundle.
final class ExecutableCatalog: @unchecked Sendable {
    static let shared = ExecutableCatalog()

    private var cache: [String: ExecutableInfo] = [:]
    private var icons: [String: NSImage] = [:]
    private let lock = NSLock()

    func info(path: String?, name: String) -> ExecutableInfo {
        guard let path, !path.isEmpty else {
            return ExecutableInfo(groupKey: "name:\(name)", displayName: name, appPath: nil,
                                  signer: .unknown, suspicion: nil)
        }
        if let cached = lock.withLock({ cache[path] }) { return cached }
        let info = resolve(path: path, name: name)
        lock.withLock { cache[path] = info }
        return info
    }

    private var webApps: [String: ExecutableInfo] = [:]

    /// Like `info(path:name:)`, but a Safari web app (one shared "Web App"
    /// runtime) gets the name and icon of the app added to the Dock, read from
    /// its `--bundlepath` launch argument.
    func info(for sample: ProcessSample) -> ExecutableInfo {
        let base = info(path: sample.path, name: sample.name)
        guard base.appPath?.hasSuffix("/Web App.app") == true else { return base }
        if let cached = lock.withLock({ webApps[sample.key] }) { return cached }
        var resolved = base
        let arguments = Self.arguments(of: sample.pid)
        if let index = arguments.firstIndex(of: "--bundlepath"), arguments.indices.contains(index + 1) {
            let bundle = arguments[index + 1]
            resolved = ExecutableInfo(groupKey: bundle, displayName: Self.appName(bundle), appPath: bundle,
                                      signer: base.signer, suspicion: nil)
        }
        lock.withLock { webApps[sample.key] = resolved }
        return resolved
    }

    /// Launch arguments of a process (sysctl KERN_PROCARGS2), readable for the
    /// user's own processes.
    private static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        // Layout: argc, executable path, padding NULs, then argc arguments.
        let strings = buffer[4..<size].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return Array(strings.dropFirst().prefix(argc))
    }

    @MainActor
    func icon(for info: ExecutableInfo) -> NSImage {
        let key = info.appPath ?? "generic"
        if let icon = icons[key] { return icon }
        let icon = info.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        icons[key] = icon
        return icon
    }

    private func resolve(path: String, name: String) -> ExecutableInfo {
        let appPath = Self.outermostApp(in: path)
        let displayName: String
        if let appPath {
            displayName = Self.appName(appPath)
        } else {
            displayName = Self.toolName(path: path, name: name)
        }
        let signer = Self.signer(of: path)
        return ExecutableInfo(groupKey: appPath ?? "path:\(path)", displayName: displayName,
                              appPath: appPath, signer: signer,
                              suspicion: Self.suspicion(path: path, signer: signer))
    }

    private static func outermostApp(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Command-line tools installed as versioned files
    /// (~/.local/share/claude/versions/2.1.323) get the tool's folder name.
    private static func toolName(path: String, name: String) -> String {
        let file = (path as NSString).lastPathComponent
        guard file.allSatisfy({ $0.isNumber || $0 == "." }), file.contains(".") else { return name }
        let components = (path as NSString).pathComponents.dropLast()
        let tool = components.reversed().first { !["versions", "bin", "libexec", "current"].contains($0) } ?? name
        return "\(tool) \(file)"
    }

    private static func appName(_ appPath: String) -> String {
        let bundle = Bundle(path: appPath)
        let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleName"] as? String
        return name ?? FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
    }

    private static func signer(of path: String) -> ExecutableInfo.Signer {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return .unknown }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess, let info = information as? [String: Any] else { return .unknown }

        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & 0x0002 != 0 { return .adHoc } // kSecCodeSignatureAdhoc
        // Binaries shipped with macOS carry a platform identifier.
        if info[kSecCodeInfoPlatformIdentifier as String] != nil { return .apple }
        if let identifier = info[kSecCodeInfoIdentifier as String] as? String,
           info[kSecCodeInfoTeamIdentifier as String] == nil,
           identifier.hasPrefix("com.apple.") {
            return .apple
        }
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            // "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC (EQHXZ8M8AV)"
            let name = summary.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            if summary.hasPrefix("Software Signing") || summary.hasPrefix("Apple ") && name.isEmpty { return .apple }
            return .developer(name.isEmpty ? summary : name)
        }
        return .unknown
    }

    /// Places where developer tools legitimately run unsigned or ad hoc binaries.
    private static let developerPlaces = [
        "/opt/homebrew/", "/usr/local/", "/.vscode/", "/.cursor/", "/.nvm/", "/.cargo/", "/.rustup/",
        "/node_modules/", "/DerivedData/", "/.build/", "/.local/", "/go/bin/", "/.pyenv/", "/.bun/",
        "/Library/Developer/", "/.docker/", "/.orbstack/",
    ]
    private static let temporaryPlaces = ["/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"]

    private static func suspicion(path: String, signer: ExecutableInfo.Signer) -> String? {
        if !FileManager.default.fileExists(atPath: path) {
            return "L'exécutable a été supprimé alors que le processus tourne encore."
        }
        if temporaryPlaces.contains(where: path.hasPrefix), !path.contains("/com.apple.") {
            return "Lancé depuis un dossier temporaire."
        }
        let downloads = NSHomeDirectory() + "/Downloads/"
        if path.hasPrefix(downloads) {
            return "Lancé directement depuis le dossier Téléchargements."
        }
        if signer == .unsigned || signer == .adHoc,
           !developerPlaces.contains(where: path.contains),
           !path.hasPrefix(NSHomeDirectory() + "/dev/") {
            return signer == .unsigned ? "Exécutable non signé." : "Signé localement, sans éditeur identifié."
        }
        return nil
    }
}
