import Foundation
import ServiceManagement
import MultitoolShared

/// Installs and talks to the read-only privileged helper.
///
/// The helper is a launchd daemon declared in the app bundle
/// (Contents/Library/LaunchDaemons) and registered with SMAppService. macOS
/// asks the user to allow it once, in System Settings → General → Login Items
/// & Extensions. Without it, the monitor reads only the user's processes.
@MainActor
final class HelperClient: ObservableObject {
    static let shared = HelperClient()

    enum State: Equatable {
        case notInstalled
        case needsApproval
        case enabled
        case unavailable(String)
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var lastError: String?

    private var service: SMAppService { SMAppService.daemon(plistName: HelperIdentity.plistName) }
    private var connection: NSXPCConnection?
    private var checkedIdentity = false
    /// One restart request per launch at most, so a mismatch can never loop.
    private var restartRequested = false

    func refresh() {
        switch service.status {
        case .enabled: state = .enabled
        case .requiresApproval: state = .needsApproval
        case .notRegistered: state = .notInstalled
        case .notFound:
            // Also what macOS answers for a daemon never registered yet.
            let plist = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperIdentity.plistName)")
            state = FileManager.default.fileExists(atPath: plist.path)
                ? .notInstalled
                : .unavailable("Service absent : lancer Multitool depuis l'app construite par scripts/build-app.sh.")
        @unknown default: state = .unavailable("État inconnu")
        }
    }

    func install() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.monitor.error("helper register failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() {
        connection?.invalidate()
        connection = nil
        do {
            try service.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// One snapshot from the helper, or nil when it isn't available.
    nonisolated func snapshot() async -> ProcessSnapshot? {
        guard let proxy = await proxy() else { return nil }
        return await withCheckedContinuation { continuation in
            let once = Once()
            proxy.snapshot { data in
                once.run { continuation.resume(returning: try? JSONDecoder().decode(ProcessSnapshot.self, from: data)) }
            }
            // A helper that doesn't answer must not freeze the monitor.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                once.run { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: - Connection

    private func proxy() -> MonitorHelperProtocol? {
        guard service.status == .enabled else { return nil }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: MonitorHelperProtocol.self)
            // Refuses to talk to anything but our own helper.
            connection.setCodeSigningRequirement(HelperIdentity.helperRequirement)
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil; self?.checkedIdentity = false }
            }
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.checkedIdentity = false }
            }
            connection.resume()
            self.connection = connection
        }
        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            Log.monitor.error("helper XPC error: \(error.localizedDescription, privacy: .public)")
        } as? MonitorHelperProtocol
        if !checkedIdentity, let proxy {
            checkedIdentity = true
            checkIdentity(proxy)
        }
        return proxy
    }

    /// After an update, the helper still running is the previous binary: ask it
    /// to exit so launchd starts the new one.
    private func checkIdentity(_ proxy: MonitorHelperProtocol) {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MultitoolHelper").path
        let bundledDate = ((try? FileManager.default.attributesOfItem(atPath: bundled)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        guard !restartRequested else { return }
        proxy.identity { version, date in
            if version != HelperIdentity.protocolVersion || abs(date - bundledDate) > 1 {
                Log.monitor.info("helper outdated (v\(version), \(date) vs \(bundledDate)), restarting it")
                Task { @MainActor in self.restartRequested = true }
                proxy.exitForUpdate()
                Task { @MainActor in self.connection?.invalidate() }
            }
        }
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
