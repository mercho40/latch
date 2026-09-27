import UIKit

/// The application delegate `main.swift` names. Everything with a window lives in the
/// scene: this only says which delegate class each new scene gets.
public final class LatchAppDelegate: UIResponder, UIApplicationDelegate {
    public func application(_ application: UIApplication,
                            configurationForConnecting connectingSceneSession: UISceneSession,
                            options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = LatchSceneDelegate.self
        return configuration
    }
}
