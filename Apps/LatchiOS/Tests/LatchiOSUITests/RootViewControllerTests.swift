import LatchRemoteProtocol
import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class RootViewControllerTests: XCTestCase {
    private let token = LatchRemoteToken.generate()

    func testTheSessionsListIsThePrimaryColumnAndOffersAddServer() throws {
        let root = RootViewController()
        XCTAssertEqual(root.style, .doubleColumn)
        XCTAssertTrue(root.viewController(for: .primary) === root.sessions)
        XCTAssertTrue(root.viewController(for: .secondary) === root.placeholder)
        // One explanation of pairing, with one Add Server: in the session column while there
        // is one beside the list, and in the list when it is all there is.
        root.placeholder.loadViewIfNeeded()
        let empty = try XCTUnwrap(root.placeholder.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)
        XCTAssertEqual(empty.text, "No Servers")
        XCTAssertEqual(empty.button.title, "Scan Pairing Code")
        XCTAssertEqual(empty.secondaryButton.title, "Add Manually")
        XCTAssertNotNil(empty.buttonProperties.primaryAction)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        root.sessions.reload(animated: false)
        let list = root.sessions.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        if root.isCollapsed {
            XCTAssertEqual(list?.text, "No Servers")
        } else {
            XCTAssertNil(list, "The sidebar leaves it to the column beside it")
        }
    }

    func testNoSessionSelectedExplainsAndOffersNewSession() throws {
        let placeholder = SessionPlaceholderViewController()
        var newSessions = 0
        placeholder.onNewSession = { newSessions += 1 }
        placeholder.loadViewIfNeeded()
        let configuration = try XCTUnwrap(placeholder.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)
        XCTAssertEqual(configuration.text, "No Session Selected")
        XCTAssertEqual(configuration.secondaryText, "Choose a session, or start one on a server.")
        XCTAssertNotNil(configuration.image)
        XCTAssertEqual(configuration.button.title, "New Session")
        configuration.buttonProperties.primaryAction?.performWithSender(nil, target: nil)
        XCTAssertEqual(newSessions, 1)
    }

    /// Collapsed, the stack starts at the list rather than an empty session.
    func testCollapsingShowsTheSessionsList() {
        let root = RootViewController()
        XCTAssertEqual(root.splitViewController(root, topColumnForCollapsingToProposedTopColumn: .secondary), .primary)
    }

    func testAddServerAsksTheDelegate() {
        let root = RootViewController()
        let delegate = Delegate()
        root.serverDelegate = delegate
        root.sessions.addServer()
        XCTAssertEqual(delegate.addServerRequests, 1)
        XCTAssertTrue(delegate.links.isEmpty)
    }

    /// A code scanned in Latch is a link opened from the Camera app: the delegate confirms it
    /// in Add Server, or offers to update the server it already has.
    func testScanPairingCodeOpensTheScannerWhoseCodeReachesTheDelegate() throws {
        let root = RootViewController()
        let delegate = Delegate()
        root.serverDelegate = delegate
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        root.sessions.scanPairingCode()
        let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
        let scanner = try XCTUnwrap(navigation.topViewController as? PairingScannerViewController)
        XCTAssertEqual(scanner.title, "Scan Pairing Code")
        XCTAssertTrue(delegate.links.isEmpty, "Opening the scanner reads nothing")
        let pairing = try LatchRemotePairing(host: "vps.example", token: token)
        // Called as the scanner does once it has gone, which never happens in the test host.
        scanner.onScan?(pairing)
        XCTAssertEqual(delegate.links, [.success(pairing)])
        XCTAssertEqual(delegate.addServerRequests, 0)
    }

    func testAPairingLinkReachesTheDelegate() throws {
        let root = RootViewController()
        let delegate = Delegate()
        root.serverDelegate = delegate
        root.open([try XCTUnwrap(URL(string: "latch://vps.example:7800?token=\(token.rawValue)"))])
        XCTAssertEqual(delegate.links, [.success(try LatchRemotePairing(host: "vps.example", port: 7800, token: token))])
    }

    /// A link that launched the app can arrive before anything is listening for it.
    func testALinkWaitsForTheDelegateAndIsDeliveredOnce() throws {
        let root = RootViewController()
        root.open([try XCTUnwrap(URL(string: "latch://vps.example?token=\(token.rawValue)"))])
        let delegate = Delegate()
        root.serverDelegate = delegate
        XCTAssertEqual(delegate.links.count, 1)
        root.serverDelegate = delegate
        XCTAssertEqual(delegate.links.count, 1)
    }

    /// One server at a time is confirmed, and other schemes are not Latch's to handle.
    func testOnlyTheFirstLatchLinkIsForwarded() throws {
        let root = RootViewController()
        let delegate = Delegate()
        root.serverDelegate = delegate
        root.open([try XCTUnwrap(URL(string: "https://example.com")),
                   try XCTUnwrap(URL(string: "latch://first?token=\(token.rawValue)")),
                   try XCTUnwrap(URL(string: "latch://second?token=\(token.rawValue)"))])
        XCTAssertEqual(delegate.links, [.success(try LatchRemotePairing(host: "first", token: token))])
        root.open([try XCTUnwrap(URL(string: "https://example.com"))])
        XCTAssertEqual(delegate.links.count, 1)
    }

    func testPairingLinksParseOrSayWhyNot() throws {
        XCTAssertNil(PairingLink.parse(try XCTUnwrap(URL(string: "https://vps.example"))))
        XCTAssertEqual(PairingLink.parse(try XCTUnwrap(URL(string: "LATCH://[::1]:9000?token=\(token.rawValue)"))),
                       .success(try LatchRemotePairing(host: "::1", port: 9000, token: token)))
        XCTAssertEqual(PairingLink.parse(try XCTUnwrap(URL(string: "latch://vps.example"))), .failure(.missingToken))
        XCTAssertEqual(PairingLink.parse(try XCTUnwrap(URL(string: "latch://vps.example?token=latch_short"))),
                       .failure(.invalidToken))
        XCTAssertEqual(PairingLink.parse(try XCTUnwrap(URL(string: "latch://vps.example:0?token=\(token.rawValue)"))),
                       .failure(.invalidPort))
    }

    func testTheTintHasContrastInBothAppearances() {
        let light = LatchPalette.tint.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = LatchPalette.tint.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertGreaterThanOrEqual(contrast(light, .white), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(dark, .black), 4.5)
    }

    private func contrast(_ lhs: UIColor, _ rhs: UIColor) -> CGFloat {
        let (a, b) = (luminance(lhs), luminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// WCAG relative luminance, from the colour's extended sRGB components.
    private func luminance(_ color: UIColor) -> CGFloat {
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

@MainActor
private final class Delegate: RootViewControllerDelegate {
    var addServerRequests = 0
    var links: [Result<LatchRemotePairing, LatchRemotePairingError>] = []

    func rootViewControllerDidRequestAddServer(_ root: RootViewController) { addServerRequests += 1 }

    func rootViewController(_ root: RootViewController,
                            didOpenPairingLink link: Result<LatchRemotePairing, LatchRemotePairingError>) {
        links.append(link)
    }
}
