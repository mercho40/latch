import Foundation
import UIKit

/// `--smoke-test`: waits for the root UI to come up in the real app, prints one
/// `IOS SMOKE:` line, and exits 0 on a pass or 1 on a failure. `Scripts/test-ios-app.sh`
/// launches it in the Simulator and reads the line from the console.
@MainActor
enum LaunchSmoke {
    static let argument = "--smoke-test"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func run(in window: UIWindow) {
        Task { @MainActor in
            // The scene activates and the columns lay out after `willConnectTo` returns.
            let deadline = ContinuousClock.now + .seconds(20)
            var problem = check(window)
            while problem != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                problem = check(window)
            }
            if let problem {
                FileHandle.standardError.write(Data("IOS SMOKE: root UI — FAIL: \(problem)\n".utf8))
                exit(1)
            }
            let traits = window.traitCollection
            let device = traits.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            let width = traits.horizontalSizeClass == .compact ? "compact" : "regular"
            FileHandle.standardOutput.write(Data(
                "IOS SMOKE: window, split view and sessions list up on \(device), \(width) width — PASS\n".utf8))
            exit(0)
        }
    }

    /// Why the root UI is not up yet, or `nil` once it is.
    static func check(_ window: UIWindow) -> String? {
        guard window.isKeyWindow, window.windowScene?.activationState == .foregroundActive else {
            return "the window is not key in an active scene"
        }
        guard let root = window.rootViewController as? RootViewController else {
            return "the root is not the split view"
        }
        guard root.sessions.viewIfLoaded?.window === window else {
            return "the sessions list is not on screen"
        }
        guard let empty = root.sessions.contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
              empty.text == "No servers yet", empty.buttonProperties.primaryAction != nil else {
            return "the sessions list has no Add Server empty state"
        }
        return nil
    }
}
