import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class SessionsListTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: The status slot

    func testTheStatusSlotFollowsTheMacSidebarsRules() {
        func slot(_ change: (inout SessionRowStatus.Input) -> Void) -> SessionRowStatus {
            var input = SessionRowStatus.Input(lastActiveAt: now.addingTimeInterval(-300))
            change(&input)
            return SessionRowStatus.make(input, now: now)
        }
        XCTAssertEqual(slot { _ in }, SessionRowStatus(mark: .none, text: "5m", spoken: "Active 5 minutes ago"))
        XCTAssertEqual(slot { $0.phase = .ready }.text, "5m")
        XCTAssertEqual(slot { $0.phase = .ready; $0.hasUnseenReply = true }.mark, .unread)
        XCTAssertEqual(slot { $0.hasUnseenReply = true }.mark, .none, "Unread only means something for a live session")
        XCTAssertEqual(slot { $0.phase = .prompting; $0.status = "Working…"; $0.promptStartedAt = now.addingTimeInterval(-72) },
                       SessionRowStatus(mark: .working, text: "1m 12s", spoken: "Working, 1m 12s"))
        XCTAssertEqual(slot { $0.phase = .prompting; $0.status = "Cancelling…" }.text, "Cancelling…")
        XCTAssertEqual(slot { $0.phase = .connecting; $0.status = "Resuming…" },
                       SessionRowStatus(mark: .working, text: "Resuming…", spoken: "Resuming…"))
        // A decision outranks everything, a lost link outranks an old error.
        XCTAssertEqual(slot { $0.phase = .prompting; $0.needsApproval = true; $0.hasError = true }.mark, .waiting)
        XCTAssertEqual(slot { $0.phase = .prompting; $0.linkState = .reconnecting(server: "vps", since: now); $0.hasError = true },
                       SessionRowStatus(mark: .working, text: "Reconnecting…", spoken: "Reconnecting…"))
        XCTAssertEqual(slot { $0.phase = .connecting; $0.linkState = .reconnecting(server: "vps", since: now) }.text,
                       "Connecting…")
        XCTAssertEqual(slot { $0.linkState = .reconnecting(server: "vps", since: now) }.text, "5m",
                       "A disconnected session is not waiting for its link")
        XCTAssertEqual(slot { $0.hasError = true; $0.status = "Not connected"; $0.connectionFailure = true },
                       SessionRowStatus(mark: .failed, text: "Can’t connect", spoken: "Can’t connect"))
        XCTAssertEqual(slot { $0.hasError = true; $0.status = "Saved · Resume failed"; $0.connectionFailure = true }.text,
                       "Can’t connect")
        XCTAssertEqual(slot { $0.hasError = true; $0.status = "Not connected" }.text, "Couldn’t start",
                       "The server answered; the agent did not start")
        XCTAssertEqual(slot { $0.hasError = true; $0.status = "Stopped on vps"; $0.stoppedOnServer = true }.text, "Stopped")
        XCTAssertEqual(slot { $0.hasError = true; $0.status = "Agent exited (1)" }.text, "Stopped")
        XCTAssertEqual(slot { $0.hasError = true; $0.status = "Sign-in required" },
                       SessionRowStatus(mark: .failed, text: "Sign-in required", spoken: "Sign-in required"))
        XCTAssertEqual(slot { $0.stoppedHere = true }.text, "Stopped")
        XCTAssertEqual(slot { $0.stoppedHere = true; $0.hasError = true; $0.status = "Not connected" }.text, "Stopped",
                       "Stopping here outranks the failure before it")
        XCTAssertEqual(slot { $0.lastActiveAt = nil }.text, "")
    }

    // MARK: Sections

    private func makeList(servers: [ServerProfile], listing: @escaping RuntimeListing = { _ in [] })
        -> (SessionsViewController, SessionLibrary, FakeConnector) {
        let connector = FakeConnector()
        let library = SessionLibrary(servers: InMemoryServerStore(servers), connector: connector, store: nil,
                                     listRuntimes: listing)
        let list = SessionsViewController(library: library, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        library.onChange = { [weak list] in list?.reload() }
        return (list, library, connector)
    }

    private func session(_ library: SessionLibrary, _ connector: FakeConnector, on server: ServerProfile, title: String,
                         minutesAgo: Double, runtime: String? = nil) -> PhoneSession {
        let saved = SavedSession(id: UUID(), workspacePath: "/srv/\(title.lowercased())", title: title, agentID: "codex",
                                 customCommand: "", draft: "", messages: [], lastActiveAt: now.addingTimeInterval(-60 * minutesAgo),
                                 serverID: server.id, remote: runtime.map { SavedSession.RemoteBinding(runtimeID: $0, cursor: 0) })
        let session = PhoneSession(saved: saved, connector: connector)
        library.add(session)
        return session
    }

    func testOneSectionPerServerNewestFirstAndRemovedServersLast() {
        let vps = Fake.server("vps")
        let mini = Fake.server("mini")
        let (list, library, connector) = makeList(servers: [vps, mini])
        let old = session(library, connector, on: vps, title: "Old", minutesAgo: 90)
        let recent = session(library, connector, on: vps, title: "Recent", minutesAgo: 2)
        let orphan = session(library, connector, on: Fake.server("gone"), title: "Orphan", minutesAgo: 5)
        list.loadViewIfNeeded()
        let snapshot = list.dataSource.snapshot()
        XCTAssertEqual(snapshot.sectionIdentifiers, [.server(vps.id), .server(mini.id), .removedServer])
        XCTAssertEqual(snapshot.itemIdentifiers(inSection: .server(vps.id)), [.session(recent.id), .session(old.id)])
        XCTAssertEqual(snapshot.itemIdentifiers(inSection: .server(mini.id)), [.newSession(serverID: mini.id)],
                       "A server with nothing on it offers a session")
        XCTAssertEqual(snapshot.itemIdentifiers(inSection: .removedServer), [.session(orphan.id)])
        XCTAssertNil(list.contentUnavailableConfiguration)
        XCTAssertEqual(library.orderedSessions.map(\.id), [recent.id, old.id, orphan.id])
    }

    func testRuntimesOnAServerAreAGroupAndAFailureIsSaid() async throws {
        let vps = Fake.server("vps")
        let mini = Fake.server("mini")
        let (list, library, _) = makeList(servers: [vps, mini]) { options in
            guard options.host == vps.host else { throw LatchRemoteClientError.timedOut }
            return [Fake.summary("a", workspace: "/srv/a"), Fake.summary("b", workspace: "/srv/b", approvals: 1)]
        }
        list.loadViewIfNeeded()
        await library.refreshRuntimes()
        let group = SessionsViewController.Item.runtimes(serverID: vps.id)
        var section = list.dataSource.snapshot(for: .server(vps.id))
        XCTAssertEqual(section.rootItems, [SessionsViewController.Item.newSession(serverID: vps.id), group])
        XCTAssertEqual(section.snapshot(of: group, includingParent: false).items,
                       [SessionsViewController.Item.runtime(serverID: vps.id, runtimeID: "a"),
                        .runtime(serverID: vps.id, runtimeID: "b")])
        XCTAssertFalse(section.isExpanded(group), "Collapsed until asked")
        XCTAssertEqual(list.dataSource.snapshot(for: .server(mini.id)).rootItems,
                       [SessionsViewController.Item.newSession(serverID: mini.id), .unreachable(serverID: mini.id)])

        // Expanded, it stays so across a reload.
        list.collectionView(list.collectionView, didSelectItemAt: try XCTUnwrap(list.dataSource.indexPath(for: group)))
        list.reload(animated: false)
        section = list.dataSource.snapshot(for: .server(vps.id))
        XCTAssertTrue(section.isExpanded(group))
    }

    func testTappingARuntimeAdoptsItAndOpensTheSession() async throws {
        let vps = Fake.server("vps")
        let (list, library, connector) = makeList(servers: [vps]) { _ in [Fake.summary("theirs", workspace: "/srv/a")] }
        connector.prepare = { $0.serve(record: FakeClient.record(agent: .preset("fx"), workspace: "/srv/a"), backlog: []) }
        var opened: [PhoneSession] = []
        list.onOpen = { opened.append($0) }
        list.loadViewIfNeeded()
        await library.refreshRuntimes()
        var section = list.dataSource.snapshot(for: .server(vps.id))
        section.expand([.runtimes(serverID: vps.id)])
        await list.dataSource.apply(section, to: .server(vps.id), animatingDifferences: false)
        let row = try XCTUnwrap(list.dataSource.indexPath(for: .runtime(serverID: vps.id, runtimeID: "theirs")))
        list.collectionView(list.collectionView, didSelectItemAt: row)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(library.sessions.map(\.id), opened.map(\.id))
        await opened[0].settled()
        XCTAssertEqual(connector.clients.last?.snapshot.attaches.map(\.0), ["theirs"])
        let items = list.dataSource.snapshot().itemIdentifiers
        XCTAssertFalse(items.contains(.runtime(serverID: vps.id, runtimeID: "theirs")), "Taken up, it leaves the group")
        XCTAssertFalse(items.contains(.runtimes(serverID: vps.id)))
    }

    /// A decision is orange, as on the Mac, apart from the tint an unread reply and every
    /// control use; its words are the label's colour.
    func testADecisionStandsApartFromTheTint() {
        XCTAssertEqual(SessionStatusView.mark(for: .waiting)?.color, .systemOrange)
        XCTAssertEqual(SessionStatusView.mark(for: .unread)?.color, .tintColor)
        XCTAssertEqual(SessionStatusView.mark(for: .failed)?.color, .systemRed)
        let slot = SessionStatusView(status: SessionRowStatus(mark: .waiting, text: "Needs approval", spoken: "Needs approval"))
        XCTAssertEqual(slot.label.textColor, .label)
    }

    func testVoiceOverActionsReachTheDecisionAndSayWhatRemoveRemoves() {
        let vps = Fake.server("vps")
        let (list, library, connector) = makeList(servers: [vps])
        let waiting = session(library, connector, on: vps, title: "Waiting", minutesAgo: 1)
        waiting.stubbedStatus = SessionRowStatus.Input(phase: .prompting, needsApproval: true)
        var opened: [UUID] = []
        list.onOpen = { opened.append($0.id) }
        let actions = list.customActions(for: waiting)
        XCTAssertEqual(actions.map(\.name), ["Review Request…", "Remove from \(UIDevice.current.model)"])
        _ = actions[0].actionHandler?(actions[0])
        XCTAssertEqual(opened, [waiting.id])
    }

    func testEmptyStatesExplainPairingThenOfferANewSession() {
        let (empty, _, _) = makeList(servers: [])
        empty.loadViewIfNeeded()
        let pairing = empty.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        XCTAssertEqual(pairing?.text, "No servers yet")
        XCTAssertEqual(pairing?.button.title, "Add Server")

        let (list, _, _) = makeList(servers: [Fake.server("vps")])
        var newSessions = 0
        list.onNewSession = { _ in newSessions += 1 }
        list.loadViewIfNeeded()
        let offer = list.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        XCTAssertEqual(offer?.text, "No sessions yet")
        XCTAssertNil(offer?.button.title, "The server's section offers New Session; the page only explains")
    }

    func testRemoveExplainsOnceThatTheAgentKeepsRunning() async throws {
        let vps = Fake.server("vps")
        let (list, library, connector) = makeList(servers: [vps])
        let first = session(library, connector, on: vps, title: "First", minutesAgo: 1, runtime: "r1")
        let second = session(library, connector, on: vps, title: "Second", minutesAgo: 2, runtime: "r2")
        var asked: [SessionsViewController.Confirmation] = []
        list.confirm = { confirmation, go in
            asked.append(confirmation)
            go()
        }
        list.loadViewIfNeeded()
        list.remove(first)
        try await eventually("the first removal") { library.sessions.count == 1 }
        list.remove(second)
        try await eventually("the second removal") { library.sessions.isEmpty }
        XCTAssertEqual(asked, [.remove(sessionTitle: "First", serverName: "vps", agentRuns: true)])
    }

    /// With its agent stopped, nothing on the server keeps the conversation, so removing it
    /// always asks, and says so.
    func testRemovingAStoppedSessionAlwaysAsks() async throws {
        let vps = Fake.server("vps")
        let (list, library, connector) = makeList(servers: [vps])
        let running = session(library, connector, on: vps, title: "Running", minutesAgo: 1, runtime: "r1")
        let stopped = session(library, connector, on: vps, title: "Stopped", minutesAgo: 2)
        var asked: [SessionsViewController.Confirmation] = []
        list.confirm = { confirmation, go in
            asked.append(confirmation)
            go()
        }
        list.loadViewIfNeeded()
        list.remove(running)
        try await eventually("the first removal") { library.sessions.count == 1 }
        XCTAssertTrue(list.remove(stopped), "Asked, though removal was explained already")
        try await eventually("the second removal") { library.sessions.isEmpty }
        XCTAssertEqual(asked, [.remove(sessionTitle: "Running", serverName: "vps", agentRuns: true),
                               .remove(sessionTitle: "Stopped", serverName: "vps", agentRuns: false)])
    }

    func testStopAlwaysAsks() async throws {
        let vps = Fake.server("vps")
        let (list, library, _) = makeList(servers: [vps])
        let session = library.create(serverID: vps.id, path: "/srv", agent: .fx)
        await session.settled()
        var asked: [SessionsViewController.Confirmation] = []
        list.confirm = { confirmation, _ in asked.append(confirmation) }
        list.stop(session)
        XCTAssertEqual(asked, [.stop(agentTitle: "fx", serverName: "vps")])
        XCTAssertEqual(session.model.phase, .ready, "Nothing stops until confirmed")
    }
}
