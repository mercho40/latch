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
        root.sessions.loadViewIfNeeded()
        let empty = try XCTUnwrap(root.sessions.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)
        XCTAssertEqual(empty.text, "No servers yet")
        XCTAssertEqual(empty.button.title, "Add Server")
        XCTAssertNotNil(empty.buttonProperties.primaryAction)
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
