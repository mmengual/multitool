import AppKit
import Combine
import Sparkle

/// Who may receive the read token embedded in the app, when there is one.
///
/// The appcast lives on the `releases` branch of the repo, served by
/// raw.githubusercontent.com. Each version is a release asset, served by
/// api.github.com, which redirects to a signed storage URL. A public repo needs
/// no token. For a private one, the token goes to these two hosts only: an
/// appcast pointing elsewhere never gets it.
enum UpdateAccess {
    static let allowedHosts: Set<String> = ["raw.githubusercontent.com", "api.github.com"]

    /// Read-only token, written into Info.plist (`MTUpdateToken`) by
    /// scripts/build-app.sh. `MULTITOOL_UPDATE_TOKEN` overrides it for tests.
    static var token: String? {
        let env = ProcessInfo.processInfo.environment["MULTITOOL_UPDATE_TOKEN"]
        let plist = Bundle.main.object(forInfoDictionaryKey: "MTUpdateToken") as? String
        let value = (env ?? plist)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
    }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    static func headers() -> [String: String] {
        guard let token, isAllowed(feedURL) else { return [:] }
        return ["Authorization": "Bearer \(token)", "X-GitHub-Api-Version": "2022-11-28"]
    }
}

/// Sparkle, wired to the private GitHub repo.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var startError: String?
    @Published var automaticChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    @Published var automaticDownloads = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticDownloads }
    }

    /// No feed or no key: the app never contacts any server. The token is
    /// only needed while the repo is private.
    var isConfigured: Bool {
        UpdateAccess.feedURL != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    func start() {
        guard isConfigured else {
            startError = "Ce build n'embarque pas la configuration des mises à jour."
            Log.updates.info("updates disabled: missing feed or key")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: self,
                                                      userDriverDelegate: nil)
        let updater = controller.updater
        // Headers must be set before the first check, which can start right away.
        updater.httpHeaders = UpdateAccess.headers()
        do {
            try updater.start()
        } catch {
            startError = error.localizedDescription
            Log.updates.error("updater start failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.controller = controller
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = value }
            },
        ]
    }

    /// Check with Sparkle's windows.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Check without any window; an update found is downloaded and installed
    /// when the app quits. Used by the `--update-in-background` dev flag.
    func checkInBackground() {
        controller?.updater.automaticallyDownloadsUpdates = true
        controller?.updater.checkForUpdatesInBackground()
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
                             with request: NSMutableURLRequest) {
        if UpdateAccess.isAllowed(request.url) {
            // Without this, the API answers with the asset's JSON instead of the file.
            if request.url?.host?.lowercased() == "api.github.com" {
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            }
        } else {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.updates.error("update aborted: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Log.updates.info("appcast loaded: \(appcast.items.count) item(s)")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.updates.info("no update found")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.updates.info("update found: \(item.displayVersionString, privacy: .public)")
    }
}
