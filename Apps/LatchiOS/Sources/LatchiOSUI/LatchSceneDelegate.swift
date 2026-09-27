import LatchSessionKit
import UIKit

/// Builds the window and everything behind it: servers in the Keychain, one connector every
/// session reaches its server through, and the saved sessions. Hands the root any `latch://`
/// link the system opens the app with.
final class LatchSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?
    private var library: SessionLibrary?
    private let serverSheets = ServerSheets()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if DEBUG
        // `--ui-fixture <screen>`: made-up servers and sessions, for screenshots.
        if let screen = UIFixture.requestedScreen {
            let root = UIFixture.root(for: screen)
            root.serverDelegate = serverSheets
            show(root, in: windowScene)
            UIFixture.present(screen, in: root)
            return
        }
        #endif
        let directory = AppFiles.directory
        let servers = KeychainServerStore(directory: directory, vault: DeviceTokenVault.make(directory: directory))
        let connector = ChannelRemoteSessionConnector(servers: servers)
        let library = SessionLibrary(servers: servers, connector: connector, store: SessionStore(directory: directory))
        let badge = ApprovalBadge()
        let root = RootViewController(library: library, servers: servers, check: ServerCheckText.live, badge: badge)
        root.serverDelegate = serverSheets
        let window = show(root, in: windowScene)
        self.root = root
        self.library = library
        // A link that launched the app arrives here, not in `scene(_:openURLContexts:)`.
        root.open(connectionOptions.urlContexts.map(\.url))
        Task {
            await library.restore()
            root.restoreSelection()
            badge.sync(library.approvalsNeeded)
        }
        if LaunchSmoke.isRequested { LaunchSmoke.run(in: window) }
    }

    @discardableResult
    private func show(_ root: RootViewController, in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.tintColor = LatchPalette.tint
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        root?.open(URLContexts.map(\.url))
    }

    /// Suspension may have dropped every connection: each channel is probed, and the runtimes
    /// on each server listed afresh.
    func sceneDidBecomeActive(_ scene: UIScene) {
        library?.didBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        library?.isActive = false
    }

    /// Saves before the system suspends the app. Nothing is detached or stopped: the agents
    /// run on, and the next activation re-attaches from where each session had got to.
    func sceneDidEnterBackground(_ scene: UIScene) {
        guard let library else { return }
        let background = BackgroundTask(name: "Save sessions")
        Task {
            await library.flush()
            background.end()
        }
    }
}

/// A stretch of work the system lets finish after the app leaves the foreground.
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
