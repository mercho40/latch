import UIKit
import XCTest
@testable import LatchiOSUI

/// Renders a view controller the way the device running the tests shows it, in a window of
/// the screen's size, with the appearance and text size forced, and writes it as a PNG for
/// design review. Nothing is compared: the images are for looking at.
@MainActor
enum Snapshot {
    struct Appearance {
        let name: String
        let style: UIUserInterfaceStyle
        let size: UIContentSizeCategory

        static let light = Appearance(name: "light", style: .light, size: .large)
        static let dark = Appearance(name: "dark", style: .dark, size: .large)
        static let accessibility = Appearance(name: "xl", style: .light, size: .accessibilityExtraLarge)
        static let all = [light, dark, accessibility]
        /// The largest accessibility size, for screens that must still work there.
        static let largest = Appearance(name: "ax5", style: .light, size: .accessibilityExtraExtraExtraLarge)
    }

    /// Where the images go: `LATCH_SNAPSHOT_DIR` when set, else `/tmp/latch-ios-<task>`.
    static func directory(task: String) -> URL {
        let path = ProcessInfo.processInfo.environment["LATCH_SNAPSHOT_DIR"] ?? "/tmp/latch-ios-\(task)"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    /// A key window the size of the screen, holding `controller` in a navigation
    /// controller unless it is one, with `appearance` forced on everything in it.
    static func host(_ controller: UIViewController, appearance: Appearance, navigation: Bool = true) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = scene?.screen.bounds ?? UIScreen.main.bounds
        let root = navigation && !(controller is UINavigationController)
            ? UINavigationController(rootViewController: controller) : controller
        root.traitOverrides.preferredContentSizeCategory = appearance.size
        window.overrideUserInterfaceStyle = appearance.style
        window.tintColor = LatchPalette.tint
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// Lets layout, self-sizing and presentations settle, then renders `window` to
    /// `<directory>/<name>-<device>-<appearance>.png`.
    @discardableResult
    static func write(_ window: UIWindow, task: String, name: String, appearance: Appearance,
                      settle: Duration = .milliseconds(400)) async throws -> URL {
        let deadline = ContinuousClock.now + settle
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        // The test host has no render server to draw through, so `drawHierarchy` comes back
        // blank; the layer tree renders in-process. Blurs and glass come out as their tint only.
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        let directory = directory(task: task)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(deviceName)-\(appearance.name).png")
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        return url
    }

    static func tearDown(_ window: UIWindow) {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}
