import AppKit
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKitTestSupport
import XCTest
@testable import LatchMacUI
@testable import LatchSessionKit

/// Remote sessions in a window, against a real `latch-server` on loopback: the banner, the
/// sidebar and the Servers pane over what the shared session layer's own tests cover.
@MainActor
final class RemoteSessionLiveWindowTests: XCTestCase {
    private let quickBackoff = LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200))

    private func connector(_ server: LoopbackServer, backoff: LatchRemoteBackoff? = nil,
                           wake: NotificationCenter = NotificationCenter()) -> ChannelRemoteSessionConnector {
        ChannelRemoteSessionConnector(servers: server.store, backoff: backoff ?? quickBackoff, notificationCenter: wake)
    }

    private func texts(_ model: SessionModel) -> [String] { model.messages.map(\.text) }

    private func saved(_ fixture: WindowFixture, on server: LoopbackServer) -> SavedSession {
        var saved = fixture.session(1, messages: false)
        saved.workspacePath = server.workspace.path
        saved.serverID = server.profile.id
        saved.customCommand = ""
        return saved
    }

    /// The agent's question comes up as a sheet over the session, and what is chosen there
    /// reaches the agent on the server.
    func testTheAgentsQuestionIsAskedInASheetAndAnswered() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (_, sidebar) = try await fixture.restored(saved(fixture, on: server), servers: server.store,
                                                              remoteConnector: connector(server))
                let session = try XCTUnwrap(sidebar.selectedSession)
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
                let sending = Task { await session.model.send("question please") }
                try await fixture.settle({ session.questionSheet != nil }, timeout: 10)
                let sheet = try XCTUnwrap(session.questionSheet)
                XCTAssertTrue(sheet.panel.isSheet)
                sheet.choose(["SQLite"], for: "question_0")
                sheet.submit.performClick(nil)
                await sending.value
                XCTAssertNil(session.questionSheet)
                try await fixture.settle({ self.texts(session.model).last == "asking chose SQLite" }, timeout: 5)
            }
        }
    }

    /// Written while the agent works, a message waits over the composer and goes when the turn
    /// ends; Edit gives one back. Fork then copies the conversation into a new session that goes
    /// on with the agent's fork of it.
    func testAQueuedMessageWaitsItsTurnAndForkCopiesTheConversation() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, sidebar) = try await fixture.restored(saved(fixture, on: server), servers: server.store,
                                                                   remoteConnector: connector(server))
                let session = try XCTUnwrap(sidebar.selectedSession)
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
                session.submit("tools please")
                try await fixture.settle({ session.model.phase == .prompting && self.texts(session.model).contains("reading") }, timeout: 10)
                session.submit("Then say hello")
                session.submit("And this one I will edit")
                XCTAssertEqual(session.composerText, "")
                XCTAssertFalse(session.queuePanel.isHidden)
                XCTAssertEqual(session.queuePanel.rows.map(\.label.stringValue), ["Then say hello", "And this one I will edit"])
                session.queuePanel.rows[1].edit.performClick(nil)
                XCTAssertEqual(session.composerText, "And this one I will edit")
                XCTAssertEqual(session.queuePanel.rows.count, 1)

                FileManager.default.createFile(atPath: server.workspace.appendingPathComponent("go").path, contents: nil)
                try await fixture.settle({
                    session.model.phase == .ready && session.model.queuedPrompts.isEmpty && self.texts(session.model).last == "onetwothree"
                }, timeout: 10)
                XCTAssertTrue(session.queuePanel.isHidden)
                XCTAssertEqual(server.lines(in: "prompts.log"), 2)
                XCTAssertEqual(session.composerText, "And this one I will edit")

                XCTAssertTrue(session.canFork)
                window.forkSelectedSession(nil)
                try await fixture.settle({ sidebar.allSessions.count == 2 }, timeout: 10)
                let fork = try XCTUnwrap(sidebar.allSessions.first { $0 !== session })
                XCTAssertEqual(fork.savedSession.agentSessionID, "forked-1")
                XCTAssertEqual(fork.savedSession.messages.map(\.text), self.texts(session.model))
                XCTAssertEqual(fork.savedSession.draft, "")
                XCTAssertEqual(server.lines(in: "forks.log"), 1)
            }
        }
    }

    /// With an agent that steers, Send while it works puts the message into its turn: no queue,
    /// and the message shows where it went in.
    func testSendWhileTheAgentWorksSteersItsTurn() async throws {
        try await LoopbackServer.run { server in
            FileManager.default.createFile(atPath: server.workspace.appendingPathComponent("steers").path, contents: nil)
            try await WindowFixture.run { fixture in
                let (_, sidebar) = try await fixture.restored(saved(fixture, on: server), servers: server.store,
                                                              remoteConnector: connector(server))
                let session = try XCTUnwrap(sidebar.selectedSession)
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
                XCTAssertTrue(session.model.steersPrompts)
                session.submit("steerable please")
                try await fixture.settle({ self.texts(session.model).last == "working" }, timeout: 10)
                session.submit("also this")
                XCTAssertEqual(session.composerText, "")
                XCTAssertTrue(session.queuePanel.isHidden)
                try await fixture.settle({
                    session.model.phase == .ready && self.texts(session.model) == ["steerable please", "working", "also this", "heard"]
                }, timeout: 10)
                XCTAssertEqual(server.lines(in: "prompts.log"), 1)
                XCTAssertEqual(server.lines(in: "steers.log"), 1)
            }
        }
    }

    /// A new session lists the agent's other conversations, and the one chosen goes on in it
    /// with its history and title.
    func testANewSessionResumesOneOfTheAgentsConversations() async throws {
        try await LoopbackServer.run { server in
            try await WindowFixture.run { fixture in
                let (window, sidebar) = try await fixture.restored(saved(fixture, on: server), servers: server.store,
                                                                   remoteConnector: connector(server))
                let session = try XCTUnwrap(sidebar.selectedSession)
                try await fixture.settle({ session.model.phase == .ready }, timeout: 15)
                XCTAssertTrue(session.canResumeConversation)
                window.resumeConversation(nil)
                try await fixture.settle({ session.conversationAlert != nil }, timeout: 10)
                let (alert, picker) = try XCTUnwrap(session.conversationAlert)
                XCTAssertEqual(picker.itemTitles.count, 1)
                XCTAssertTrue(picker.itemTitles[0].hasPrefix("An older conversation — "), picker.itemTitles[0])
                alert.buttons[0].performClick(nil)
                try await fixture.settle({
                    session.model.phase == .ready && self.texts(session.model) == ["earlier question", "earlier answer", "Read history · completed"]
                }, timeout: 10)
                XCTAssertEqual(session.savedSession.agentSessionID, "older-1")
                XCTAssertEqual(session.savedSession.title, "An older conversation")
                XCTAssertFalse(session.canResumeConversation, "It holds a conversation now")
            }
        }
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
                // A turn ends only with its events, so they are all in.
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

    // MARK: Stopped on the server

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
                // A server that shut down may be back soon: the session resumes once it answers.
                XCTAssertEqual(session.banner.displayedMessage, "Latch starts it again, and resumes the conversation, once loopback answers.")
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
}
