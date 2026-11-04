import AppKit
import Combine

/// Tracks whether the frontmost application is a game.
final class GameDetector: ObservableObject {
    static let shared = GameDetector()

    @Published private(set) var inGame: Bool = false
    @Published private(set) var gameName: String? = nil

    private var observer: NSObjectProtocol?

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.refresh(frontmost: app)
        }
        refresh(frontmost: NSWorkspace.shared.frontmostApplication)
    }

    private func refresh(frontmost app: NSRunningApplication?) {
        let game = app.map(Self.isGame) ?? false
        let name = game ? app?.localizedName : nil
        if inGame != game || gameName != name {
            Log.game.info("frontmost=\(app?.bundleIdentifier ?? "?", privacy: .public) inGame=\(game)")
            inGame = game
            gameName = name
        }
    }

    private static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }

        // Steam installs (native or through a Wine wrapper's prefix).
        if url.path.lowercased().contains("/steamapps/") { return true }

        guard let info = Bundle(url: url)?.infoDictionary else { return false }
        // App Store category: public.app-category.games, .action-games, ...
        if let category = info["LSApplicationCategoryType"] as? String,
           category.hasSuffix("games") {
            return true
        }
        // Apps that opt in to macOS Game Mode.
        for key in ["LSSupportsGameMode", "GCSupportsGameMode"] {
            if info[key] as? Bool == true { return true }
        }
        return false
    }
}
