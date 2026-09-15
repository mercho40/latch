import AppKit
import UserNotifications
import XCTest
@testable import LatchMacUI

/// A session that needs a decision is only visible in one window at a time. Everything else
/// reaches the user through the Dock badge and a notification, and a decision taken there
/// travels back to the right request.
@MainActor
final class AttentionCenterTests: XCTestCase {
    private let sessionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let requestID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    func testPendingPermissionIsAnnouncedWithItsOptions() throws {
        let presenter = RecordingPresenter()
        let center = AttentionCenter(presenter: presenter)

        center.update([sessionID: waiting()])

        XCTAssertEqual(presenter.posts.count, 1)
        let post = try XCTUnwrap(presenter.posts.first)
        XCTAssertEqual(post.title, "Latch · workspace")
        XCTAssertEqual(post.body, "The agent is waiting for a permission decision.")
        XCTAssertEqual(post.actions, [AttentionAction(id: "allow:allow-1", title: "Allow Once", isDestructive: false),
                                       AttentionAction(id: "reject:reject-1", title: "Reject Once", isDestructive: true)])
        XCTAssertEqual(post.userInfo["session"], sessionID.uuidString)
        XCTAssertEqual(post.userInfo["request"], requestID.uuidString)
        XCTAssertEqual(center.badgeCount, 1)
    }

    func testNotificationBodyCarriesNoAgentSuppliedDetail() {
        let presenter = RecordingPresenter()
        let center = AttentionCenter(presenter: presenter)

        center.update([sessionID: waiting()])

        // Only the workspace folder identifies the session: no prompt-derived title, tool
        // name, or argument may reach a notification body.
        let text = presenter.posts.map { "\($0.title) \($0.body)" }.joined()
        XCTAssertFalse(text.contains("Saved title"))
        XCTAssertFalse(text.contains("allow-1"))
        XCTAssertEqual(center.badgeCount, 1)
    }

    func testAVisibleSessionIsCountedButNotAnnounced() {
        let presenter = RecordingPresenter()
        let center = AttentionCenter(presenter: presenter)
        center.isSessionVisible = { _ in true }

        center.update([sessionID: waiting()])

        XCTAssertTrue(presenter.posts.isEmpty, "The sheet is already on screen")
        XCTAssertEqual(center.badgeCount, 1, "The Dock still shows what is waiting")
    }

    func testResolvingWithdrawsTheNotificationAndClearsTheBadge() {
        let presenter = RecordingPresenter()
        let center = AttentionCenter(presenter: presenter)
        center.update([sessionID: waiting()])

        center.update([sessionID: AttentionCenter.State(workspaceName: "workspace")])

        XCTAssertEqual(presenter.withdrawn, ["permission.\(requestID.uuidString)"])
        XCTAssertEqual(center.badgeCount, 0)
    }

    func testFinishedTurnIsAnnouncedOnlyWhenOutOfSight() {
        let presenter = RecordingPresenter()
        let center = AttentionCenter(presenter: presenter)
        var visible = false
        center.isSessionVisible = { _ in visible }
        let prompting = AttentionCenter.State(workspaceName: "workspace", isPrompting: true)
        let idle = AttentionCenter.State(workspaceName: "workspace")

        center.update([sessionID: prompting])
        center.update([sessionID: idle])
        XCTAssertEqual(presenter.posts.map(\.body), ["The agent finished its turn."])

        visible = true
        center.update([sessionID: prompting])
        center.update([sessionID: idle])
        XCTAssertEqual(presenter.posts.count, 1, "A session you are looking at announces nothing")
    }

    func testClosedSessionTakesItsAlertsWithIt() {
        let presenter = RecordingPresenter()
        let center = AttentionCenter(presenter: presenter)
        center.update([sessionID: waiting()])

        center.clear()

        XCTAssertTrue(presenter.withdrawn.contains("permission.\(requestID.uuidString)"))
        XCTAssertTrue(presenter.withdrawn.contains("finished.\(sessionID.uuidString)"))
        XCTAssertEqual(center.badgeCount, 0)
    }

    func testDecidingFromTheNotificationResolvesThatRequest() {
        let presenter = RecordingPresenter()
        let center = AttentionCenter(presenter: presenter)
        var resolved: (UUID, UUID, String?)?
        var revealed: UUID?
        center.onResolvePermission = { resolved = ($0, $1, $2) }
        center.onReveal = { revealed = $0 }
        center.update([sessionID: waiting()])

        presenter.onAction?("allow:allow-1", ["session": sessionID.uuidString, "request": requestID.uuidString])

        XCTAssertEqual(resolved?.0, sessionID)
        XCTAssertEqual(resolved?.1, requestID)
        XCTAssertEqual(resolved?.2, "allow-1")
        XCTAssertNil(revealed)
    }

    func testClickingTheBodyOnlyRevealsTheSession() {
        let presenter = RecordingPresenter()
        let center = AttentionCenter(presenter: presenter)
        var resolved = false
        var revealed: UUID?
        center.onResolvePermission = { _, _, _ in resolved = true }
        center.onReveal = { revealed = $0 }
        center.update([sessionID: waiting()])

        // Default activation must never approve something the user has not read.
        presenter.onAction?(UNNotificationDefaultActionIdentifier,
                            ["session": sessionID.uuidString, "request": requestID.uuidString])

        XCTAssertFalse(resolved)
        XCTAssertEqual(revealed, sessionID)
    }

    private func waiting() -> AttentionCenter.State {
        AttentionCenter.State(workspaceName: "workspace", permission: requestID,
                              allowOptionID: "allow-1", rejectOptionID: "reject-1")
    }
}

/// Stands in for user notifications, which need a bundle identifier and would otherwise
/// ask this machine's user for authorization during a test run.
@MainActor
private final class RecordingPresenter: AttentionPresenting {
    struct Post: Equatable {
        let id: String
        let title: String
        let body: String
        let actions: [AttentionAction]
        let userInfo: [String: String]
    }

    var onAction: ((String, [String: String]) -> Void)?
    private(set) var posts: [Post] = []
    private(set) var withdrawn: [String] = []

    func post(id: String, title: String, body: String, actions: [AttentionAction], userInfo: [String: String]) {
        posts.append(Post(id: id, title: title, body: body, actions: actions, userInfo: userInfo))
    }

    func withdraw(id: String) { withdrawn.append(id) }
}
