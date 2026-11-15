import Foundation

/// Network traffic per process. macOS has no public API for it, but `nettop`
/// reads it without privileges. Its continuous mode busy-waits (more than one
/// core), so it is run once per sample instead (about 20 ms), and the rates are
/// the difference between two runs. Only used while the monitor window is open.
final class NetworkSampler: @unchecked Sendable {
    private var previous: (time: Date, bytes: [Int32: (UInt64, UInt64)])?
    private let lock = NSLock()

    func reset() { lock.withLock { previous = nil } }

    /// Bytes per second received and sent by each pid since the previous call.
    func sample() -> [Int32: (inRate: Double, outRate: Double)] {
        guard let output = run() else { return [:] }
        let now = Date()
        var bytes: [Int32: (UInt64, UInt64)] = [:]
        for line in output.split(separator: "\n") where !line.hasPrefix(",") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let received = UInt64(fields[1]), let sent = UInt64(fields[2]) else { continue }
            let current = bytes[pid] ?? (0, 0)
            bytes[pid] = (current.0 + received, current.1 + sent)
        }

        return lock.withLock {
            defer { previous = (now, bytes) }
            guard let previous else { return [:] }
            let elapsed = now.timeIntervalSince(previous.time)
            guard elapsed > 0 else { return [:] }
            var rates: [Int32: (inRate: Double, outRate: Double)] = [:]
            for (pid, total) in bytes {
                guard let before = previous.bytes[pid] else { continue }
                let received = total.0 >= before.0 ? Double(total.0 - before.0) : 0
                let sent = total.1 >= before.1 ? Double(total.1 - before.1) : 0
                if received > 0 || sent > 0 { rates[pid] = (received / elapsed, sent / elapsed) }
            }
            return rates
        }
    }

    private func run() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.monitor.error("nettop failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
