import AppKit
import Darwin
import LatchACP
import LatchAgentCore
import LatchAgentServer
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
import XCTest
@testable import LatchMacUI

/// Quitting Latch leaves a remote session's agent running on its server, and the next launch
/// attaches to it again. Each test runs Latch twice against one real `latch-server` on
/// loopback: a window that quits through the real quit path, then a second window restored
/// from what the first one saved, with a connector of its own, as a relaunch would have.
@MainActor
final class RemoteSessionReattachTests: XCTestCase {
    private let quickBackoff = LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200))
    private static let lostNotice = "_Some output from while Latch was closed could not be recovered._"
    private static let notSentNotice = "_This message was not sent before Latch quit._"
    private static let finished = "The agent finished its turn."

    private func connector(_ server: LoopbackServer, backoff: LatchRemoteBackoff? = nil) -> ChannelRemoteSessionConnector {
        ChannelRemoteSessionConnector(servers: server.store, backoff: backoff ?? quickBackoff,
                                      notificationCenter: NotificationCenter())
    }

    /// A session on the loopback server that has never run, selected so it launches.
    private func firstRun(_ fixture: WindowFixture, _ server: LoopbackServer, attention: AttentionCenter? = nil,
                          connector: ChannelRemoteSessionConnector? = nil) async throws
        -> (SessionWindowController, SessionViewController) {
        var saved = fixture.session(1, messages: false)
        saved.workspacePath = server.workspace.path
        saved.serverID = server.profile.id
        saved.customCommand = ""
        let (window, sidebar) = try await fixture.restored(saved, attention: attention, servers: server.store,
                                                           remoteConnector: connector ?? self.connector(server))
        let session = try XCTUnwrap(sidebar.selectedSession)
        try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
        return (window, session)
    }

    /// Latch launched again: a new window restored from the store the last one saved to.
    private func relaunch(_ fixture: WindowFixture, _ server: LoopbackServer) async throws -> SessionViewController {
        let window = fixture.window(servers: server.store, remoteConnector: connector(server))
        await window.restoreSessions(launchEnvironment: fixture.environment)
        return try XCTUnwrap(try fixture.sidebar(in: window).selectedSession)
    }

    /// Latch launched again with no session selected, so none has a view to load.
    private func relaunchInBackground(_ fixture: WindowFixture, _ server: LoopbackServer, attention: AttentionCenter)
        async throws -> (SessionWindowController, SessionViewController) {
        var library = try await fixture.store.load()
        library.selectedSessionID = nil
        try await fixture.store.save(library)
        let window = fixture.window(attention: attention, servers: server.store, remoteConnector: connector(server))
        await window.restoreSessions(launchEnvironment: fixture.environment)
        XCTAssertNil(try fixture.sidebar(in: window).selectedSession)
        return (window, try XCTUnwrap(try fixture.sidebar(in: window).allSessions.first))
    }

    /// What the last quit saved for the one session.
    private func savedBinding(_ fixture: WindowFixture) async throws -> SavedSession.RemoteBinding {
        let library = try await fixture.store.load()
        return try XCTUnwrap(library.sessions.first?.remote, "The quit saved no binding")
    }

    /// Another client that has followed the runtime since before the turn, and so saw all of it.
    private func observer(of id: AgentRuntimeID, _ server: LoopbackServer) async throws -> SessionModel {
        let connector = connector(server)
        let model = SessionModel(makeClient: { connector.makeClient(serverID: server.profile.id) })
        model.restore(messages: [], agentSessionID: "session-1",
                      remote: SavedSession.RemoteBinding(runtimeID: id.rawValue, cursor: 0))
        await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
        XCTAssertEqual(model.phase, .ready)
        return model
    }

    private func transcript(_ model: SessionModel) -> [String] {
        model.messages.map { "\($0.role.rawValue): \($0.text)" }
    }

    private func texts(_ model: SessionModel) -> [String] { model.messages.map(\.text) }

    // MARK: Turns

    func testQuittingMidTurnLeavesTheTurnRunningAndARelaunchFollowsItToTheEnd() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let id = try await server.onlyRuntime()
                let observer = try await observer(of: id, server)
                let sending = Task { await session.model.send("tools please") }
                try await fixture.settle({ self.texts(session.model).last == "Read notes · pending" }, timeout: 10)
                XCTAssertEqual(texts(session.model), ["tools please", "reading", "Read notes · pending"])

                await window.shutdown()
                await sending.value
                let summary = try await server.summary(id)
                XCTAssertEqual(summary?.lifecycle, .ready, "Quitting stops nothing on the server")
                XCTAssertNotNil(summary?.activeTurnID, "The turn is still running")
                let binding = try await savedBinding(fixture)
                XCTAssertEqual(binding.runtimeID, id.rawValue)
                XCTAssertNotNil(binding.boundaryTurnID)
                XCTAssertEqual(binding.boundaryMessageID, session.model.messages.first?.id, "The turn's prompt")

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.phase == .prompting && relaunched.model.messages.count == 3 },
                                         timeout: 15)
                XCTAssertEqual(transcript(relaunched.model), transcript(observer), "Replayed from the prompt, once")
                XCTAssertEqual(relaunched.model.remoteBinding?.runtimeID, id.rawValue, "The same runtime, not a new one")

                try Data().write(to: server.workspace.appendingPathComponent("go"))
                try await fixture.settle({ relaunched.model.phase == .ready }, timeout: 15)
                XCTAssertEqual(relaunched.model.status, "Ready · end_turn")
                XCTAssertNil(relaunched.model.errorMessage)
                try await fixture.settle({ self.transcript(observer).count == 4 && self.transcript(relaunched.model).count == 4 })
                XCTAssertEqual(transcript(relaunched.model), transcript(observer))
                XCTAssertEqual(texts(relaunched.model), ["tools please", "reading", "Read notes · completed", "done"],
                               "One tool row, updated in place")
                XCTAssertEqual(server.lines(in: "prompts.log"), 1)
                XCTAssertEqual(server.lines(in: "loads.log"), 0, "Attached, not resumed")
            }
        }
    }

    func testATurnThatEndedWhileLatchWasClosedIsReplayedInFull() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let id = try await server.onlyRuntime()
                let observer = try await observer(of: id, server)
                let sending = Task { await session.model.send("tools please") }
                try await fixture.settle({ self.texts(session.model).last == "Read notes · pending" }, timeout: 10)
                await window.shutdown()
                await sending.value

                try Data().write(to: server.workspace.appendingPathComponent("go"))
                try await fixture.settle({ server.lines(in: "tools.log") == 1 }, timeout: 10)
                try await fixture.settle({ self.transcript(observer).count == 4 }, timeout: 10)

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.messages.count == 4 && relaunched.model.phase == .ready },
                                         timeout: 15)
                XCTAssertEqual(relaunched.model.status, "Ready · end_turn")
                XCTAssertEqual(transcript(relaunched.model), transcript(observer))
                XCTAssertEqual(texts(relaunched.model), ["tools please", "reading", "Read notes · completed", "done"])
            }
        }
    }

    func testQuittingMidTurnIsNotAnnouncedAsTheTurnFinishing() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let notifications = NotificationRecorder()
                let (window, session) = try await firstRun(fixture, server,
                                                           attention: AttentionCenter(presenter: notifications))
                let sending = Task { await session.model.send("tools please") }
                try await fixture.settle({ self.texts(session.model).last == "Read notes · pending" }, timeout: 10)
                await window.shutdown()
                await sending.value
                XCTAssertFalse(notifications.posts.contains { $0.body == Self.finished })
            }
        }
    }

    func testATurnThatEndedWhileLatchWasClosedIsAnnouncedAtLaunch() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let sending = Task { await session.model.send("tools please") }
                try await fixture.settle({ self.texts(session.model).last == "Read notes · pending" }, timeout: 10)
                await window.shutdown()
                await sending.value
                try Data().write(to: server.workspace.appendingPathComponent("go"))
                try await fixture.settle({ server.lines(in: "tools.log") == 1 }, timeout: 10)

                let notifications = NotificationRecorder()
                let (_, background) = try await relaunchInBackground(
                    fixture, server, attention: AttentionCenter(presenter: notifications))
                try await fixture.settle({ notifications.posts.contains { $0.body == Self.finished } }, timeout: 15)
                XCTAssertEqual(background.model.phase, .ready)
                XCTAssertEqual(background.model.status, "Ready · end_turn")
                XCTAssertTrue(background.hasUnseenReply)
                XCTAssertEqual(background.sidebarRow(now: Date()).status, .unseen)
                try await fixture.settle { self.texts(background.model).count == 4 }
                XCTAssertEqual(texts(background.model), ["tools please", "reading", "Read notes · completed", "done"])
            }
        }
    }

    func testAPromptStillWaitingForTheLinkAtQuitIsMarkedNotSent() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                // Long enough that the link stays down until the quit.
                let slow = connector(server, backoff: LatchRemoteBackoff(initial: .seconds(120), maximum: .seconds(120)))
                let (window, session) = try await firstRun(fixture, server, connector: slow)
                try XCTUnwrap(slow.liveClients.first).dropConnectionForTesting()
                try await fixture.settle { if case .reconnecting = session.model.linkState { true } else { false } }
                let sending = Task { await session.model.send("hello") }
                try await fixture.settle { session.model.phase == .prompting }
                await window.shutdown()
                await sending.value
                let binding = try await savedBinding(fixture)
                XCTAssertNotNil(binding.boundaryTurnID)

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ self.texts(relaunched.model).count == 2 }, timeout: 15)
                XCTAssertEqual(texts(relaunched.model), ["hello", Self.notSentNotice])
                XCTAssertEqual(relaunched.model.phase, .ready)
                XCTAssertNil(relaunched.model.errorMessage)
                XCTAssertEqual(server.lines(in: "prompts.log"), 0, "Never sent, and not sent again")
            }
        }
    }

    // MARK: Permissions

    func testQuittingWithAPermissionPendingLeavesItForTheRelaunchToAnswer() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let id = try await server.onlyRuntime()
                let sending = Task { await session.model.send("permission please") }
                try await fixture.settle({ session.model.permissions.current != nil }, timeout: 10)

                await window.shutdown()
                await sending.value
                XCTAssertNil(session.model.permissions.current)
                // Give a stray refusal time to reach the agent, which it must not.
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(server.lines(in: "decisions.log"), 0, "Quitting refuses nothing")
                let summary = try await server.summary(id)
                XCTAssertEqual(summary?.pendingPermissionCount, 1)
                XCTAssertEqual(summary?.lifecycle, .ready)

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.permissions.current != nil }, timeout: 15)
                XCTAssertEqual(relaunched.model.phase, .prompting)
                XCTAssertEqual(relaunched.attention.permission, relaunched.model.permissions.current?.id,
                               "Raised through the attention path, like any request")
                let request = try XCTUnwrap(relaunched.model.permissions.current)
                relaunched.resolvePermission(request: request.id, optionID: "allow-once")
                try await fixture.settle({ relaunched.model.phase == .ready }, timeout: 15)
                XCTAssertEqual(relaunched.model.status, "Ready · end_turn")
                try await fixture.settle { self.texts(relaunched.model).last == "askingallowed" }
                XCTAssertEqual(texts(relaunched.model), ["permission please", "askingallowed"])
                XCTAssertNil(relaunched.model.permissions.current,
                             "Raised once, though the record and the backlog both have it")
                XCTAssertEqual(server.lines(in: "decisions.log"), 1)
                XCTAssertEqual(server.lines(in: "prompts.log"), 1)
            }
        }
    }

    func testASessionNotOnScreenIsAttachedAtLaunchAndItsRequestReachesANotification() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let sending = Task { await session.model.send("permission please") }
                try await fixture.settle({ session.model.permissions.current != nil }, timeout: 10)
                await window.shutdown()
                await sending.value
                // Latch reopens with no session selected, so none has a view to load.
                var library = try await fixture.store.load()
                library.selectedSessionID = nil
                try await fixture.store.save(library)

                let notifications = NotificationRecorder()
                let attention = AttentionCenter(presenter: notifications)
                let relaunched = fixture.window(attention: attention, servers: server.store,
                                                remoteConnector: connector(server))
                await relaunched.restoreSessions(launchEnvironment: fixture.environment)
                let background = try XCTUnwrap(try fixture.sidebar(in: relaunched).allSessions.first)
                XCTAssertNil(try fixture.sidebar(in: relaunched).selectedSession)
                try await fixture.settle({ notifications.posts.contains { $0.body == "The agent is waiting for a permission decision." } },
                                         timeout: 15)
                XCTAssertFalse(background.isViewLoaded, "Attached without being selected")
                XCTAssertEqual(attention.badgeCount, 1)
                XCTAssertEqual(background.sidebarRow(now: Date()).detail, "Waiting for a decision")

                let request = try XCTUnwrap(notifications.posts.last?.userInfo)
                notifications.onAction?("allow:allow-once", request)
                try await fixture.settle({ notifications.posts.contains { $0.body == "The agent finished its turn." } },
                                         timeout: 15)
                XCTAssertEqual(background.model.status, "Ready · end_turn")
                XCTAssertEqual(attention.badgeCount, 0)
                try await fixture.settle { self.texts(background.model).last == "askingallowed" }
                XCTAssertEqual(server.lines(in: "decisions.log"), 1)
            }
        }
    }

    func testSelectingASessionAttachedInTheBackgroundKeepsItsRuntime() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, _) = try await firstRun(fixture, server)
                let id = try await server.onlyRuntime()
                await window.shutdown()

                let (relaunched, background) = try await relaunchInBackground(
                    fixture, server, attention: AttentionCenter(presenter: NotificationRecorder()))
                try await fixture.settle({ background.model.phase == .ready }, timeout: 15)
                XCTAssertFalse(background.isViewLoaded)
                try fixture.sidebar(in: relaunched).select(background)
                background.loadViewIfNeeded()
                XCTAssertTrue(background.isViewLoaded)
                // Give a second connection time to begin, which it must not.
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(background.model.phase, .ready)
                XCTAssertEqual(background.model.remoteBinding?.runtimeID, id.rawValue)
                let summary = try await server.summary(id)
                XCTAssertEqual(summary?.lifecycle, .ready)
                let only = try await server.onlyRuntime()
                XCTAssertEqual(only, id)
                XCTAssertEqual(server.lines(in: "loads.log"), 0)
            }
        }
    }

    // MARK: Configuration

    func testARelaunchShowsTheModelAndModeLastChosenNotTheSessionsDefaults() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                await session.model.select(.model, value: "model-b")
                await session.model.select(.permissionMode, value: "code")
                XCTAssertEqual(session.model.configuration.model?.currentValue, "model-b")
                XCTAssertEqual(session.model.configuration.permissionMode?.currentValue, "code")
                await window.shutdown()

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.phase == .ready }, timeout: 15)
                XCTAssertEqual(relaunched.model.configuration.model?.currentValue, "model-b")
                XCTAssertEqual(relaunched.model.configuration.permissionMode?.currentValue, "code")
                let model: NSPopUpButton = try fixture.control(in: relaunched.view, label: "Session model")
                let mode: NSPopUpButton = try fixture.control(in: relaunched.view, label: "Permission mode")
                XCTAssertEqual(model.titleOfSelectedItem, "Model B")
                XCTAssertEqual(mode.titleOfSelectedItem, "Code")
                XCTAssertTrue(model.isEnabled)
                XCTAssertEqual(server.lines(in: "loads.log"), 0)
            }
        }
    }

    func testQuittingIdleSavesTheLastSequenceAndARelaunchShowsTheTranscriptOnce() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                // The turn's end can overtake its last chunks.
                await session.model.send("hello")
                try await fixture.settle { self.texts(session.model) == ["hello", "onetwothree"] }
                await session.model.send("again")
                try await fixture.settle { self.texts(session.model) == ["hello", "onetwothree", "again", "onetwothree"] }
                await window.shutdown()
                // Detaching stops taking events in, so this is what had been applied at the quit.
                let applied = session.model.appliedSequence
                XCTAssertGreaterThan(applied, 0)
                let binding = try await savedBinding(fixture)
                XCTAssertEqual(binding.cursor, applied)
                XCTAssertEqual(binding.applied, applied)
                XCTAssertNil(binding.boundaryTurnID)
                XCTAssertEqual(binding.boundaryMessageID, session.model.messages.last?.id)

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.phase == .ready }, timeout: 15)
                // Anything replayed twice would have arrived by now.
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(texts(relaunched.model), ["hello", "onetwothree", "again", "onetwothree"])
                await relaunched.model.send("third")
                try await fixture.settle { self.texts(relaunched.model).last == "onetwothree" }
                XCTAssertEqual(texts(relaunched.model), ["hello", "onetwothree", "again", "onetwothree", "third", "onetwothree"])
                XCTAssertEqual(server.lines(in: "prompts.log"), 3)
            }
        }
    }

    // MARK: A runtime that is gone

    func testAServerRestartedWhileLatchWasClosedResumesTheSessionAndSaysWhatWasLost() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let sending = Task { await session.model.send("tools please") }
                try await fixture.settle({ self.texts(session.model).last == "Read notes · pending" }, timeout: 10)
                await window.shutdown()
                await sending.value
                let old = try await savedBinding(fixture)
                try await server.restart()

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.phase == .ready || relaunched.model.errorMessage != nil },
                                         timeout: 15)
                XCTAssertNil(relaunched.model.errorMessage)
                XCTAssertEqual(server.lines(in: "loads.log"), 1, "Resumed through session/load")
                XCTAssertEqual(relaunched.model.savedAgentSessionID, "session-1")
                XCTAssertEqual(texts(relaunched.model), ["tools please", "reading", "Read notes · pending", Self.lostNotice])
                XCTAssertNotEqual(relaunched.model.remoteBinding?.runtimeID, old.runtimeID)
            }
        }
    }

    func testAnAgentThatExitedWhileLatchWasClosedShowsItsLastOutputAndTheExit() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let id = try await server.onlyRuntime()
                let sending = Task { await session.model.send("tools please") }
                try await fixture.settle({ self.texts(session.model).last == "Read notes · pending" }, timeout: 10)
                await window.shutdown()
                await sending.value
                try Data().write(to: server.workspace.appendingPathComponent("die"))
                try await eventually("the agent's exit") { try await server.summary(id)?.lifecycle == .exited }

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.status == "Agent exited (3)" }, timeout: 15)
                XCTAssertEqual(relaunched.model.phase, .disconnected)
                XCTAssertEqual(texts(relaunched.model), ["tools please", "reading", "Read notes · pending"])
                XCTAssertNil(relaunched.model.remoteBinding)
                XCTAssertEqual(server.lines(in: "loads.log"), 0)
            }
        }
    }

    func testAnAgentStoppedWhileLatchWasClosedSaysItWasStoppedThere() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let id = try await server.onlyRuntime()
                await session.model.send("hello")
                await window.shutdown()
                let other = LatchRemoteRuntimeChannel(options: LatchRemoteRuntimeChannel.Options(
                    connection: server.profile.connectionOptions, runtimeID: id, backoff: quickBackoff))
                defer { other.close() }
                _ = try await other.send(.stopRuntime(runtimeID: id))

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.phase == .disconnected && relaunched.model.errorMessage != nil },
                                         timeout: 15)
                XCTAssertEqual(relaunched.model.status, "Stopped on loopback")
                XCTAssertEqual(relaunched.model.errorMessage, "The agent was stopped on loopback.")
                XCTAssertEqual(texts(relaunched.model), ["hello", "onetwothree"])
                XCTAssertNil(relaunched.model.remoteBinding)
                XCTAssertEqual(server.lines(in: "loads.log"), 0)
            }
        }
    }

    func testOutputEvictedWhileLatchWasClosedKeepsTheTranscriptAndSaysSo() async throws {
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.runtimeJournalBudget = 4096
        try await LoopbackServer.run(hub: configuration) { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let sending = Task { await session.model.send("flood please") }
                try await fixture.settle({ self.texts(session.model).last == "start" }, timeout: 10)
                await window.shutdown()
                await sending.value
                try Data().write(to: server.workspace.appendingPathComponent("go"))
                try await fixture.settle({ server.lines(in: "flood.log") == 1 }, timeout: 10)

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ self.texts(relaunched.model).last?.hasSuffix("end") == true }, timeout: 15)
                let texts = texts(relaunched.model)
                XCTAssertEqual(Array(texts.prefix(3)), ["flood please", "start", Self.lostNotice],
                               "The saved transcript stays, and the gap is marked")
                XCTAssertEqual(texts.count, 4)
                XCTAssertEqual(relaunched.model.phase, .ready)
                XCTAssertNil(relaunched.model.errorMessage)
            }
        }
    }

    func testOutputEvictedDuringTheTurnBeforeQuittingIsNotShownTwice() async throws {
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.runtimeJournalBudget = 4096
        try await LoopbackServer.run(hub: configuration) { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                let sending = Task { await session.model.send("deluge please") }
                try await fixture.settle({ self.texts(session.model).last == "mid" }, timeout: 10)
                let before = texts(session.model)
                XCTAssertEqual(before.count, 4, "\(before.map { $0.prefix(20) })")
                await window.shutdown()
                await sending.value
                let binding = try await savedBinding(fixture)
                XCTAssertGreaterThan(binding.applied, binding.cursor, "The turn's output is past its prompt")

                let relaunched = try await relaunch(fixture, server)
                try await fixture.settle({ relaunched.model.phase == .prompting }, timeout: 15)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(texts(relaunched.model), before, "Nothing was lost, and nothing arrives twice")

                try Data().write(to: server.workspace.appendingPathComponent("go"))
                try await fixture.settle({ relaunched.model.phase == .ready }, timeout: 15)
                try await fixture.settle { self.texts(relaunched.model).last == "done" }
                XCTAssertEqual(Array(texts(relaunched.model).prefix(4)), before)
                XCTAssertFalse(texts(relaunched.model).contains(Self.lostNotice))
                XCTAssertEqual(texts(relaunched.model).filter { $0 == "mid" }.count, 1)
                XCTAssertEqual(server.lines(in: "prompts.log"), 1)
            }
        }
    }

    // MARK: Closing

    func testUndoingACloseResumesInANewRuntimeAndNeverAttachesToTheStoppedOne() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, session) = try await firstRun(fixture, server)
                await session.model.send("hello")
                // The turn's end can overtake its last chunks.
                try await fixture.settle { self.texts(session.model) == ["hello", "onetwothree"] }
                let id = try await server.onlyRuntime()
                XCTAssertEqual(session.savedSession.remote?.runtimeID, id.rawValue)

                window.closeSession(nil)
                try await eventually("the runtime stopping") { try await server.summary(id)?.lifecycle == .exited }
                try XCTUnwrap(window.window?.undoManager).undo()
                let reopened = try XCTUnwrap(try fixture.sidebar(in: window).selectedSession)
                XCTAssertEqual(reopened.id, session.id)
                XCTAssertNil(reopened.savedSession.remote, "The close dropped the binding")
                try await fixture.settle({ reopened.model.phase == .ready || reopened.model.errorMessage != nil },
                                         timeout: 15)
                XCTAssertNil(reopened.model.errorMessage)
                XCTAssertEqual(server.lines(in: "loads.log"), 1, "Resumed through session/load")
                let binding = try XCTUnwrap(reopened.model.remoteBinding)
                XCTAssertNotEqual(binding.runtimeID, id.rawValue)
                XCTAssertEqual(reopened.model.messages.map(\.text), ["hello", "onetwothree"])
            }
        }
    }

    func testClosingASessionThatHasNotAttachedYetStopsItsSavedRuntime() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, _) = try await firstRun(fixture, server)
                let id = try await server.onlyRuntime()
                await window.shutdown()
                // Relaunched with the server unreachable: the binding stays, unattached.
                let unreachable = fixture.window(servers: server.store,
                                                 remoteConnector: UnconnectedRemoteSessionConnector())
                await unreachable.restoreSessions(launchEnvironment: fixture.environment)
                let session = try XCTUnwrap(try fixture.sidebar(in: unreachable).selectedSession)
                try await fixture.settle { session.model.errorMessage != nil }
                XCTAssertEqual(session.model.remoteBinding?.runtimeID, id.rawValue)
                let lifecycle = try await server.summary(id)?.lifecycle
                XCTAssertEqual(lifecycle, .ready)

                // Its runtime stops with the close all the same, through a client that can reach it.
                let closing = SessionModel(makeClient: { self.connector(server).makeClient(serverID: server.profile.id) })
                closing.restore(messages: [], agentSessionID: "session-1", remote: session.model.remoteBinding)
                await closing.discardRemoteBinding()
                XCTAssertNil(closing.remoteBinding)
                try await eventually("the runtime stopping") { try await server.summary(id)?.lifecycle == .exited }
            }
        }
    }

    // MARK: Saving

    func testABindingIsSavedWithItsSessionAndOnlyForOneOnAServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteBinding-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let prompt = ChatMessage(role: .user, text: "tools please")
        let binding = SavedSession.RemoteBinding(runtimeID: UUID().uuidString, cursor: 41,
                                                 boundaryMessageID: prompt.id, boundaryTurnID: UUID())
        var remote = SavedSession(id: UUID(), workspacePath: "/srv/app", title: "Remote", agentID: "codex",
                                  customCommand: "", draft: "", messages: [prompt], agentSessionID: "ctx",
                                  serverID: UUID(), remote: binding)
        try await store.save(SavedSessionLibrary(sessions: [remote], selectedSessionID: nil))
        let restored = try await SessionStore(directory: directory).load()
        XCTAssertEqual(restored.version, 2)
        XCTAssertEqual(restored.sessions.first?.remote, binding)

        remote.serverID = nil
        do {
            try await store.save(SavedSessionLibrary(sessions: [remote], selectedSessionID: nil))
            XCTFail("A session on this Mac cannot have left a runtime on a server")
        } catch {
            XCTAssertEqual(error as? SessionStore.StoreError, .invalidLibrary)
        }

        // Written before bindings existed: no key, no binding.
        let old = Data("""
        {"version":2,"sessions":[{"id":"00000000-0000-0000-0000-000000000001","workspacePath":"/srv/app",
          "title":"Old","agentID":"codex","customCommand":"","draft":"","messages":[],"agentSessionID":"ctx",
          "serverID":"00000000-0000-0000-0000-000000000002"}]}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(SavedSessionLibrary.self, from: old).sessions[0].remote)
    }

    // MARK: This Mac

    func testQuittingStillStopsAnAgentOnThisMac() async throws {
        try await WindowFixture.run { fixture in
            let script = fixture.root.appendingPathComponent("agent.sh")
            let pidFile = fixture.root.appendingPathComponent("agent.pid")
            try ("echo $$ > " + AgentCommand.quotedArgument(pidFile.path) + "\n" + SmokeAgent.script)
                .write(to: script, atomically: true, encoding: .utf8)
            var saved = fixture.session(1, messages: false)
            saved.customCommand = "/bin/sh " + AgentCommand.quotedArgument(script.path)
            let (window, sidebar) = try await fixture.restored(saved)
            let session = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle({ session.model.phase == .ready }, timeout: 10)
            let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), 0, "The agent is running")
            XCTAssertNil(session.model.remoteBinding, "Nothing on this Mac outlives Latch")

            await window.shutdown()
            try await fixture.settle({ kill(pid, 0) != 0 }, timeout: 10)
            let library = try await fixture.store.load()
            XCTAssertNil(library.sessions.first?.remote)
        }
    }

    // MARK: The model alone

    func testARequestDeliveredTwiceIsShownAndAnsweredOnce() async throws {
        let client = DuplicatingRemoteClient()
        let model = SessionModel(makeClient: { client })
        await model.connect(remote: .custom("agent"), path: "/srv/app")
        XCTAssertEqual(model.phase, .ready)
        var sheets: [UUID] = []
        model.onChange = { [weak model] in
            if let id = model?.permissions.current?.id, sheets.last != id { sheets.append(id) }
        }
        let sending = Task { await model.send("permission please") }
        // Both deliveries, and the event after them, have been taken in.
        try await eventually("the events after the request") { model.appliedSequence == 3 }
        let request = try XCTUnwrap(model.permissions.current)
        model.permissions.resolve(id: request.id, optionID: "allow")
        await sending.value
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(client.resolutions.count, 1)
        XCTAssertEqual(model.status, "Ready · end_turn")
    }
}

/// Delivers the one permission request of each prompt twice, as a server can after a
/// re-attach, and answers the prompt once the request is resolved.
private final class DuplicatingRemoteClient: AgentServiceClient {
    let events: AsyncStream<LatchAgentEvent>
    let remoteEvents: AsyncStream<RemoteServiceEvent>?
    var isRemote: Bool { true }
    private let lifetime: AsyncStream<LatchAgentEvent>.Continuation
    private let continuation: AsyncStream<RemoteServiceEvent>.Continuation
    private let state = Mutex<(resolutions: [ACPPermissionOutcome], waiter: CheckedContinuation<Void, Never>?)>(([], nil))

    init() {
        (events, lifetime) = AsyncStream.makeStream()
        let (stream, continuation) = AsyncStream<RemoteServiceEvent>.makeStream()
        remoteEvents = stream
        self.continuation = continuation
    }

    var resolutions: [ACPPermissionOutcome] { state.withLock { $0.resolutions } }

    func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init()))
    }

    func prompt(runtimeID id: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock]) async throws -> LatchAgentResponse {
        let requestID = UUID()
        let request = ACPPermissionRequest(sessionId: "remote-session", toolCall: .object(["toolCallId": .string("edit")]),
                                           options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")])
        await withCheckedContinuation { waiter in
            state.withLock { $0.waiter = waiter }
            for sequence in [UInt64(1), 2] {
                continuation.yield(.agent(.permissionRequested(runtimeID: id, requestID: requestID, request: request),
                                          sequence: sequence))
            }
            continuation.yield(.skipped(runtimeID: id, sequence: 3))
        }
        return .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn"))
    }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: "remote-session"))
        case let .resolvePermission(id, requestID, outcome):
            let waiter = state.withLock { state in
                state.resolutions.append(outcome)
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
            return .permissionResolved(runtimeID: id, requestID: requestID)
        case let .stopRuntime(id):
            return .runtimeStopped(runtimeID: id)
        default:
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected command")
        }
    }

    func close() {
        continuation.finish()
        lifetime.finish()
    }

    var transportDescription: String { "remote test double" }
}

/// Stands in for user notifications, which need a bundle identifier and would ask this
/// machine's user for authorization during a test run.
@MainActor
final class NotificationRecorder: AttentionPresenting {
    struct Post {
        let id: String
        let body: String
        let userInfo: [String: String]
    }

    var onAction: ((String, [String: String]) -> Void)?
    private(set) var posts: [Post] = []

    func post(id: String, title: String, body: String, actions: [AttentionAction], userInfo: [String: String]) {
        posts.append(Post(id: id, body: body, userInfo: userInfo))
    }

    func withdraw(id: String) {}
}
