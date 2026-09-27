#if os(macOS)
import Foundation
import LatchACP
import LatchAgentCore
import LatchAgentServer
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKitTestSupport
import XCTest
@testable import LatchSessionKit

/// Remote sessions against a real `latch-server` on 127.0.0.1 in this process, running a mock
/// agent from a temporary folder. On loopback the server's filesystem is this Mac's, so the
/// agent's logs show what actually reached it.
@MainActor
final class RemoteSessionLiveTests: XCTestCase {
    private let quickBackoff = LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200))

    private func connector(_ server: LoopbackServer, backoff: LatchRemoteBackoff? = nil) -> ChannelRemoteSessionConnector {
        ChannelRemoteSessionConnector(servers: server.store, backoff: backoff ?? quickBackoff)
    }

    private func connectedModel(_ server: LoopbackServer, _ connector: ChannelRemoteSessionConnector) async throws -> SessionModel {
        let serverID = server.profile.id
        let model = SessionModel(makeClient: { connector.makeClient(serverID: serverID) })
        await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.phase, .ready)
        return model
    }

    private func texts(_ model: SessionModel) -> [String] { model.messages.map(\.text) }

    // MARK: Turns

    func testARemoteSessionStreamsRepliesAndAnswersPermissions() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server)
            let model = try await connectedModel(server, connector)
            XCTAssertEqual(model.status, "Connected · mock-agent")
            XCTAssertEqual(model.serviceTransportDescription, "remote 127.0.0.1:\(server.port)")

            await model.send("hello")
            XCTAssertEqual(model.status, "Ready · end_turn")
            XCTAssertNil(model.turnID)
            try await eventually("the streamed reply") { self.texts(model) == ["hello", "onetwothree"] }

            for (option, word) in [("allow-once", "allowed"), ("reject-once", "rejected")] {
                let sending = Task { await model.send("permission please") }
                try await eventually("a permission request") { model.permissions.current != nil }
                let request = try XCTUnwrap(model.permissions.current)
                XCTAssertNotNil(model.turnID, "The turn has an ID to persist while it runs")
                model.permissions.resolve(id: request.id, optionID: option)
                await sending.value
                XCTAssertEqual(model.status, "Ready · end_turn")
                try await eventually("the \(word) reply") { self.texts(model).last == "asking\(word)" }
            }
            XCTAssertEqual(texts(model), ["hello", "onetwothree", "permission please", "askingallowed",
                                          "permission please", "askingrejected"])
            XCTAssertEqual(server.lines(in: "prompts.log"), 3)
            XCTAssertGreaterThan(model.appliedSequence, 0)
            XCTAssertEqual(server.lines(in: "decisions.log"), 2)
        }
    }

    func testADroppedConnectionMidTurnReconnectsAndTheTurnRunsOnce() async throws {
        try await LoopbackServer.run { server in
            // Long enough that only the probe reconnects, after the rest of the turn is journaled.
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)))
            let model = try await connectedModel(server, connector)
            var links: [SessionLinkState] = []
            model.onChange = { [weak model] in
                guard let state = model?.linkState, links.last != state else { return }
                links.append(state)
            }

            let sending = Task { await model.send("slow") }
            // The agent has streamed its first chunk and sleeps before the rest.
            try await eventually("the first chunk") { self.texts(model).last == "one" }
            try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
            try await eventually("the link lost") { if case .reconnecting = model.linkState { true } else { false } }
            try await eventually("the rest of the turn on the server") { server.lines(in: "slow.log") == 1 }
            XCTAssertEqual(model.phase, .prompting, "The turn is still awaited")
            connector.probeAll()
            await sending.value

            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.status, "Ready · end_turn")
            try await eventually("the reply") { self.texts(model).last == "onetwothree" }
            XCTAssertEqual(texts(model), ["slow", "onetwothree"], "Nothing arrives twice")
            XCTAssertEqual(server.lines(in: "prompts.log"), 1, "The prompt ran once")
            let reconnecting = try XCTUnwrap(links.firstIndex { if case .reconnecting(server: "loopback", _) = $0 { true } else { false } },
                                             "Saw \(links)")
            XCTAssertTrue(links[(reconnecting + 1)...].contains(.connected), "Saw \(links)")
            XCTAssertEqual(model.linkState, .connected)
        }
    }

    func testAPermissionRaisedWhileTheLinkIsDownIsShownAndAnsweredOnce() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)))
            let model = try await connectedModel(server, connector)
            var sheets: [UUID] = []
            model.onChange = { [weak model] in
                if let id = model?.permissions.current?.id, sheets.last != id { sheets.append(id) }
            }
            let sending = Task { await model.send("later") }
            try await eventually("the prompt reaching the agent") { server.lines(in: "prompts.log") == 1 }
            try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
            try await eventually("the request raised during the outage") { server.lines(in: "asked.log") == 1 }
            let id = try await server.onlyRuntime()
            try await eventually("the server holding it") { try await server.summary(id)?.pendingPermissionCount == 1 }
            XCTAssertNil(model.permissions.current)

            connector.probeAll()
            try await eventually("the sheet") { model.permissions.current != nil }
            try await eventually("the link back") { model.linkState == .connected }
            let request = try XCTUnwrap(model.permissions.current)
            model.permissions.resolve(id: request.id, optionID: "allow-once")
            await sending.value
            XCTAssertEqual(model.status, "Ready · end_turn")
            try await eventually("the allowed reply") { self.texts(model).last == "askingallowed" }
            XCTAssertEqual(sheets.count, 1, "Shown once, though both the record and the backlog have it")
            XCTAssertEqual(server.lines(in: "decisions.log"), 1)
        }
    }

    func testAnIdleSessionLeavesAnotherClientsPermissionToThem() async throws {
        try await LoopbackServer.run { server in
            let model = try await connectedModel(server, connector(server))
            let id = try await server.onlyRuntime()
            let other = LatchRemoteRuntimeChannel(options: LatchRemoteRuntimeChannel.Options(
                connection: server.profile.connectionOptions, runtimeID: id, backoff: quickBackoff))
            defer { other.close() }
            _ = try await other.attach(after: try await server.summary(id)?.lastSequence ?? 0)
            let turn = Task { try await other.prompt(turnID: UUID(), blocks: [.text("permission please")]) }
            var requested: (id: UUID, sequence: UInt64)?
            for await event in other.events {
                if case let .event(sequence, .permissionRequested(raised, _)) = event { requested = (raised, sequence); break }
            }
            let (raised, sequence) = try XCTUnwrap(requested)
            // This session has the request too. Give it time to answer, which it must not.
            try await eventually("this session taking the request in") { model.appliedSequence >= sequence }
            try await Task.sleep(for: .milliseconds(300))
            let pending = try await server.summary(id)?.pendingPermissionCount
            XCTAssertEqual(pending, 1)
            XCTAssertEqual(server.lines(in: "decisions.log"), 0)
            _ = try await other.send(.resolvePermission(runtimeID: id, requestID: raised, outcome: .selected(optionID: "allow-once")))
            let outcome = try await turn.value
            XCTAssertEqual(outcome.stopReason, "end_turn", "The other client's decision, not a refusal from this session")
            XCTAssertNil(outcome.error)
            XCTAssertEqual(server.lines(in: "decisions.log"), 1)
            XCTAssertNil(model.permissions.current)
            XCTAssertEqual(model.phase, .ready)
        }
    }

    func testAnAgentThatExitsReleasesItsChannel() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server)
            let model = try await connectedModel(server, connector)
            let client = try XCTUnwrap(connector.liveClients.first)
            await model.send("crash")
            try await eventually("the exit") { model.phase == .disconnected }
            XCTAssertEqual(model.status, "Agent exited (3)")
            try await eventually("the channel released") { client.followedRuntimeID == nil }
            XCTAssertEqual(model.linkState, .connected)
        }
    }

    // MARK: Failures

    func testASignInErrorFromAPromptStopsTheRuntime() async throws {
        try await LoopbackServer.run { server in
            let model = try await connectedModel(server, connector(server))
            let id = try await server.onlyRuntime()
            await model.send("signin")
            XCTAssertEqual(model.status, "Sign-in required")
            XCTAssertEqual(model.errorAdvice, "Sign in with the agent, then try again.")
            try await eventually("the session stopping") { model.phase == .disconnected }
            try await eventually("the runtime stopping") { try await server.summary(id)?.lifecycle == .exited }
        }
    }

    func testAFailedTurnIsReportedAsTheAgentsError() async throws {
        try await LoopbackServer.run { server in
            let model = try await connectedModel(server, connector(server))
            await model.send("broken")
            XCTAssertEqual(model.status, "Prompt failed")
            XCTAssertEqual(model.phase, .ready)
            let message = try XCTUnwrap(model.errorMessage)
            XCTAssertTrue(message.contains("Something broke"), message)
            XCTAssertFalse(model.errorIsConnectionFailure)
        }
    }

    func testANewSessionTheAgentRefusesReportsItsError() async throws {
        try await LoopbackServer.run { server in
            try Data().write(to: server.workspace.appendingPathComponent("fail-new"))
            let connector = connector(server)
            let model = SessionModel(makeClient: { connector.makeClient(serverID: server.profile.id) })
            await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
            XCTAssertEqual(model.phase, .disconnected)
            XCTAssertEqual(model.status, "Not connected")
            let message = try XCTUnwrap(model.errorMessage)
            XCTAssertTrue(message.contains("No sessions today"), message)
            XCTAssertFalse(model.errorIsConnectionFailure)
            let id = try await server.onlyRuntime()
            try await eventually("the runtime stopping") { try await server.summary(id)?.lifecycle == .exited }
        }
    }

    func testAServerThatNeverAnswersFailsTheLaunchNamingIt() async throws {
        let store = InMemoryServerStore([ServerProfile(name: "nowhere", host: "127.0.0.1", port: 1,
                                                       token: LatchRemoteToken.generate(), customCommand: "agent")])
        let connector = ChannelRemoteSessionConnector(servers: store, backoff: quickBackoff,
                                                      firstConnectionLimit: .milliseconds(500))
        let model = SessionModel(makeClient: { connector.makeClient(serverID: store.servers[0].id) })
        let started = ContinuousClock.now
        await model.connect(remote: .custom("agent"), path: "/srv/app")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "Stopping what never reached the server takes no wait")
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.errorMessage, "nowhere is not answering at 127.0.0.1:1. "
            + "Check that latch-server is running there and that Settings → Servers has its address right.")
        XCTAssertTrue(model.errorIsConnectionFailure)
    }

    func testDisconnectingFromAServerThatNeverAnsweredDoesNotWait() async throws {
        let store = InMemoryServerStore([ServerProfile(name: "nowhere", host: "127.0.0.1", port: 1,
                                                       token: LatchRemoteToken.generate(), customCommand: "agent")])
        let connector = ChannelRemoteSessionConnector(servers: store, backoff: quickBackoff)
        let model = SessionModel(makeClient: { connector.makeClient(serverID: store.servers[0].id) })
        let connecting = Task { await model.connect(remote: .custom("agent"), path: "/srv/app") }
        try await eventually("a failed first attempt") { if case .reconnecting = model.linkState { true } else { false } }
        let started = ContinuousClock.now
        await model.disconnect()
        await connecting.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(model.phase, .disconnected)
    }

    func testAPermissionSheetOutlivesALostLink() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server)
            let model = try await connectedModel(server, connector)
            var reconnected = false
            model.onChange = { [weak model] in
                if case .reconnecting = model?.linkState { reconnected = true }
            }
            let sending = Task { await model.send("permission please") }
            try await eventually("a permission request") { model.permissions.current != nil }
            let request = try XCTUnwrap(model.permissions.current)

            try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
            try await eventually("the link back") { reconnected && model.linkState == .connected }
            XCTAssertEqual(model.permissions.current?.id, request.id, "The same sheet, neither closed nor raised again")
            XCTAssertEqual(model.phase, .prompting)

            model.permissions.resolve(id: request.id, optionID: "allow-once")
            await sending.value
            XCTAssertEqual(model.status, "Ready · end_turn")
            try await eventually("the allowed reply") { self.texts(model).last == "askingallowed" }
            XCTAssertEqual(server.lines(in: "decisions.log"), 1)
        }
    }

    func testOutputTooLargeToSendLeavesANotice() async throws {
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.maxEncodedEventBytes = 2048
        try await LoopbackServer.run(hub: configuration) { server in
            let model = try await connectedModel(server, connector(server))
            await model.send("oversize")
            XCTAssertEqual(model.status, "Ready · end_turn")
            try await eventually("the chunk after") { self.texts(model).last == "after" }
            XCTAssertEqual(texts(model), ["oversize", "_Some output could not be shown._", "after"])
        }
    }

    // MARK: Re-attaching

    private func permission(_ id: String) -> ACPPermissionRequest {
        ACPPermissionRequest(sessionId: "session-1", toolCall: .object(["toolCallId": .string(id)]),
                             options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")])
    }

    private func record(lastSequence: UInt64, pending: [UUID]) -> LatchRemoteRuntimeRecord {
        LatchRemoteRuntimeRecord(runtimeID: AgentRuntimeID("runtime"), agent: .preset("codex"), agentTitle: "Codex",
                                 workspace: "/srv", lifecycle: .ready,
                                 pendingPermissions: pending.map { LatchRemotePendingPermission(requestID: $0, request: permission($0.uuidString)) },
                                 lastSequence: lastSequence)
    }

    func testAReattachRaisesAndClosesOnlyWhatTheSessionHasNotSeen() {
        var ledger = RemotePermissionLedger()
        let shown = UUID(), answeredElsewhere = UUID(), evicted = UUID(), raisedAndClosed = UUID(), live = UUID()
        XCTAssertTrue(ledger.raise(shown, at: 3))
        XCTAssertTrue(ledger.raise(answeredElsewhere, at: 4))
        XCTAssertFalse(ledger.raise(shown, at: 3), "Never twice")

        // While the link was down: one request was answered by another client, one was raised
        // and its event evicted, one was raised and closed again. The record, as of sequence
        // 20, has the first and the evicted one pending.
        let changes = ledger.reattached(to: record(lastSequence: 20, pending: [shown, evicted]))
        XCTAssertEqual(changes.map(\.summary), ["closed \(answeredElsewhere)", "raised \(evicted)"])

        // The backlog follows: the evicted request's event may still be in it, and the one
        // raised and closed within it is shown not at all.
        XCTAssertFalse(ledger.raise(evicted, at: 12))
        XCTAssertFalse(ledger.raise(raisedAndClosed, at: 14))
        XCTAssertFalse(ledger.close(raisedAndClosed))
        XCTAssertFalse(ledger.close(answeredElsewhere), "Already closed")
        // What comes after the record is live.
        XCTAssertTrue(ledger.raise(live, at: 21))
        XCTAssertTrue(ledger.close(shown))
        XCTAssertTrue(ledger.close(evicted))
        XCTAssertTrue(ledger.close(live))
    }

    // MARK: Configuration

    func testAModelOrModeSetByAnotherClientIsApplied() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server)
            let model = try await connectedModel(server, connector)
            XCTAssertEqual(model.configuration.model?.currentValue, "model-a")
            XCTAssertEqual(model.configuration.permissionMode?.currentValue, "ask")

            // This session's own change arrives both as the reply and as the published event.
            await model.select(.model, value: "model-b")
            XCTAssertEqual(model.configuration.model?.currentValue, "model-b")

            let id = try await server.onlyRuntime()
            let other = LatchRemoteRuntimeChannel(options: LatchRemoteRuntimeChannel.Options(
                connection: server.profile.connectionOptions, runtimeID: id, backoff: quickBackoff))
            defer { other.close() }
            _ = try await other.send(.setModel(runtimeID: id, modelID: "model-a"))
            try await eventually("the other client's model") { model.configuration.model?.currentValue == "model-a" }
            _ = try await other.send(.setMode(runtimeID: id, modeID: "code"))
            try await eventually("the other client's mode") { model.configuration.permissionMode?.currentValue == "code" }
            XCTAssertNil(model.errorMessage)
        }
    }

    func testRetryAfterARefusedTokenAttachesToTheSameRuntime() async throws {
        try await LoopbackServer.run { server in
            // Not through a connector, which would attach again on its own once the token is saved.
            let store = server.store
            let backoff = quickBackoff
            let model = SessionModel(makeClient: {
                RemoteAgentServiceClient(server: store.servers[0], backoff: backoff) { store.servers.first }
            })
            await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
            XCTAssertEqual(model.phase, .ready)
            let id = try await server.onlyRuntime()
            await model.send("hello")
            try await eventually("the reply") { self.texts(model) == ["hello", "onetwothree"] }

            let token = try server.rotateToken()
            try await eventually("the refusal") { model.errorMessage != nil }
            XCTAssertEqual(model.status, "Not connected")
            XCTAssertEqual(model.remoteBinding?.runtimeID, id.rawValue)
            var fixed = server.profile
            fixed.token = token
            try store.save(fixed)
            XCTAssertEqual(model.phase, .disconnected, "Nothing but Retry or the connector attaches again")

            // What Retry does.
            await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertEqual(model.status, "Connected · mock-agent")
            XCTAssertEqual(texts(model), ["hello", "onetwothree"], "Nothing shown twice")
            await model.send("again")
            XCTAssertEqual(model.status, "Ready · end_turn")
            try await eventually("the second reply") { self.texts(model).count == 4 }
            let runtime = try await server.onlyRuntime()
            XCTAssertEqual(runtime, id)
            XCTAssertEqual(server.lines(in: "loads.log"), 0)
        }
    }

    func testChangingTheServersAddressRePointsALiveSessionAtItsRuntime() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server)
            let model = try await connectedModel(server, connector)
            let id = try await server.onlyRuntime()
            var phases: [SessionModel.Phase] = []
            model.onChange = { [weak model] in
                guard let phase = model?.phase, phases.last != phase else { return }
                phases.append(phase)
            }
            let sending = Task { await model.send("tools please") }
            try await eventually("the turn holding") { self.texts(model).last == "Read notes · pending" }

            // A new name or command is not a new way to reach the server.
            var renamed = server.profile
            renamed.name = "renamed"
            renamed.customCommand += " "
            try server.store.save(renamed)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(phases, [.prompting])

            let port = try server.listenOnAnotherPort()
            var moved = server.profile
            moved.port = port
            try server.store.save(moved)
            XCTAssertEqual(model.serviceTransportDescription, "remote 127.0.0.1:\(port)")
            try await eventually("the link back") { model.linkState == .connected }
            try await Task.sleep(for: .milliseconds(200))
            // Pointed at the server the new way in place: the prompt it sent is still awaited.
            XCTAssertEqual(phases, [.prompting])
            try Data().write(to: server.workspace.appendingPathComponent("go"))
            await sending.value
            XCTAssertEqual(model.status, "Ready · end_turn")
            XCTAssertNil(model.errorMessage)
            // The turn's outcome and its last events travel separately; wait for the events.
            try await eventually("the last chunk") { self.texts(model).last == "done" }
            XCTAssertEqual(texts(model), ["tools please", "reading", "Read notes · completed", "done"])
            let runtime = try await server.onlyRuntime()
            XCTAssertEqual(runtime, id)
            XCTAssertEqual(server.lines(in: "prompts.log"), 1)
            XCTAssertEqual(server.lines(in: "loads.log"), 0)
        }
    }

    /// The usual reason to change a server's address is that the old one stopped answering,
    /// so a prompt sent meanwhile is still waiting for the link. It goes to the new address.
    func testAPromptWaitingForTheLinkIsSentOnceTheAddressIsFixed() async throws {
        try await LoopbackServer.run { server in
            // Long enough that only the new address brings the link back.
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)))
            let model = try await connectedModel(server, connector)
            let id = try await server.onlyRuntime()
            try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
            try await eventually("the link lost") { if case .reconnecting = model.linkState { true } else { false } }
            let sending = Task { await model.send("hello") }
            try await eventually("the prompt shown") { self.texts(model) == ["hello"] }
            XCTAssertEqual(server.lines(in: "prompts.log"), 0)

            var moved = server.profile
            moved.port = try server.listenOnAnotherPort()
            try server.store.save(moved)
            try await eventually("the reply") { self.texts(model) == ["hello", "onetwothree"] }
            await sending.value
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.status, "Ready · end_turn")
            XCTAssertEqual(model.linkState, .connected)
            XCTAssertEqual(server.lines(in: "prompts.log"), 1)
            let runtime = try await server.onlyRuntime()
            XCTAssertEqual(runtime, id)
        }
    }

    /// A save that lands while the session is still attaching, as when Latch relaunches after
    /// the server's address changed and the address is fixed while it says "Resuming…".
    func testAFixSavedWhileAttachingIsUsedByThatAttach() async throws {
        try await LoopbackServer.run { server in
            let connector = ChannelRemoteSessionConnector(servers: server.store, backoff: quickBackoff,
                                                          firstConnectionLimit: .seconds(4))
            let model = try await connectedModel(server, connector)
            let id = try await server.onlyRuntime()
            await model.send("hello")
            try await eventually("the reply") { self.texts(model) == ["hello", "onetwothree"] }
            await model.detach()
            let reachable = server.profile
            var unreachable = reachable
            unreachable.port = 1
            try server.store.save(unreachable)

            let attaching = Task { await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path) }
            try await eventually("the attach under way") { model.phase == .connecting }
            try await Task.sleep(for: .milliseconds(300))
            try server.store.save(reachable)
            await attaching.value
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertEqual(model.status, "Connected · mock-agent")
            XCTAssertEqual(texts(model), ["hello", "onetwothree"])
            let runtime = try await server.onlyRuntime()
            XCTAssertEqual(runtime, id)
            XCTAssertEqual(server.lines(in: "loads.log"), 0)
        }
    }

    /// The one link failure that gives the runtime up: the server answered, and no longer has
    /// it. A change in Settings then starts nothing; Retry starts the agent again and resumes.
    func testARuntimeTheServerNoLongerHasIsDroppedAndRetryResumesIt() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)))
            let model = try await connectedModel(server, connector)
            await model.send("hello")
            // Away while the server restarts, so the first it hears of it is the re-attach.
            try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
            try await eventually("the link lost") { if case .reconnecting = model.linkState { true } else { false } }
            try await server.restart()
            connector.probeAll()

            try await eventually("the runtime gone") { model.phase == .disconnected }
            XCTAssertEqual(model.status, "Agent stopped")
            XCTAssertEqual(model.errorMessage, "The agent is no longer running on loopback; the server may have restarted.")
            XCTAssertEqual(model.errorAdvice, "Retry to start it again.")
            XCTAssertFalse(model.errorIsConnectionFailure)
            XCTAssertNil(model.remoteBinding, "Nothing is left to attach to")

            var changed = server.profile
            changed.allowUnencryptedNetwork.toggle()
            try server.store.save(changed)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.phase, .disconnected, "Settings reattaches only a runtime the session kept")

            // What Retry does.
            await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertEqual(server.lines(in: "loads.log"), 1, "Resumed in a new agent")
        }
    }

    /// The server restarted while the link was down mid-turn, so the re-attach finds the
    /// runtime gone. The turn did not finish: it went with the agent, and is announced so.
    func testARestartWhileTheLinkIsDownIsNotAnnouncedAsTheTurnFinishing() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)))
            let model = try await connectedModel(server, connector)
            let sending = Task { await model.send("tools please") }
            try await eventually("the first chunk") { self.texts(model).contains("reading") }
            let ended = model.turnsEnded
            try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
            try await eventually("the link lost") { if case .reconnecting = model.linkState { true } else { false } }
            try await server.restart()
            connector.probeAll()
            try await eventually("the runtime gone") { model.phase == .disconnected }
            await sending.value
            XCTAssertEqual(model.status, "Agent stopped")
            XCTAssertEqual(model.turnsEnded, ended + 1)
            XCTAssertTrue(model.lastTurnEndedByStop, "Not announced as a finished turn")
            XCTAssertEqual(texts(model).last, "_" + SessionModel.outputLostWhileUnreachable + "_")
        }
    }

    // MARK: Stopped on the server

    func testAnAgentStoppedByAnotherClientIsNotReportedAsAnExit() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server)
            let model = try await connectedModel(server, connector)
            let client = try XCTUnwrap(connector.liveClients.first)
            let id = try await server.onlyRuntime()
            let other = LatchRemoteRuntimeChannel(options: LatchRemoteRuntimeChannel.Options(
                connection: server.profile.connectionOptions, runtimeID: id, backoff: quickBackoff))
            defer { other.close() }
            _ = try await other.send(.stopRuntime(runtimeID: id))

            try await eventually("the stop") { model.phase == .disconnected }
            XCTAssertEqual(model.status, "Stopped on loopback")
            XCTAssertEqual(model.errorMessage, "The agent was stopped on loopback.")
            XCTAssertEqual(model.errorAdvice, "Retry to start it again.")
            XCTAssertTrue(model.stoppedOnServer)
            XCTAssertFalse(model.errorIsConnectionFailure)
            XCTAssertNil(model.remoteBinding)
            try await eventually("the channel released") { client.followedRuntimeID == nil }

            // Retry starts the agent again and resumes its conversation there.
            await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.stoppedOnServer)
            XCTAssertEqual(server.lines(in: "loads.log"), 1)
        }
    }

    func testARemovedServerFailsAtOnceAndSaysSo() async throws {
        let connector = ChannelRemoteSessionConnector(servers: InMemoryServerStore())
        let model = SessionModel(makeClient: { connector.makeClient(serverID: UUID()) })
        await model.connect(remote: .preset(AgentPreset.codex.rawValue), path: "/srv/app")
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.errorMessage, "This session’s server is no longer in Settings.")
        XCTAssertTrue(model.errorIsConnectionFailure)
        XCTAssertTrue(connector.liveClients.isEmpty)
    }

}

private extension RemotePermissionLedger.Change {
    var summary: String {
        switch self {
        case let .raised(id, _): "raised \(id)"
        case let .closed(id): "closed \(id)"
        }
    }
}
#endif
