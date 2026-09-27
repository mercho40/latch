import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// The session screen as the root shows it: its context made from the session and kept
/// current, and each of its requests taken back to the session, the library or the root.
@MainActor
final class SessionScreenTests: XCTestCase {
    private let vps = Fake.server("vps")
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach(Snapshot.tearDown)
        windows = []
        try await super.tearDown()
    }

    private func hosted(_ connector: FakeConnector = FakeConnector())
        -> (RootViewController, SessionLibrary, InMemoryServerStore, FakeConnector) {
        let store = InMemoryServerStore([vps])
        let library = SessionLibrary(servers: store, connector: connector, store: nil, listRuntimes: { _ in [] })
        let root = RootViewController(library: library, servers: store, check: { _ in throw LatchRemoteClientError.timedOut },
                                      badge: nil, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        windows.append(Snapshot.host(root, appearance: .light, navigation: false))
        return (root, library, store, connector)
    }

    private func screen(_ root: RootViewController) throws -> SessionDetailViewController {
        try XCTUnwrap(root.shown?.controller as? SessionDetailViewController)
    }

    private func type(_ text: String, in screen: SessionDetailViewController) {
        screen.composer.textView.text = text
        screen.composer.textViewDidChange(screen.composer.textView)
    }

    func testTheScreenIsMadeFromTheSessionAndFollowsItsTitleAndItsServersName() async throws {
        let (root, library, store, connector) = hosted()
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .claudeCode)
        root.show(session)
        let screen = try screen(root)
        XCTAssertTrue(screen.model === session.model)
        XCTAssertEqual(screen.context.title, "New Session")
        XCTAssertEqual(screen.context.serverName, "vps")
        XCTAssertEqual(screen.context.folderPath, "/srv/app")
        XCTAssertEqual(screen.context.agentTitle, "Claude Code")

        try await eventually("the agent") { session.model.phase == .ready }
        type("Why is the build slow?", in: screen)
        screen.send()
        try await eventually("the turn") { connector.clients.first?.isRunningTurn == true }
        XCTAssertEqual(screen.context.title, "Why is the build slow?", "The first prompt titles the screen")
        XCTAssertEqual(screen.title, "Why is the build slow?")

        var renamed = vps
        renamed.name = "Build box"
        try store.save(renamed)
        XCTAssertEqual(screen.context.serverName, "Build box")
        connector.clients.first?.finishTurn()
    }

    func testTheDraftIsKeptWithTheSession() throws {
        let (root, library, _, _) = hosted()
        let session = library.create(serverID: vps.id, path: "/srv", agent: .fx)
        session.draft = "half a thought"
        root.show(session)
        let screen = try screen(root)
        XCTAssertEqual(screen.composer.text, "half a thought", "The composer starts from the saved draft")
        type("half a thought, finished", in: screen)
        XCTAssertEqual(session.draft, "half a thought, finished")
    }

    func testStopAgentStopsTheRuntimeThroughTheLibrary() async throws {
        let (root, library, _, connector) = hosted()
        let session = library.create(serverID: vps.id, path: "/srv", agent: .fx)
        root.show(session)
        let screen = try screen(root)
        try await eventually("the agent") { session.model.phase == .ready }
        let runtime = try XCTUnwrap(connector.clients.first?.snapshot.launched)
        screen.context.onStopAgent()
        try await eventually("the stop") { connector.clients.first?.snapshot.stops == [runtime.rawValue] }
        try await eventually("the row to say so") { session.rowStatus(now: Date()).text == "Stopped" }
    }

    func testRetryAdoptsAnAdoptionThatDidNotTakeAgain() async throws {
        let connector = FakeConnector()
        connector.prepare = { $0.failAttaches(with: UnreachableServer(message: "vps did not answer.")) }
        let (root, library, _, _) = hosted(connector)
        let session = library.adopt(Fake.summary("theirs", workspace: "/srv/a"), serverID: vps.id)
        root.show(session)
        let screen = try screen(root)
        await session.settled()
        XCTAssertNotNil(session.pendingAdoption)
        XCTAssertFalse(screen.context.canStopAgent?() ?? true, "Nothing to stop while the adoption has not taken")
        let attaches = try XCTUnwrap(connector.clients.first).snapshot.attaches.count
        screen.context.onRetry()
        await session.settled()
        XCTAssertGreaterThan(try XCTUnwrap(connector.clients.first).snapshot.attaches.count, attaches)
        XCTAssertEqual(connector.clients.first?.snapshot.launches.count, 0, "An adoption never launches an agent")
    }

    func testCollapsingKeepsTheOpenSessionOnTop() throws {
        let (root, library, _, _) = hosted()
        XCTAssertEqual(root.splitViewController(root, topColumnForCollapsingToProposedTopColumn: .primary), .primary)
        root.show(library.create(serverID: vps.id, path: "/srv", agent: .fx))
        XCTAssertEqual(root.splitViewController(root, topColumnForCollapsingToProposedTopColumn: .primary), .secondary)
    }

    /// Stop Agent's confirmation is answered first; on iPad it can go by a tap outside its
    /// popover, which runs no action, and the request still shows once it has gone.
    func testAPermissionRequestWaitsForAnAlertAndShowsOnceItHasGone() async throws {
        let fixture = SessionScreenFixture()
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.connect()
        let alert = UIAlertController(title: "Stop Claude Code on vps?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        fixture.screen.present(alert, animated: false)
        try await eventually("the alert") { fixture.screen.presentedViewController === alert && !alert.isBeingPresented }
        fixture.type("Clean the build folder")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        fixture.client.requestPermission(title: "rm -rf .build")
        await waitUntil("the request") { fixture.model.permissions.current != nil }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(fixture.presentedSheets.isEmpty, "Nothing is presented over an alert")
        alert.dismiss(animated: false)
        try await eventually("the sheet") { fixture.presentedSheets.count == 1 }
        fixture.client.endTurn()
    }
}
