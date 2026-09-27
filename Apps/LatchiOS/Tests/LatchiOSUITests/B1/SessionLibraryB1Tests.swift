import LatchAgentCore
import LatchServiceProtocol
import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class SessionLibraryTests: XCTestCase {
    private var directory: URL!
    private let vps = B1.server("vps")

    override func setUp() async throws {
        directory = try B1.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLibrary(_ connector: B1Connector, store: SessionStore? = nil,
                             listing: @escaping RuntimeListing = { _ in [] }) -> SessionLibrary {
        SessionLibrary(servers: InMemoryServerStore([vps]), connector: connector, store: store, listRuntimes: listing)
    }

    // MARK: Snapshots

    /// The fields the Mac's session saves, the same way: the first prompt names it.
    func testASessionSavesWhatTheMacSaves() async throws {
        let connector = B1Connector()
        let library = makeLibrary(connector)
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .claudeCode)
        await session.settled()
        XCTAssertEqual(session.model.phase, .ready)
        XCTAssertEqual(connector.clients.first?.snapshot.launches, [.remote(agent: .preset("claudeCode"), path: "/srv/app")])
        session.draft = "half a thought"
        let send = Task { await session.model.send("  Fix the flaky test  \nand explain why") }
        try await eventuallyB1("the turn to start") { connector.clients[0].isRunningTurn }
        XCTAssertEqual(session.title, "Fix the flaky test")

        let saved = session.savedSession
        XCTAssertEqual(saved.id, session.id)
        XCTAssertEqual(saved.workspacePath, "/srv/app")
        XCTAssertEqual(saved.title, "Fix the flaky test")
        XCTAssertEqual(saved.agentID, "claudeCode")
        XCTAssertEqual(saved.customCommand, "")
        XCTAssertEqual(saved.draft, "half a thought")
        XCTAssertEqual(saved.messages, session.model.messages)
        XCTAssertEqual(saved.agentSessionID, "session")
        XCTAssertEqual(saved.lastActiveAt, session.model.lastActiveAt)
        XCTAssertEqual(saved.serverID, vps.id)
        XCTAssertEqual(saved.remote, session.model.remoteBinding)
        XCTAssertNotNil(saved.remote, "A running turn's runtime is bound, so a relaunch attaches to it")
        connector.clients[0].finishTurn()
        await send.value
    }

    func testTitlesFollowTheMacRule() {
        XCTAssertEqual(PhoneSession.title(fromPrompt: ChatMessage(role: .user, text: "\n  first line  \nsecond")), "first line")
        XCTAssertEqual(PhoneSession.title(fromPrompt: ChatMessage(role: .user, text: "",
                                                                  attachments: [ChatAttachment(kind: .image, name: "shot.png", path: nil)])),
                       "shot.png")
        XCTAssertEqual(PhoneSession.title(fromPrompt: ChatMessage(role: .user, text: String(repeating: "a", count: 90)))?.count, 60)
        XCTAssertNil(PhoneSession.title(fromPrompt: ChatMessage(role: .user, text: "   ")))
    }

    func testACustomAgentRunsItsServersCommand() async {
        let server = B1.server("box", command: "mock-agent --acp")
        let connector = B1Connector()
        let library = SessionLibrary(servers: InMemoryServerStore([server]), connector: connector, store: nil,
                                     listRuntimes: { _ in [] })
        let session = library.create(serverID: server.id, path: "~", agent: .custom)
        await session.settled()
        XCTAssertEqual(session.customCommand, "mock-agent --acp")
        XCTAssertEqual(session.subtitle, "mock-agent · ~")
        XCTAssertEqual(connector.clients[0].snapshot.launches, [.remote(agent: .custom("mock-agent --acp"), path: "~")])
    }

    // MARK: Saving and restoring

    func testALibrarySavesAndRestoresAndReattachesBoundSessionsFirst() async throws {
        let store = SessionStore(directory: directory)
        let connector = B1Connector()
        let library = makeLibrary(connector, store: store)
        await library.restore()
        let bound = library.create(serverID: vps.id, path: "/srv/bound", agent: .codex)
        await bound.settled()
        let idle = library.create(serverID: vps.id, path: "/srv/idle", agent: .fx)
        await idle.settled()
        await idle.stop()
        library.open(bound)
        await library.flush()
        let written = try await store.load()
        XCTAssertEqual(written, library.savedLibrary)
        XCTAssertEqual(written.selectedSessionID, bound.id)
        let runtimeID = try XCTUnwrap(written.sessions.first { $0.id == bound.id }?.remote?.runtimeID)

        // A relaunch: the bound session attaches to its runtime before anything is opened;
        // the other waits to be opened.
        let relaunched = B1Connector()
        relaunched.prepare = { $0.serve(record: B1FakeClient.record(agent: .preset("codex"), workspace: "/srv/bound"), backlog: []) }
        let next = makeLibrary(relaunched, store: SessionStore(directory: directory))
        await next.restore()
        XCTAssertEqual(next.sessions.map(\.id), [bound.id, idle.id])
        XCTAssertEqual(next.selectedSessionID, bound.id)
        let restoredBound = try XCTUnwrap(next.session(id: bound.id))
        await restoredBound.settled()
        XCTAssertEqual(restoredBound.model.phase, .ready)
        let attaches = relaunched.clients.flatMap { $0.snapshot.attaches.map(\.0) }
        XCTAssertEqual(attaches, [runtimeID])
        XCTAssertEqual(next.session(id: idle.id)?.model.phase, .disconnected)
        XCTAssertEqual(next.session(id: idle.id)?.hasStarted, false)
        XCTAssertTrue(relaunched.clients.allSatisfy { $0.snapshot.launches.isEmpty }, "Restoring launches nothing")
    }

    /// Leaving the foreground writes at once; nothing is detached or stopped.
    func testFlushingSavesImmediatelyAndLeavesRuntimesRunning() async throws {
        let store = SessionStore(directory: directory)
        let connector = B1Connector()
        let library = makeLibrary(connector, store: store)
        await library.restore()
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .fx)
        await session.settled()
        session.draft = "typed just before leaving"
        await library.flush()
        let written = try await store.load()
        XCTAssertEqual(written.sessions.first?.draft, "typed just before leaving")
        XCTAssertEqual(session.model.phase, .ready)
        XCTAssertTrue(connector.clients[0].snapshot.detaches.isEmpty)
        XCTAssertTrue(connector.clients[0].snapshot.stops.isEmpty)
    }

    func testAnUnreadableLibraryIsNeverOverwritten() async throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent(SessionStore.fileName))
        let library = makeLibrary(B1Connector(), store: SessionStore(directory: directory))
        await library.restore()
        XCTAssertNotNil(library.persistenceError)
        library.create(serverID: vps.id, path: "/srv/app", agent: .fx)
        await library.flush()
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(SessionStore.fileName), encoding: .utf8), "not json")
    }

    // MARK: Attention

    func testAnOffScreenTurnLeavesAnUnreadMarkAndAsksForAttention() async throws {
        let connector = B1Connector()
        let library = makeLibrary(connector)
        var attention: [SessionLibrary.Attention] = []
        var counts: [Int] = []
        library.onAttention = { _, kind in attention.append(kind) }
        library.onApprovalCountChange = { counts.append($0) }
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .fx)
        await session.settled()
        let send = Task { await session.model.send("go") }
        try await eventuallyB1("the turn") { connector.clients[0].isRunningTurn }
        connector.clients[0].requestPermission()
        try await eventuallyB1("the request") { session.model.permissions.current != nil }
        XCTAssertEqual(attention, [.needsApproval])
        XCTAssertEqual(counts, [1])
        XCTAssertEqual(session.rowStatus(now: Date()).text, "Needs approval")
        let request = try XCTUnwrap(session.model.permissions.current)
        session.model.permissions.resolve(id: request.id, optionID: "allow")
        try await eventuallyB1("the badge to clear") { counts == [1, 0] }

        connector.clients[0].finishTurn()
        await send.value
        XCTAssertEqual(attention, [.needsApproval, .finished])
        XCTAssertTrue(session.hasUnseenReply)
        XCTAssertEqual(session.rowStatus(now: Date()).mark, .unread)
        library.open(session)
        XCTAssertFalse(session.hasUnseenReply)
    }

    func testTheSessionOnScreenIsNeitherMarkedNorAnnounced() async throws {
        let connector = B1Connector()
        let library = makeLibrary(connector)
        var attention: [SessionLibrary.Attention] = []
        library.onAttention = { _, kind in attention.append(kind) }
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .fx)
        library.isSessionVisible = { $0 == session.id }
        await session.settled()
        let send = Task { await session.model.send("go") }
        try await eventuallyB1("the turn") { connector.clients[0].isRunningTurn }
        connector.clients[0].finishTurn()
        await send.value
        XCTAssertEqual(attention, [])
        XCTAssertFalse(session.hasUnseenReply)
    }

    func testNothingIsAnnouncedWhileInactiveButTheMarkStays() async throws {
        let connector = B1Connector()
        let library = makeLibrary(connector)
        library.isActive = false
        var attention: [SessionLibrary.Attention] = []
        library.onAttention = { _, kind in attention.append(kind) }
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .fx)
        await session.settled()
        let send = Task { await session.model.send("go") }
        try await eventuallyB1("the turn") { connector.clients[0].isRunningTurn }
        connector.clients[0].finishTurn()
        await send.value
        XCTAssertEqual(attention, [])
        XCTAssertTrue(session.hasUnseenReply)
    }

    // MARK: Runtimes on the server

    func testRuntimesListedExceptThoseFollowedHereOrStillStarting() async throws {
        let connector = B1Connector()
        let followedID = UUID().uuidString
        let listing: RuntimeListing = { _ in
            [B1.summary("other", workspace: "/srv/other", working: true),
             B1.summary(followedID, workspace: "/srv/mine"),
             B1.summary("starting", workspace: "/srv/new", lifecycle: .starting),
             B1.summary("exited", workspace: "/srv/old", lifecycle: .exited)]
        }
        let library = makeLibrary(connector, listing: listing)
        // A session here that follows one of them.
        connector.prepare = { $0.serve(record: B1FakeClient.record(agent: .preset("fx"), workspace: "/srv/mine"), backlog: []) }
        let mine = PhoneSession(serverID: vps.id, path: "/srv/mine", agent: .fx, customCommand: "",
                                saved: SavedSession(id: UUID(), workspacePath: "/srv/mine", title: "Mine", agentID: "fx",
                                                    customCommand: "", draft: "", messages: [], agentSessionID: "s",
                                                    serverID: vps.id, remote: .init(runtimeID: followedID, cursor: 0)),
                                connector: connector)
        library.add(mine)
        await library.refreshRuntimes()
        XCTAssertEqual(library.runtimes[vps.id]?.runtimes.count, 4)
        XCTAssertEqual(library.adoptableRuntimes(on: vps.id).map(\.runtimeID.rawValue), ["other"])
    }

    func testAServerThatCannotBeListedSaysWhy() async {
        let library = makeLibrary(B1Connector(), listing: { _ in throw LatchRemoteClientError.timedOut })
        await library.refreshRuntimes()
        XCTAssertNotNil(library.runtimes[vps.id]?.failure)
        XCTAssertEqual(library.runtimes[vps.id]?.isLoading, false)
    }

    /// Adopting replays the runtime from the start and saves the agent and folder its record
    /// names; the first prompt in the replay names the session.
    func testAdoptingARuntimeTakesItsAgentFolderAndTitle() async throws {
        let connector = B1Connector()
        let runtime = B1.summary("theirs", workspace: "/srv/listed")
        connector.prepare = { client in
            client.serve(record: B1FakeClient.record(agent: .preset("claudeCode"), workspace: "/home/me/app", lastSequence: 2),
                         backlog: [.turnStarted(runtimeID: AgentRuntimeID("theirs"), turnID: UUID(), text: "Tidy the README",
                                                attachments: [], sequence: 1),
                                   .turnEnded(runtimeID: AgentRuntimeID("theirs"), turnID: UUID(), sequence: 2)])
        }
        let library = makeLibrary(connector, listing: { _ in [runtime] })
        await library.refreshRuntimes()
        XCTAssertEqual(library.adoptableRuntimes(on: vps.id).count, 1)
        let session = library.adopt(runtime, serverID: vps.id)
        XCTAssertEqual(session.agentTitle, "Claude Code", "The listed agent names it until the record arrives")
        await session.settled()
        XCTAssertEqual(connector.clients[0].snapshot.attaches.map(\.0), ["theirs"])
        XCTAssertEqual(connector.clients[0].snapshot.attaches.map(\.1), [0], "From the start of the journal")
        XCTAssertEqual(session.model.phase, .ready)
        XCTAssertEqual(session.agent, .claudeCode)
        XCTAssertEqual(session.path, "/home/me/app")
        try await eventuallyB1("the replayed prompt") { session.title == "Tidy the README" }
        XCTAssertEqual(session.savedSession.agentID, "claudeCode")
        XCTAssertEqual(session.savedSession.remote?.runtimeID, "theirs")
        XCTAssertTrue(library.adoptableRuntimes(on: vps.id).isEmpty, "Followed here now")
    }

    func testAdoptingACustomAgentKeepsItsCommand() async {
        let connector = B1Connector()
        connector.prepare = { $0.serve(record: B1FakeClient.record(agent: .custom("mock-agent"), workspace: "/srv"), backlog: []) }
        let library = makeLibrary(connector)
        let session = library.adopt(B1.summary(workspace: "/srv"), serverID: vps.id)
        await session.settled()
        XCTAssertEqual(session.agent, .custom)
        XCTAssertEqual(session.customCommand, "mock-agent")
        XCTAssertEqual(session.savedSession.agentID, "custom")
    }

    // MARK: Remove and stop

    func testRemovingDetachesAndForgetsTheSession() async throws {
        let connector = B1Connector()
        let library = makeLibrary(connector)
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .fx)
        await session.settled()
        library.open(session)
        await library.remove(session)
        XCTAssertTrue(library.sessions.isEmpty)
        XCTAssertNil(library.selectedSessionID)
        XCTAssertEqual(connector.clients[0].snapshot.detaches.count, 1)
        XCTAssertTrue(connector.clients[0].snapshot.stops.isEmpty, "The agent keeps running")
    }

    func testStoppingStopsTheAgentAndKeepsTheSession() async throws {
        let connector = B1Connector()
        let library = makeLibrary(connector)
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .fx)
        await session.settled()
        await library.stop(session)
        XCTAssertEqual(library.sessions.count, 1)
        XCTAssertEqual(connector.clients[0].snapshot.stops.count, 1)
        XCTAssertEqual(session.rowStatus(now: Date()).text, "Stopped")
    }

    func testRemovingAServerDetachesItsSessions() async throws {
        let servers = InMemoryServerStore([vps])
        let connector = B1Connector()
        let library = SessionLibrary(servers: servers, connector: connector, store: nil, listRuntimes: { _ in [] })
        let session = library.create(serverID: vps.id, path: "/srv/app", agent: .fx)
        await session.settled()
        try servers.remove(id: vps.id)
        try await eventuallyB1("the detach") { connector.clients[0].snapshot.detaches.count == 1 }
        XCTAssertEqual(library.orphanedSessions.map(\.id), [session.id])
        XCTAssertTrue(connector.clients[0].snapshot.stops.isEmpty)
    }

    // MARK: Adoption edges

    /// A runtime being adopted, or adopted, is not offered again, and a second tap opens the
    /// session that took it up.
    func testAnAdoptionIsNeverOfferedTwice() async throws {
        let connector = B1Connector()
        connector.prepare = { $0.serve(record: B1FakeClient.record(agent: .preset("fx"), workspace: "/srv/a"), backlog: []) }
        let runtime = B1.summary("theirs", workspace: "/srv/a")
        let library = makeLibrary(connector, listing: { _ in [runtime] })
        await library.refreshRuntimes()
        var changes = 0
        library.onChange = { changes += 1 }
        let session = library.adopt(runtime, serverID: vps.id)
        XCTAssertEqual(session.pendingAdoption?.rawValue, "theirs")
        XCTAssertTrue(library.adoptableRuntimes(on: vps.id).isEmpty, "Not offered while it attaches")
        XCTAssertEqual(changes, 1, "The list is told at once")
        XCTAssertTrue(library.adopt(runtime, serverID: vps.id) === session)
        XCTAssertEqual(library.sessions.count, 1)
        await session.settled()
        XCTAssertNil(session.pendingAdoption)
        XCTAssertEqual(session.model.remoteBinding?.runtimeID, "theirs")
        XCTAssertTrue(library.adoptableRuntimes(on: vps.id).isEmpty, "Followed now")
    }

    /// An adoption whose attach failed adopts again on Retry, never launches an agent it
    /// cannot name, and is not saved: a relaunch finds the runtime listed again.
    func testAFailedAdoptionAdoptsAgainAndIsNotSaved() async throws {
        let store = SessionStore(directory: directory)
        let connector = B1Connector()
        connector.prepare = { $0.failAttaches(with: LatchRemoteClientError.connectionLost) }
        let library = makeLibrary(connector, store: store)
        await library.restore()
        let session = library.adopt(B1.summary("theirs", workspace: "/srv/a"), serverID: vps.id)
        await session.settled()
        XCTAssertEqual(session.model.phase, .disconnected)
        XCTAssertEqual(session.pendingAdoption?.rawValue, "theirs")
        XCTAssertNil(session.launchAgent, "Nothing this device could start")
        XCTAssertFalse(session.canStop)
        session.connect()
        await session.settled()
        let client = connector.clients[0].snapshot
        XCTAssertEqual(client.attaches.map(\.0), ["theirs", "theirs"])
        XCTAssertEqual(client.attaches.map(\.1), [0, 0], "From the start each time")
        XCTAssertTrue(client.launches.isEmpty, "Never launches .custom(\"\")")
        await library.flush()
        let written = try await store.load()
        XCTAssertTrue(written.sessions.isEmpty)
    }

    func testRuntimesAreNotOfferedBeforeTheSavedSessionsLoad() async {
        let library = makeLibrary(B1Connector(), store: SessionStore(directory: directory),
                                  listing: { _ in [B1.summary("x", workspace: "/srv")] })
        await library.refreshRuntimes()
        XCTAssertTrue(library.adoptableRuntimes(on: vps.id).isEmpty, "Its own could be among them")
        await library.restore()
        XCTAssertEqual(library.adoptableRuntimes(on: vps.id).count, 1)
    }

    // MARK: Stop Agent edges

    private func bound(_ runtimeID: String, in library: SessionLibrary, _ connector: B1Connector) -> PhoneSession {
        let saved = SavedSession(id: UUID(), workspacePath: "/srv/app", title: "Bound", agentID: "codex", customCommand: "",
                                 draft: "", messages: [], agentSessionID: "s", serverID: vps.id,
                                 remote: .init(runtimeID: runtimeID, cursor: 3))
        let session = PhoneSession(saved: saved, connector: connector)
        library.add(session)
        return session
    }

    /// A session whose re-attach failed still names a runtime that runs on: Stop reaches it.
    func testStopReachesARuntimeLeftBoundAfterAFailedReattach() async throws {
        let connector = B1Connector()
        connector.prepare = { $0.failAttaches(with: LatchRemoteClientError.connectionLost) }
        let library = makeLibrary(connector)
        let session = bound("rt", in: library, connector)
        session.startIfNeeded()
        await session.settled()
        XCTAssertEqual(session.model.phase, .disconnected)
        XCTAssertNotNil(session.model.remoteBinding)
        XCTAssertTrue(session.canStop)
        await library.stop(session)
        XCTAssertEqual(connector.clients[0].snapshot.stops, ["rt"])
        XCTAssertNil(session.model.remoteBinding, "Nothing to attach to at the next launch")
        XCTAssertEqual(session.rowStatus(now: Date()).text, "Stopped")
    }

    /// Stopped while its launch-time re-attach is still waiting: the runtime it names stops.
    func testStopWhileReattachingStopsTheBoundRuntime() async throws {
        let connector = B1Connector()
        connector.prepare = { $0.holdAttaches() }
        let library = makeLibrary(connector)
        let session = bound("rt", in: library, connector)
        session.startIfNeeded()
        try await eventuallyB1("the attach") { connector.clients.first?.snapshot.attaches.count == 1 }
        XCTAssertEqual(session.model.phase, .connecting)
        XCTAssertTrue(session.canStop)
        await library.stop(session)
        connector.clients[0].releaseAttach()
        await session.settled()
        XCTAssertEqual(connector.clients[0].snapshot.stops, ["rt"])
        XCTAssertNil(session.model.remoteBinding)
        XCTAssertEqual(session.rowStatus(now: Date()).text, "Stopped")
    }

    func testNothingToStopIsNotStopped() async {
        let connector = B1Connector()
        let library = makeLibrary(connector)
        let saved = SavedSession(id: UUID(), workspacePath: "/srv", title: "Idle", agentID: "fx", customCommand: "",
                                 draft: "", messages: [], serverID: vps.id)
        let session = PhoneSession(saved: saved, connector: connector)
        library.add(session)
        XCTAssertFalse(session.canStop)
    }

    // MARK: Servers coming and going

    /// Sessions restored while their server's token was missing reconnect once it is entered
    /// again under the same ID: each is made anew, and a bound one attaches to its runtime.
    func testEnteringAMissingTokenAgainReconnectsItsSessions() async throws {
        let vault = InMemoryTokenVault()
        let servers = KeychainServerStore(directory: directory, vault: vault)
        try servers.save(vps)
        vault.removeToken(for: vps.id)
        servers.reload()
        XCTAssertTrue(servers.servers.isEmpty)
        let saved = SavedSession(id: UUID(), workspacePath: "/srv/bound", title: "Bound", agentID: "codex", customCommand: "",
                                 draft: "keep me", messages: [], agentSessionID: "s", serverID: vps.id,
                                 remote: .init(runtimeID: "rt", cursor: 0))
        let sessions = SessionStore(directory: directory)
        try await sessions.save(SavedSessionLibrary(sessions: [saved], selectedSessionID: nil))
        let connector = B1Connector()
        connector.servers = servers
        connector.prepare = { $0.serve(record: B1FakeClient.record(agent: .preset("codex"), workspace: "/srv/bound"), backlog: []) }
        let library = SessionLibrary(servers: servers, connector: connector, store: sessions, listRuntimes: { _ in [] })
        await library.restore()
        let before = try XCTUnwrap(library.session(id: saved.id))
        await before.settled()
        XCTAssertEqual(before.model.phase, .disconnected, "Its server is not in Servers yet")
        XCTAssertEqual(library.orphanedSessions.map(\.id), [saved.id])

        try servers.save(vps)
        let after = try XCTUnwrap(library.session(id: saved.id))
        XCTAssertFalse(after === before)
        XCTAssertEqual(after.draft, "keep me")
        await after.settled()
        XCTAssertEqual(after.model.phase, .ready)
        XCTAssertEqual(connector.clients.last?.snapshot.attaches.map(\.0), ["rt"])
        XCTAssertTrue(library.orphanedSessions.isEmpty)
    }

    func testAListingFailureWithoutWordsSaysTheServerDidNotAnswer() {
        struct Opaque: Error {}
        XCTAssertEqual(SessionLibrary.listingFailure(Opaque(), server: "vps"), "vps did not answer.")
        XCTAssertEqual(SessionLibrary.listingFailure(LatchRemoteClientError.timedOut, server: "vps"),
                       ServerCheckText.failure(LatchRemoteClientError.timedOut))
    }
}
