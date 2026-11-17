import Foundation

/// Logs when the main thread stops answering for more than a second, with how
/// long it lasted: the interface freezes for that long. Costs one wake-up every
/// half second on a background thread.
enum HangWatchdog {
    static func start() {
        let thread = Thread {
            var blockedSince: Date?
            while true {
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 1) == .timedOut {
                    if blockedSince == nil {
                        blockedSince = Date()
                        Log.app.error("main thread blocked for more than 1 s")
                    }
                    answered.wait()
                }
                if let since = blockedSince {
                    Log.app.error("main thread was blocked for \(Date().timeIntervalSince(since) + 1, format: .fixed(precision: 1)) s")
                    blockedSince = nil
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "HangWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
