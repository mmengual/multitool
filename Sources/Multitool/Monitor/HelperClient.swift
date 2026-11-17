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
    /// After a connection error, the limited reading is used for a while. An
    /// outdated helper that nobody calls exits after 5 minutes, and launchd then
    /// starts the new binary.
    private var retryAfter: Date?

    /// SMAppService.status asks a system daemon and can be slow: read it off the
    /// main thread, then publish.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let status = SMAppService.daemon(plistName: HelperIdentity.plistName).status
            await MainActor.run {
                self.apply(status)
                self.refreshing = false
            }
        }
    }

    private var refreshing = false

    private func apply(_ status: SMAppService.Status) {
        switch status {
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
        apply(service.status)
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
        apply(service.status)
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// One snapshot from the helper, or nil when it isn't available.
    nonisolated func snapshot() async -> ProcessSnapshot? {
        guard let connection = await connect() else { return nil }
        return await withCheckedContinuation { continuation in
            let once = Once()
            // On a connection error, fall back to the limited reading at once.
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Log.monitor.error("helper XPC error: \(error.localizedDescription, privacy: .public)")
                once.run { continuation.resume(returning: nil) }
                // 4102: the helper failed the signing check, typically an old binary
                // whose file an update replaced. It exits once nobody calls it.
                let signing = (error as NSError).code == 4102
                Task { @MainActor in self.backOff(seconds: signing ? 360 : 10) }
            } as? MonitorHelperProtocol
            guard let proxy else { once.run { continuation.resume(returning: nil) }; return }
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

    private func backOff(seconds: TimeInterval) {
        retryAfter = Date().addingTimeInterval(seconds)
        connection?.invalidate()
        connection = nil
        checkedIdentity = false
    }

    private func connect() -> NSXPCConnection? {
        guard state == .enabled else { return nil }
        if let retryAfter, Date() < retryAfter { return nil }
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
        if !checkedIdentity, let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? MonitorHelperProtocol {
            checkedIdentity = true
            checkIdentity(proxy)
        }
        return connection
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
