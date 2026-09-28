import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class RootNavigationTests: XCTestCase {
    private let vps = Fake.server("vps")

    private func hosted() -> (RootViewController, SessionLibrary, UIWindow) {
        let store = InMemoryServerStore([vps])
        let library = SessionLibrary(servers: store, connector: FakeConnector(), store: nil, listRuntimes: { _ in [] })
        let root = RootViewController(library: library, servers: store, check: { _ in throw LatchRemoteClientError.timedOut },
                                      badge: nil, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        return (root, library, window)
    }

    func testShowingASessionPutsItsScreenInTheSecondaryColumnAndOpensIt() async throws {
        let (root, library, window) = hosted()
        defer { window.isHidden = true }
        let session = library.create(serverID: vps.id, path: "/srv", agent: .fx)
        session.hasUnseenReply = true
        root.show(session)
        XCTAssertTrue(root.shown?.session === session)
        XCTAssertTrue(root.shown?.controller is SessionDetailViewController)
        XCTAssertEqual(library.selectedSessionID, session.id)
        XCTAssertFalse(session.hasUnseenReply)
        window.layoutIfNeeded()
        try await eventually("the screen on screen") {
            root.isShowing(session.id) && root.shown?.controller.transitionCoordinator == nil
        }
        XCTAssertTrue(library.isSessionVisible(session.id), "The library asks the root")

        // Removed, its screen goes with it.
        await library.remove(session)
        XCTAssertNil(root.shown)
        XCTAssertFalse(root.isShowing(session.id))
    }

    /// Removing the session while its screen is still being pushed waits for the push.
    func testRemovingASessionMidPushIsSafe() async throws {
        let (root, library, window) = hosted()
        defer { window.isHidden = true }
        let session = library.create(serverID: vps.id, path: "/srv", agent: .fx)
        root.show(session)
        await library.remove(session)
        try await eventually("the placeholder back") { root.shown == nil }
        XCTAssertTrue(root.viewController(for: .secondary) === root.placeholder)
    }

    func testTheFactoryMakesTheSessionScreen() {
        let store = InMemoryServerStore([vps])
        let library = SessionLibrary(servers: store, connector: FakeConnector(), store: nil, listRuntimes: { _ in [] })
        var made: [UUID] = []
        let root = RootViewController(library: library, servers: store, check: { _ in throw CancellationError() }, badge: nil,
                                      makeSessionViewController: { session, _ in
                                          made.append(session.id)
                                          return UIViewController()
                                      })
        let session = library.create(serverID: vps.id, path: "/srv", agent: .fx)
        root.show(session)
        root.show(session)
        XCTAssertEqual(made, [session.id], "Showing the same session again keeps its screen")
    }

    func testPreviousAndNextFollowTheListsOrder() {
        let (root, library, window) = hosted()
        defer { window.isHidden = true }
        let first = library.create(serverID: vps.id, path: "/a", agent: .fx)
        let second = library.create(serverID: vps.id, path: "/b", agent: .fx)
        let ordered = library.orderedSessions
        XCTAssertEqual(Set(ordered.map(\.id)), [first.id, second.id])
        root.nextSessionCommand()
        XCTAssertTrue(root.shown?.session === ordered[0])
        root.nextSessionCommand()
        XCTAssertTrue(root.shown?.session === ordered[1])
        root.nextSessionCommand()
        XCTAssertTrue(root.shown?.session === ordered[0], "Wraps around")
        root.previousSessionCommand()
        XCTAssertTrue(root.shown?.session === ordered[1])
    }

    func testKeyCommands() {
        let root = RootViewController()
        let commands = (root.keyCommands ?? []).map { ($0.input ?? "", $0.modifierFlags, $0.title) }
        XCTAssertEqual(commands.map(\.0), ["n", ",", "[", "]"])
        XCTAssertTrue(commands.allSatisfy { $0.1 == .command })
        XCTAssertEqual(commands.map(\.2), ["New Session", "Servers", "Previous Session", "Next Session"])
    }

    func testNewSessionWithoutAServerAsksToAddOne() {
        let root = RootViewController()
        let delegate = AddServerCounter()
        root.serverDelegate = delegate
        XCTAssertNil(root.newSessionSheet())
        root.presentNewSession()
        XCTAssertEqual(delegate.requests, 1)
    }

    func testAnAttentionBannerOpensTheSessionAndSaysWhatHappened() async throws {
        let (root, library, window) = hosted()
        defer { window.isHidden = true }
        let session = library.create(serverID: vps.id, path: "/srv", agent: .fx)
        library.onAttention?(session, .needsApproval)
        let banner = try XCTUnwrap(root.attentionBanner)
        XCTAssertEqual(banner.titleLabel.text, "New Session")
        XCTAssertEqual(banner.messageLabel.text, "The agent is waiting for a permission decision.")
        XCTAssertEqual(banner.accessibilityLabel, "New Session. The agent is waiting for a permission decision.")
        XCTAssertTrue(banner.accessibilityTraits.contains(.button))
        banner.onTap?()
        XCTAssertTrue(root.shown?.session === session)
        XCTAssertNil(root.attentionBanner)
    }

    // MARK: The badge

    func testTheBadgeAsksForPermissionOnlyWhenThereIsSomethingToCount() async {
        var asked = 0
        var applied: [Int] = []
        let badge = ApprovalBadge(authorize: { asked += 1; return true }, apply: { applied.append($0) })
        badge.update(0)
        await badge.settled()
        XCTAssertEqual(asked, 0, "Never at launch, and never for zero")
        badge.update(2)
        await badge.settled()
        badge.update(0)
        await badge.settled()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(applied, [2, 0])
    }

    /// The system's question never covers a request on screen: it waits for one the user
    /// cannot see.
    func testTheBadgeWaitsToAskUntilARequestIsOffScreen() async {
        var asked = 0
        var applied: [Int] = []
        let badge = ApprovalBadge(authorize: { asked += 1; return true }, apply: { applied.append($0) })
        badge.update(1, mayAsk: false)
        await badge.settled()
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(applied, [])
        badge.update(2, mayAsk: true)
        await badge.settled()
        badge.update(1, mayAsk: false)
        await badge.settled()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(applied, [2, 1], "Once allowed, the badge follows whatever is on screen")
    }

    /// A badge left by a run that ended while a session waited is cleared at the next launch
    /// where badges are allowed, and nothing is asked for.
    func testALaunchSetsTheBadgeRightWithoutAsking() async {
        var asked = 0
        var applied: [Int] = []
        let allowed = ApprovalBadge(authorize: { asked += 1; return true }, apply: { applied.append($0) }, current: { true })
        allowed.sync(0)
        await allowed.settled()
        XCTAssertEqual(applied, [0])
        let unasked = ApprovalBadge(authorize: { asked += 1; return true }, apply: { applied.append($0) }, current: { nil })
        unasked.sync(0)
        await unasked.settled()
        XCTAssertEqual(applied, [0], "Never asked, so there is no badge to clear")
        XCTAssertEqual(asked, 0)
    }

    func testARefusedBadgeIsNotAskedForAgain() async {
        var asked = 0
        var applied: [Int] = []
        let badge = ApprovalBadge(authorize: { asked += 1; return false }, apply: { applied.append($0) })
        badge.update(1)
        await badge.settled()
        badge.update(2)
        await badge.settled()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(applied, [])
    }
}

@MainActor
private final class AddServerCounter: RootViewControllerDelegate {
    var requests = 0
    func rootViewControllerDidRequestAddServer(_ root: RootViewController) { requests += 1 }
    func rootViewController(_ root: RootViewController,
                            didOpenPairingLink link: Result<LatchRemotePairing, LatchRemotePairingError>) {}
}
