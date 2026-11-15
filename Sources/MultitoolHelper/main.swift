import Darwin
import Foundation
import MultitoolShared
import os.log

// Multitool's privileged helper. launchd starts it as root on demand, when the
// app connects to its Mach service. It only reads process counters and answers
// nothing to a client that isn't Multitool signed with the same team.

private let log = Logger(subsystem: "com.mmengual.multitool", category: "Helper")

final class HelperService: NSObject, MonitorHelperProtocol {
    func identity(reply: @escaping (Int, Double) -> Void) {
        reply(HelperIdentity.protocolVersion, Self.executableDate)
    }

    func snapshot(reply: @escaping (Data) -> Void) {
        Activity.touch()
        let data = (try? JSONEncoder().encode(ProcessSampler.snapshot())) ?? Data()
        reply(data)
    }

    func exitForUpdate() {
        log.info("exit requested after an update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }

    static let executableDate: Double = {
        // launchd passes a relative argv[0] (BundleProgram): ask the kernel for the real path.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return 0 }
        let path = String(cString: buffer)
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return date?.timeIntervalSince1970 ?? 0
    }()
}

/// Exits after a few idle minutes: launchd starts the helper again on the next
/// request, so it costs nothing while the monitor is closed.
enum Activity {
    private static var last = Date()
    static func touch() { DispatchQueue.main.async { last = Date() } }
    static func startIdleTimer() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            if Date().timeIntervalSince(last) > 300 {
                log.info("idle, exiting")
                exit(0)
            }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MonitorHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        Activity.touch()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
// Rejects any client that doesn't satisfy the requirement, before the delegate sees it.
listener.setConnectionCodeSigningRequirement(HelperIdentity.clientRequirement)
listener.delegate = delegate
listener.resume()
Activity.startIdleTimer()
log.info("helper started, uid=\(getuid())")
RunLoop.main.run()
