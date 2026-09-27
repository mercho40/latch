import UIKit

/// Builds the window and hands it any `latch://` link the system opens the app with.
final class LatchSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = RootViewController()
        window.rootViewController = root
        window.tintColor = LatchPalette.tint
        window.makeKeyAndVisible()
        self.window = window
        self.root = root
        // A link that launched the app arrives here, not in `scene(_:openURLContexts:)`.
        root.open(connectionOptions.urlContexts.map(\.url))
        if LaunchSmoke.isRequested { LaunchSmoke.run(in: window) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        root?.open(URLContexts.map(\.url))
    }
}
