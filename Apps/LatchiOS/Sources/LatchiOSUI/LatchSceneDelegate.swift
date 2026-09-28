import LatchSessionKit
import UIKit

/// Builds the window and everything behind it: servers in the Keychain, one connector every
/// session reaches its server through, the saved sessions, and the session screen the root
/// shows each one in. Hands the root any `latch://` link the system opens the app with.
final class LatchSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?
    private var library: SessionLibrary?
    private let serverSheets = ServerSheets()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // The tests the app hosts make their own windows, over nothing of the app's: no saved
        // servers or sessions are read, and no server is reached.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            self.window = window
            return
        }
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
        let vault = KeychainTokenVault()
        vault.requireEntitlement()
        let servers = KeychainServerStore(directory: directory, vault: vault)
        #if DEBUG
        // The remote smoke never asks to badge the icon: the question is this device owner's.
        let remoteSmoke = RemoteSmoke.request
        let connector = remoteSmoke == nil ? ChannelRemoteSessionConnector(servers: servers)
            : ChannelRemoteSessionConnector(servers: servers, backoff: RemoteSmoke.backoff)
        let badge = remoteSmoke == nil ? ApprovalBadge() : nil
        #else
        let connector = ChannelRemoteSessionConnector(servers: servers)
        let badge: ApprovalBadge? = ApprovalBadge()
        #endif
        let memory = ServerMemory()
        // Each listing's handshake keeps the server's home, which paths on it are shown against.
        let listing = RemoteRuntimeList.live(welcomed: { options, welcome in
            await memory.recordHome(welcome.server.home, options: options)
        })
        let library = SessionLibrary(servers: servers, connector: connector, store: SessionStore(directory: directory),
                                     listRuntimes: listing)
        let root = RootViewController(library: library, servers: servers, check: ServerCheckText.live, badge: badge,
                                      memory: memory, makeSessionViewController: SessionDetailViewController.make)
        root.serverDelegate = serverSheets
        let window = show(root, in: windowScene)
        self.root = root
        self.library = library
        // A link that launched the app arrives here, not in `scene(_:openURLContexts:)`.
        root.open(connectionOptions.urlContexts.map(\.url))
        Task {
            await library.restore()
            root.restoreSelection()
            badge?.sync(library.approvalsNeeded)
        }
        if LaunchSmoke.isRequested { LaunchSmoke.run(in: window) }
        #if DEBUG
        switch remoteSmoke {
        case let .success(request)?:
            RemoteSmoke.run(request, window: window, scene: windowScene, delegate: self, root: root, servers: servers,
                            connector: connector)
        case let .failure(problem)?:
            FileHandle.standardError.write(Data("IOS SMOKE REMOTE: FAIL — \(problem)\n".utf8))
            exit(1)
        case nil:
            break
        }
        #endif
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
