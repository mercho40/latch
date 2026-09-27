import UIKit
import XCTest
@testable import LatchiOSUI

/// Renders a screen to a PNG for design review, at the size of the device the tests run on,
/// in a chosen appearance and text size. Tests run without an app host, so there is no window
/// scene: the window is a bare one, and it is drawn with its layer rather than
/// `drawHierarchy`, which draws nothing without a scene. Materials come out flat.
@MainActor
enum SnapshotB1 {
    static let directory = URL(fileURLWithPath: "/tmp/latch-ios-b1", isDirectory: true)

    struct Variant {
        let name: String
        let style: UIUserInterfaceStyle
        let category: UIContentSizeCategory

        static let light = Variant(name: "light", style: .light, category: .large)
        static let dark = Variant(name: "dark", style: .dark, category: .large)
        static let accessibility = Variant(name: "axxl", style: .light, category: .accessibilityExtraLarge)
    }

    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    /// A window the size of the screen, with the traits the variant asks for, showing `root`.
    static func window(_ root: UIViewController, variant: Variant, size: CGSize? = nil) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size ?? UIScreen.main.bounds.size))
        window.overrideUserInterfaceStyle = variant.style
        window.traitOverrides.preferredContentSizeCategory = variant.category
        window.tintColor = LatchPalette.tint
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    /// Lets layout, diffable updates and short tasks finish.
    static func settle(_ duration: Duration = .milliseconds(400)) async {
        try? await Task.sleep(for: duration)
    }

    enum Sheet: Equatable {
        /// A page sheet at the medium or large detent, as on iPhone.
        case page(medium: Bool)
        /// A form sheet in the middle of the screen, as on iPad.
        case form
    }

    /// A sheet over `background` as it is presented, since a bare window cannot present one:
    /// the background dimmed, and the sheet drawn in its own window at the sheet's frame.
    @discardableResult
    static func writeSheet(_ sheet: UIViewController, over background: UIWindow, as kind: Sheet, name: String,
                           variant: Variant, prepare: (UIViewController) async -> Void = { _ in }) async throws -> URL {
        let bounds = background.bounds
        let frame: CGRect = switch kind {
        case let .page(medium):
            medium ? CGRect(x: 0, y: bounds.height * 0.5, width: bounds.width, height: bounds.height * 0.5)
                : CGRect(x: 0, y: background.safeAreaInsets.top + 10, width: bounds.width,
                         height: bounds.height - background.safeAreaInsets.top - 10)
        case .form:
            CGRect(x: (bounds.width - 600) / 2, y: (bounds.height - 660) / 2, width: 600, height: 660)
        }
        let behind = SnapshotB1.render(background)
        // A sheet starts below the status bar, which a bare window of its size still makes room for.
        let insets = background.safeAreaInsets
        sheet.additionalSafeAreaInsets = UIEdgeInsets(top: -insets.top, left: 0,
                                                      bottom: kind == .page(medium: false) ? 0 : -insets.bottom, right: 0)
        let window = SnapshotB1.window(sheet, variant: variant, size: frame.size)
        await settle()
        await prepare(sheet)
        await settle()
        let front = SnapshotB1.render(window)
        let format = UIGraphicsImageRendererFormat(for: background.traitCollection)
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            behind.draw(in: bounds)
            UIColor.black.withAlphaComponent(variant.style == .dark ? 0.48 : 0.2).setFill()
            context.fill(bounds, blendMode: .normal)
            let radius: CGFloat = kind == .form ? 24 : 36
            UIBezierPath(roundedRect: frame, byRoundingCorners: kind == .form ? .allCorners : [.topLeft, .topRight],
                         cornerRadii: CGSize(width: radius, height: radius)).addClip()
            front.draw(in: frame)
        }
        window.isHidden = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(device)-\(variant.name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
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

    /// Writes `<name>-<device>-<variant>.png` and returns where.
    @discardableResult
    static func write(_ window: UIWindow, name: String, variant: Variant) throws -> URL {
        let image = SnapshotB1.render(window)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(device)-\(variant.name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }
}
