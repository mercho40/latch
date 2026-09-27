import AppKit
import LatchACP
import LatchAgentCore
import LatchAgentServer
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest
@testable import LatchMacUI

/// Remote sessions against a real `latch-server` on 127.0.0.1 in this process, running a mock
/// agent from a temporary folder. On loopback the server's filesystem is this Mac's, so the
/// agent's logs show what actually reached it.
@MainActor
final class RemoteSessionLiveTests: XCTestCase {
    private let quickBackoff = LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200))

    private func connector(_ server: LoopbackServer, backoff: LatchRemoteBackoff? = nil,
                           wake: NotificationCenter = NotificationCenter()) -> ChannelRemoteSessionConnector {
        ChannelRemoteSessionConnector(servers: server.store, backoff: backoff ?? quickBackoff, notificationCenter: wake)
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
            let wake = NotificationCenter()
            // Long enough that only the wake reconnects, after the rest of the turn is journaled.
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)),
                                      wake: wake)
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
            wake.post(name: NSWorkspace.didWakeNotification, object: nil)
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
            let wake = NotificationCenter()
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)),
                                      wake: wake)
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

            wake.post(name: NSWorkspace.didWakeNotification, object: nil)
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
                                                      firstConnectionLimit: .milliseconds(500),
                                                      notificationCenter: NotificationCenter())
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
        let connector = ChannelRemoteSessionConnector(servers: store, backoff: quickBackoff,
                                                      notificationCenter: NotificationCenter())
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

    // MARK: Window

    private func saved(_ fixture: WindowFixture, on server: LoopbackServer) -> SavedSession {
        var saved = fixture.session(1, messages: false)
        saved.workspacePath = server.workspace.path
        saved.serverID = server.profile.id
        saved.customCommand = ""
        return saved
    }

    func testClosingARemoteSessionStopsItsRuntimeOnTheServer() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, sidebar) = try await fixture.restored(saved(fixture, on: server), servers: server.store,
                                                                   remoteConnector: connector(server))
                let session = try XCTUnwrap(sidebar.selectedSession)
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
                let id = try await server.onlyRuntime()
                let running = try await server.summary(id)
                XCTAssertEqual(running?.lifecycle, .ready)

                window.closeSession(nil)
                try await eventually("the runtime stopping") { try await server.summary(id)?.lifecycle == .exited }
            }
        }
    }

    /// This used to end the session and drop its runtime, so fixing the token started a second
    /// agent that resumed the conversation while the first ran on until the server's reaper.
    /// A refused token says nothing about the agent, though: the session keeps its runtime, and
    /// the new token, saved through the Edit sheet that keeps the server's ID, attaches to it
    /// again, where the turn that was running finishes.
    func testARotatedTokenKeepsTheRuntimeUntilTheEditedServerAttachesToItAgain() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let notifications = NotificationRecorder()
                let attention = AttentionCenter(presenter: notifications)
                let (_, sidebar) = try await fixture.restored(saved(fixture, on: server), fixture.session(2),
                                                              attention: attention, servers: server.store,
                                                              remoteConnector: connector(server))
                attention.isSessionVisible = { _ in false }
                let session = try XCTUnwrap(sidebar.selectedSession)
                let local = try XCTUnwrap(sidebar.allSessions.first { !$0.location.isRemote })
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
                let id = try await server.onlyRuntime()
                let sending = Task { await session.model.send("tools please") }
                try await fixture.settle({ self.texts(session.model).last == "Read notes · pending" }, timeout: 10)

                let token = try server.rotateToken()
                try await fixture.settle({ session.model.errorMessage != nil }, timeout: 15)
                await sending.value
                XCTAssertEqual(session.model.phase, .disconnected)
                XCTAssertEqual(session.model.errorMessage, "loopback refused the token. Update its token in Settings → Servers.")
                XCTAssertTrue(session.model.errorIsConnectionFailure)
                XCTAssertEqual(session.banner.displayedTitle, "Can’t connect to loopback")
                XCTAssertEqual(session.banner.displayedActions, ["Retry", "Server Settings…"])
                XCTAssertEqual(session.sidebarRow(now: Date()).detail, "Couldn’t connect")
                XCTAssertEqual(session.model.remoteBinding?.runtimeID, id.rawValue, "The runtime is kept")
                let running = try await server.summary(id)
                XCTAssertNotNil(running?.activeTurnID, "The turn runs on without the link")
                XCTAssertEqual(notifications.posts.map(\.body), [], "The turn has not finished")
                let localStatus = local.model.status

                // A save that still does not reach the server fails as the link did, and says so
                // again even after the last failure was dismissed.
                session.banner.performDismissForSmokeTest()
                let attempts = session.model.connectionAttempts
                var wrong = server.profile
                wrong.token = LatchRemoteToken.generate()
                try server.store.save(wrong)
                try await fixture.settle({
                    session.model.connectionAttempts > attempts && session.model.phase == .disconnected
                        && session.model.errorMessage != nil
                }, timeout: 15)
                XCTAssertEqual(session.model.status, "Not connected", "Not the wording of a relaunch's resume")
                XCTAssertNil(session.model.errorAdvice)
                XCTAssertEqual(session.model.errorMessage, "loopback refused the token. Update its token in Settings → Servers.")
                XCTAssertFalse(session.banner.isHidden)
                XCTAssertEqual(session.banner.displayedTitle, "Can’t connect to loopback")
                XCTAssertEqual(session.sidebarRow(now: Date()).detail, "Couldn’t connect")
                XCTAssertEqual(session.model.remoteBinding?.runtimeID, id.rawValue)

                // Edited rather than removed and added again, so the session is still on it.
                let pane = ServersSettingsViewController(store: server.store)
                let settings = NSWindow(contentViewController: pane)
                defer { settings.close() }
                pane.editServer()
                let sheet = try XCTUnwrap(pane.serverSheet)
                sheet.pairingField.stringValue = "latch://127.0.0.1:\(server.port)?token=\(token.rawValue)"
                sheet.pairingChanged()
                sheet.add()
                XCTAssertEqual(server.store.servers.count, 1)
                XCTAssertEqual(server.profile.token, token)
                XCTAssertEqual(session.serverName, "loopback")

                try await fixture.settle({ session.model.phase == .prompting }, timeout: 15)
                XCTAssertNil(session.model.errorMessage)
                XCTAssertEqual(session.model.remoteBinding?.runtimeID, id.rawValue)
                try Data().write(to: server.workspace.appendingPathComponent("go"))
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
                XCTAssertEqual(session.model.status, "Ready · end_turn")
                XCTAssertNil(session.model.errorMessage)
                XCTAssertTrue(session.banner.isHidden)
                // The turn's outcome and its last events travel separately; wait for the events.
                try await fixture.settle({ self.texts(session.model).last == "done" }, timeout: 5)
                XCTAssertEqual(texts(session.model), ["tools please", "reading", "Read notes · completed", "done"])
                let runtime = try await server.onlyRuntime()
                XCTAssertEqual(runtime, id, "No second agent")
                XCTAssertEqual(server.lines(in: "prompts.log"), 1)
                XCTAssertEqual(server.lines(in: "loads.log"), 0, "Attached, not resumed")
                XCTAssertEqual(local.model.status, localStatus, "A session on this Mac is left alone")
                XCTAssertEqual(notifications.posts.map(\.body), ["The agent finished its turn."], "Once, when it did")
            }
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
                                                          firstConnectionLimit: .seconds(4),
                                                          notificationCenter: NotificationCenter())
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
            let wake = NotificationCenter()
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)),
                                      wake: wake)
            let model = try await connectedModel(server, connector)
            await model.send("hello")
            // Away while the server restarts, so the first it hears of it is the re-attach.
            try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
            try await eventually("the link lost") { if case .reconnecting = model.linkState { true } else { false } }
            try await server.restart()
            wake.post(name: NSWorkspace.didWakeNotification, object: nil)

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
            let wake = NotificationCenter()
            let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)),
                                      wake: wake)
            let model = try await connectedModel(server, connector)
            let sending = Task { await model.send("tools please") }
            try await eventually("the first chunk") { self.texts(model).contains("reading") }
            let ended = model.turnsEnded
            try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
            try await eventually("the link lost") { if case .reconnecting = model.linkState { true } else { false } }
            try await server.restart()
            wake.post(name: NSWorkspace.didWakeNotification, object: nil)
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

    func testAServerShuttingDownSaysItStoppedTheAgent() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let notifications = NotificationRecorder()
                let attention = AttentionCenter(presenter: notifications)
                let (_, sidebar) = try await fixture.restored(saved(fixture, on: server), attention: attention,
                                                              servers: server.store, remoteConnector: connector(server))
                attention.isSessionVisible = { _ in false }
                let session = try XCTUnwrap(sidebar.selectedSession)
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
                let sending = Task { await session.model.send("tools please") }
                try await fixture.settle({ self.texts(session.model).last == "Read notes · pending" }, timeout: 10)

                await server.shutdown()
                try await fixture.settle({ session.model.phase == .disconnected }, timeout: 15)
                await sending.value
                XCTAssertEqual(session.model.status, "Stopped on loopback")
                XCTAssertEqual(session.model.errorMessage, "The agent was stopped on loopback.")
                XCTAssertEqual(session.banner.displayedTitle, "\(AgentPreset.custom.title) stopped on loopback")
                XCTAssertEqual(session.banner.displayedDetail, "The agent was stopped on loopback.")
                XCTAssertEqual(session.banner.displayedMessage, "Retry to start it again.")
                XCTAssertEqual(session.banner.displayedActions, ["Retry", "Server Settings…"])
                XCTAssertEqual(session.sidebarRow(now: Date()).detail, "Stopped on loopback")
                XCTAssertEqual(session.model.linkState, .connected, "Not left reconnecting to a server that has gone")
                XCTAssertNil(session.model.remoteBinding)
                XCTAssertEqual(notifications.posts.map(\.body), ["The agent was stopped on its server."])
            }
        }
    }

    func testALostLinkShowsReconnectingUntilAWakeBringsItBack() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let wake = NotificationCenter()
                // Long enough that only the wake can end the wait.
                let connector = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)),
                                          wake: wake)
                let (_, sidebar) = try await fixture.restored(saved(fixture, on: server), servers: server.store,
                                                              remoteConnector: connector)
                let session = try XCTUnwrap(sidebar.selectedSession)
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)

                // An earlier turn's failure gives way to the lost link.
                await session.model.send("broken")
                XCTAssertEqual(session.model.status, "Prompt failed")
                try XCTUnwrap(connector.liveClients.first).dropConnectionForTesting()
                try await fixture.settle { if case .reconnecting = session.model.linkState { true } else { false } }
                XCTAssertEqual(session.banner.displayedTitle, "Reconnecting to loopback…")
                XCTAssertEqual(session.banner.displayedSeverity, .info)
                XCTAssertEqual(session.banner.displayedActions, [])
                XCTAssertFalse(session.banner.isHidden)
                XCTAssertEqual(session.sidebarRow(now: Date()).detail, "Reconnecting to loopback…")
                XCTAssertEqual(session.menuBarRow.status, "Reconnecting to loopback…")
                XCTAssertEqual(session.model.phase, .ready, "A lost link is not a lost session")

                wake.post(name: NSWorkspace.didWakeNotification, object: nil)
                try await fixture.settle({ session.model.linkState == .connected }, timeout: 10)
                XCTAssertEqual(session.model.phase, .ready)
                // The earlier failure is still true, and has its say again.
                XCTAssertEqual(session.banner.displayedSeverity, .warning)
                XCTAssertEqual(session.sidebarRow(now: Date()).detail, "Prompt failed")
            }
        }
    }

    func testARemovedServerFailsAtOnceAndSaysSo() async throws {
        let connector = ChannelRemoteSessionConnector(servers: InMemoryServerStore(), notificationCenter: NotificationCenter())
        let model = SessionModel(makeClient: { connector.makeClient(serverID: UUID()) })
        await model.connect(remote: .preset(AgentPreset.codex.rawValue), path: "/srv/app")
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.errorMessage, "This session’s server is no longer in Settings.")
        XCTAssertTrue(model.errorIsConnectionFailure)
        XCTAssertTrue(connector.liveClients.isEmpty)
    }

}

extension XCTestCase {
    /// Waits for a condition that may need the server to answer, such as a runtime's state.
    @MainActor func eventually(_ description: String, timeout: Duration = .seconds(15),
                    file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw WindowFixture.SettleTimeout(description: description)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// `latch-server`'s hub and network layer over this Mac's agent service, listening on an
/// ephemeral loopback port, with its token in a private folder of its own.
@MainActor
final class LoopbackServer {
    let workspace: URL
    private(set) var hub: RemoteRuntimeHub
    private(set) var server: RemoteServer
    let port: UInt16
    let store: InMemoryServerStore
    private let configDirectory: String
    private let tokens: ServerTokenFile
    private let configuration: RemoteRuntimeHubConfiguration
    private var control: RemoteConnectionID
    /// More listeners on the same hub, as a server reached at a second address would be.
    private var others: [RemoteServer] = []

    static func run(hub configuration: RemoteRuntimeHubConfiguration = RemoteRuntimeHubConfiguration(),
                    _ body: (LoopbackServer) async throws -> Void) async throws {
        let server = try await LoopbackServer(hub: configuration)
        do { try await body(server) } catch {
            await server.close()
            throw error
        }
        await server.close()
    }

    init(hub configuration: RemoteRuntimeHubConfiguration) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("LatchLoopback-\(UUID().uuidString)")
        configDirectory = root.appendingPathComponent("LatchLoopbackConfig-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try RemoteMockAgent.script.write(to: workspace.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        try ServerConfigDirectory.prepare(configDirectory)
        tokens = ServerTokenFile(directory: configDirectory)
        let token = try tokens.readOrCreate()
        self.configuration = configuration
        hub = RemoteRuntimeHub(service: LatchAgentService(), configuration: configuration, homeDirectory: workspace.path)
        control = hub.openConnection(wake: {})
        await hub.start()
        let listener = try ServerListener.bind(ServerSocketAddress(bytes: [127, 0, 0, 1], port: 0))
        port = listener.address.port
        server = Self.serve(hub, tokens: tokens, home: workspace.path, on: listener)
        store = InMemoryServerStore([ServerProfile(
            name: "loopback", host: "127.0.0.1", port: port, token: token,
            customCommand: "/bin/sh " + AgentCommand.quotedArgument(workspace.appendingPathComponent("agent.sh").path))])
    }

    private static func serve(_ hub: RemoteRuntimeHub, tokens: ServerTokenFile, home: String,
                              on listener: ServerListener) -> RemoteServer {
        let server = RemoteServer(
            hub: hub, tokens: tokens,
            configuration: RemoteServerConfiguration(serverInfo: LatchRemoteServerInfo(
                version: "9.9.9", hostname: "loopback", os: "macOS", arch: "arm64", home: home)),
            log: ServerLog(sink: { _ in }))
        server.start([listener])
        return server
    }

    /// Shuts the server down, which stops every agent it runs, and starts a fresh one at the
    /// same address with the same token, as a reboot of the machine would.
    func restart() async throws {
        await server.shutdown()
        hub = RemoteRuntimeHub(service: LatchAgentService(), configuration: configuration, homeDirectory: workspace.path)
        control = hub.openConnection(wake: {})
        await hub.start()
        server = Self.serve(hub, tokens: tokens, home: workspace.path,
                            on: try ServerListener.bind(ServerSocketAddress(bytes: [127, 0, 0, 1], port: port)))
    }

    /// Serves the same hub, runtimes and token on another loopback port, and returns the port.
    func listenOnAnotherPort() throws -> UInt16 {
        let listener = try ServerListener.bind(ServerSocketAddress(bytes: [127, 0, 0, 1], port: 0))
        others.append(Self.serve(hub, tokens: tokens, home: workspace.path, on: listener))
        return listener.address.port
    }

    /// Stops the server as SIGTERM does, which stops every agent it runs.
    func shutdown() async {
        await server.shutdown()
    }

    var profile: ServerProfile { store.servers[0] }
    var agentCommand: String { profile.customCommand }

    /// Replaces the server's token and drops every connection that used the old one.
    func rotateToken() throws -> LatchRemoteToken {
        let token = try tokens.rotate()
        server.checkToken()
        return token
    }

    func summary(_ id: AgentRuntimeID) async throws -> LatchRemoteRuntimeSummary? {
        try await runtimes().first { $0.runtimeID == id }
    }

    /// The one runtime a test launched.
    func onlyRuntime() async throws -> AgentRuntimeID {
        let runtimes = try await runtimes()
        guard runtimes.count == 1 else { throw LoopbackError(description: "expected one runtime, found \(runtimes.count)") }
        return runtimes[0].runtimeID
    }

    private func runtimes() async throws -> [LatchRemoteRuntimeSummary] {
        guard case let .success(.runtimes(runtimes)) = await hub.handle(.listRuntimes, from: control) else {
            throw LoopbackError(description: "listRuntimes failed")
        }
        return runtimes
    }

    /// Lines the mock agent wrote to a log in its folder.
    func lines(in file: String) -> Int {
        let text = (try? String(contentsOf: workspace.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    func close() async {
        for other in others { await other.shutdown() }
        await server.shutdown()
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(atPath: configDirectory)
    }

    struct LoopbackError: Error, CustomStringConvertible {
        let description: String
    }
}

/// An ACP agent in `sh` for remote sessions. Every `case` matches one JSON key, never two:
/// Latch's encoder orders keys differently in every process. The prompt's text picks the
/// turn; `prompts.log`, `decisions.log` and `loads.log` count what reached the agent, and
/// `slow.log`, `asked.log`, `tools.log`, `flood.log` and `deluge.log` when a turn got that far. A `fail-new`
/// file fails session/new. The `tools` and `flood` turns hold after their first output until
/// a `go` file appears, and exit with status 3 if a `die` file appears first; so does `deluge`,
/// which streams about 12 KB, a tool row and `mid` first. A hold also ends that way after a
/// minute, or once the process that started the agent has gone, so a test run that dies
/// mid-turn leaves no agent behind. `SmokeAgent.remoteScript` is the
/// bundle smoke's cut-down copy: a change to the JSON Latch writes must keep both matching.
enum RemoteMockAgent {
    static let script = #"""
    PATH=/usr/bin:/bin:$PATH
    prompt_id=
    reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
    fail() { printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\n' "$1" "$2" "$3"; }
    chunk() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$1"; }
    tool() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"%s","toolCallId":"call-7","title":"Read notes","status":"%s"}}}\n' "$1" "$2"; }
    hold() { n=0; while [ ! -f go ]; do if [ -f die ] || ! kill -0 "$PPID" 2>/dev/null || [ $n -ge 1200 ]; then exit 3; fi; n=$((n+1)); sleep 0.05; done; }
    ask() {
      printf '%s\n' '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"call-1","title":"Edit file"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
    }
    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *\"method\":\"initialize\"*)
          reply "$id" '{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}' ;;
        *\"method\":\"session*/new\"*)
          if [ -f fail-new ]; then fail "$id" -32603 "No sessions today"; continue; fi
          reply "$id" '{"sessionId":"session-1","modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]},"models":{"currentModelId":"model-a","availableModels":[{"modelId":"model-a","name":"Model A"},{"modelId":"model-b","name":"Model B"}]}}' ;;
        *\"method\":\"session*/load\"*)
          echo load >> loads.log
          reply "$id" '{"modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]}}' ;;
        *\"method\":\"session*/set_mode\"*)
          reply "$id" '{}' ;;
        *\"method\":\"session*/set_model\"*)
          reply "$id" '{}' ;;
        *\"method\":\"session*/prompt\"*)
          echo prompt >> prompts.log
          prompt_id=$id
          case "$line" in
            *permission*) chunk asking; ask ;;
            *slow*) chunk one; sleep 1; chunk two; chunk three; echo done >> slow.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *later*) sleep 1; chunk asking; ask; echo asked >> asked.log ;;
            *signin*) fail "$id" -32000 "Authentication required" ;;
            *broken*) fail "$id" -32603 "Something broke" ;;
            *crash*) exit 3 ;;
            *oversize*) chunk "$(printf '%04000d' 0)"; chunk after; reply "$id" '{"stopReason":"end_turn"}' ;;
            *tools*) chunk reading; tool tool_call pending; hold; tool tool_call_update completed; chunk done
              echo done >> tools.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *deluge*) chunk start; i=0
              while [ $i -lt 40 ]; do chunk "$(printf '%0300d' $i)"; i=$((i+1)); done
              tool tool_call pending; chunk mid; hold; tool tool_call_update completed; chunk done
              echo done >> deluge.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *flood*) chunk start; hold; i=0
              while [ $i -lt 40 ]; do chunk "$(printf '%0300d' $i)"; i=$((i+1)); done
              chunk end; echo done >> flood.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *) chunk one; chunk two; chunk three; reply "$id" '{"stopReason":"end_turn"}' ;;
          esac ;;
        *\"id\":900[,}]*)
          echo decision >> decisions.log
          case "$line" in
            *allow-once*) chunk allowed; reply "$prompt_id" '{"stopReason":"end_turn"}' ;;
            *reject-once*) chunk rejected; reply "$prompt_id" '{"stopReason":"end_turn"}' ;;
            *) reply "$prompt_id" '{"stopReason":"cancelled"}' ;;
          esac ;;
      esac
    done
    """#
}

private extension RemotePermissionLedger.Change {
    var summary: String {
        switch self {
        case let .raised(id, _): "raised \(id)"
        case let .closed(id): "closed \(id)"
        }
    }
}
