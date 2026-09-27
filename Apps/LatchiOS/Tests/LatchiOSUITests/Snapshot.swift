import UIKit
import XCTest
@testable import LatchiOSUI

/// Hosts a view controller in a window the size of the device running the tests, with the
/// appearance and text size forced, and renders it to a PNG for design review. Nothing is
/// compared: the images are for looking at, and are written only when `LATCH_SNAPSHOTS` is
/// set, so ordinary runs stay fast. Windows are drawn with their layer, where glass and blur
/// come out as their tint only; `--ui-fixture` screenshots of the running app show them.
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

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["LATCH_SNAPSHOTS"] != nil }

    /// For a snapshot test's `setUp`.
    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(isEnabled, "Set LATCH_SNAPSHOTS to render snapshots")
    }

    /// Where the images go: `LATCH_SNAPSHOT_DIR` when set, else `/tmp/latch-ios-<task>`.
    static func directory(task: String) -> URL {
        let path = ProcessInfo.processInfo.environment["LATCH_SNAPSHOT_DIR"] ?? "/tmp/latch-ios-\(task)"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    /// A key window the size of the screen, or of `size`, holding `controller` in a navigation
    /// controller unless it is one or `navigation` is false, with `appearance` forced on
    /// everything in it.
    static func host(_ controller: UIViewController, appearance: Appearance, navigation: Bool = true,
                     size: CGSize? = nil) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = CGRect(origin: .zero, size: size ?? scene?.screen.bounds.size ?? UIScreen.main.bounds.size)
        let root = navigation && !(controller is UINavigationController)
            ? UINavigationController(rootViewController: controller) : controller
        window.traitOverrides.preferredContentSizeCategory = appearance.size
        window.overrideUserInterfaceStyle = appearance.style
        window.tintColor = LatchPalette.tint
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// Lets layout, diffable updates and short tasks finish.
    static func settle(_ duration: Duration = .milliseconds(400)) async {
        try? await Task.sleep(for: duration)
    }

    static func render(_ window: UIWindow) -> UIImage {
        window.rootViewController.map(plainProminentItems)
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            UIColor.systemBackground.resolvedColor(with: window.traitCollection).setFill()
            context.fill(window.bounds)
            window.layer.render(in: context.cgContext)
        }
    }

    /// A prominent bar button's glass stops the layer drawing anything at all, so snapshots
    /// show those buttons plain. Only the button's fill differs from the app.
    private static func plainProminentItems(_ controller: UIViewController) {
        if #available(iOS 26.0, *) {
            for item in (controller.navigationItem.rightBarButtonItems ?? []) + (controller.navigationItem.leftBarButtonItems ?? [])
            where item.style == .prominent {
                item.style = .plain
            }
        }
        let navigation = (controller as? UINavigationController)?.viewControllers ?? []
        for child in controller.children + navigation { plainProminentItems(child) }
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
        return try save(render(window), task: task, name: name, appearance: appearance)
    }

    enum Sheet: Equatable {
        /// A page sheet at the medium or large detent, as on iPhone.
        case page(medium: Bool)
        /// A form sheet in the middle of the screen, as on iPad.
        case form
    }

    /// A sheet over `background` as it is presented, drawn rather than presented so the
    /// render is the same every time: the background dimmed, and the sheet drawn in its own
    /// window at the sheet's frame.
    @discardableResult
    static func writeSheet(_ sheet: UIViewController, over background: UIWindow, as kind: Sheet, task: String,
                           name: String, appearance: Appearance,
                           prepare: (UIViewController) async -> Void = { _ in }) async throws -> URL {
        let bounds = background.bounds
        let frame: CGRect = switch kind {
        case let .page(medium):
            medium ? CGRect(x: 0, y: bounds.height * 0.5, width: bounds.width, height: bounds.height * 0.5)
                : CGRect(x: 0, y: background.safeAreaInsets.top + 10, width: bounds.width,
                         height: bounds.height - background.safeAreaInsets.top - 10)
        case .form:
            CGRect(x: (bounds.width - 600) / 2, y: (bounds.height - 660) / 2, width: 600, height: 660)
        }
        let behind = render(background)
        // A sheet starts below the status bar, which a window of its size still makes room for.
        let insets = background.safeAreaInsets
        sheet.additionalSafeAreaInsets = UIEdgeInsets(top: -insets.top, left: 0,
                                                      bottom: kind == .page(medium: false) ? 0 : -insets.bottom, right: 0)
        let window = host(sheet, appearance: appearance, navigation: false, size: frame.size)
        await settle()
        await prepare(sheet)
        await settle()
        let front = render(window)
        let format = UIGraphicsImageRendererFormat(for: background.traitCollection)
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            behind.draw(in: bounds)
            UIColor.black.withAlphaComponent(appearance.style == .dark ? 0.48 : 0.2).setFill()
            context.fill(bounds, blendMode: .normal)
            let radius: CGFloat = kind == .form ? 24 : 36
            UIBezierPath(roundedRect: frame, byRoundingCorners: kind == .form ? .allCorners : [.topLeft, .topRight],
                         cornerRadii: CGSize(width: radius, height: radius)).addClip()
            front.draw(in: frame)
        }
        tearDown(window)
        return try save(image, task: task, name: name, appearance: appearance)
    }

    private static func save(_ image: UIImage, task: String, name: String, appearance: Appearance) throws -> URL {
        let directory = directory(task: task)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(deviceName)-\(appearance.name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

    static func tearDown(_ window: UIWindow) {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}
