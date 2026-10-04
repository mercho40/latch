import LatchACP
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// The agent's own conversations: a new session takes up one it saved, as Resume Conversation…
/// does, and a conversation forks into a session beside it, for an agent that does either, as
/// Claude Code does. And what its tool calls return besides text.
@MainActor
final class AgentConversationsTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach(Snapshot.tearDown)
        windows = []
        try await super.tearDown()
    }

    static let older = ACPSessionSummary(sessionId: "older-1", cwd: "/home/simon/latch", title: "Keep the port across restarts",
                                         updatedAt: "2026-09-01T10:00:00Z")
    static let newer = ACPSessionSummary(sessionId: "newer-1", cwd: "/home/simon/latch", title: "Fix the flaky reconnect test",
                                         updatedAt: "2026-10-01T12:30:00.250+02:00")
    static let undated = ACPSessionSummary(sessionId: "undated-1", cwd: "/home/simon/latch")

    private func shown(_ client: ScriptedSessionClient) -> SessionScreenFixture {
        let fixture = SessionScreenFixture(client: client)
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        return fixture
    }

    /// The menu's section of what the agent can do with the conversation, by title, with
    /// whether each can run now.
    private func conversationItems(_ fixture: SessionScreenFixture) throws -> [String: Bool] {
        let menu = try XCTUnwrap(fixture.screen.menuButton.menu)
        let actions = menu.children.compactMap { $0 as? UIMenu }.flatMap(\.children).compactMap { $0 as? UIAction }
        return Dictionary(uniqueKeysWithValues: actions.filter { ["Fork Conversation", "Resume Conversation…"].contains($0.title) }
            .map { ($0.title, !$0.attributes.contains(.disabled)) })
    }

    private func emptyPage(_ fixture: SessionScreenFixture) -> UIContentUnavailableConfiguration? {
        (fixture.transcript.collectionView.backgroundView as? UIContentUnavailableView)?.configuration
            as? UIContentUnavailableConfiguration
    }

    // MARK: Resume

    func testResumeIsOfferedInAnEmptySessionOfAnAgentThatListsItsConversations() async throws {
        let fixture = shown(ScriptedSessionClient(conversations: [Self.older]))
        XCTAssertEqual(try conversationItems(fixture), [:], "Not before the agent says it lists them")
        await fixture.connect()
        XCTAssertEqual(try conversationItems(fixture), ["Resume Conversation…": true])
        XCTAssertTrue(fixture.screen.canPerformAction(#selector(SessionDetailViewController.resumeConversationCommand), withSender: nil))
        XCTAssertEqual(emptyPage(fixture)?.button.title, "Resume Conversation…", "The empty page offers it too")

        fixture.type("Why does it fail?")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        XCTAssertEqual(try conversationItems(fixture), [:], "A session that holds a conversation keeps it")
        XCTAssertFalse(fixture.screen.canPerformAction(#selector(SessionDetailViewController.resumeConversationCommand), withSender: nil))
        fixture.client.endTurn()
    }

    func testAnAgentThatListsNothingOffersNoResume() async throws {
        let fixture = shown(ScriptedSessionClient())
        await fixture.connect()
        XCTAssertEqual(try conversationItems(fixture), [:])
        XCTAssertNil(emptyPage(fixture)?.button.title)
        XCTAssertFalse(fixture.screen.canResumeConversation)
    }

    func testResumeListsTheConversationsNewestFirstAndTakesOneUpWithItsHistory() async throws {
        let client = ScriptedSessionClient(conversations: [Self.older, Self.undated, Self.newer])
        client.replayOnLoad([(kind: "user_message_chunk", text: "Why does the reconnect test fail?"),
                             (kind: "agent_message_chunk", text: "The port is still in TIME_WAIT.")])
        let fixture = shown(client)
        await fixture.connect()
        fixture.screen.resumeConversation()
        await waitUntil("the list") { fixture.presentedSheets.last is UINavigationController }
        let sheet = try XCTUnwrap(fixture.presentedSheets.last as? UINavigationController)
        let picker = try XCTUnwrap(sheet.topViewController as? ConversationPickerViewController)
        XCTAssertTrue(fixture.screen.conversationPicker === picker)
        XCTAssertEqual(picker.title, "Resume Conversation")
        XCTAssertEqual(picker.conversations.map(\.sessionId), ["newer-1", "older-1", "undated-1"], "Newest first, undated last")
        picker.loadViewIfNeeded()
        let table = picker.tableView!
        let first = try XCTUnwrap(picker.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0)).contentConfiguration
            as? UIListContentConfiguration)
        XCTAssertEqual(first.text, "Fix the flaky reconnect test")
        let expected = try XCTUnwrap(ConversationPickerViewController.date(of: Self.newer))
        XCTAssertEqual(expected.timeIntervalSince1970, 1_790_850_600.25, accuracy: 0.01, "Read in the time zone it was written in")
        XCTAssertEqual(first.secondaryText, expected.formatted(date: .abbreviated, time: .shortened))
        let untitled = picker.tableView(table, cellForRowAt: IndexPath(row: 2, section: 0)).contentConfiguration as? UIListContentConfiguration
        XCTAssertEqual(untitled?.text, "Untitled Conversation")
        XCTAssertNil(untitled?.secondaryText)
        XCTAssertEqual(picker.tableView(table, titleForFooterInSection: 0),
                       "Claude Code’s saved conversations in ~/latch. The one you choose goes on in this session, with its history.")

        picker.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertTrue(fixture.dismissedSheets.last === sheet)
        XCTAssertEqual(fixture.resumed.map(\.sessionId), ["newer-1"])
        await waitUntil("the conversation's history") {
            fixture.model.phase == .ready
                && fixture.model.messages.map(\.text) == ["Why does the reconnect test fail?", "The port is still in TIME_WAIT."]
        }
        XCTAssertEqual(fixture.model.messages.first?.role, .user)
        XCTAssertEqual(fixture.model.savedAgentSessionID, "newer-1")
        XCTAssertTrue(client.commands.contains { if case .loadSession(_, "newer-1", "/home/simon/latch") = $0 { true } else { false } })
        await waitUntil("the transcript") { fixture.transcript.order.count == 2 }
        XCTAssertEqual(try conversationItems(fixture), [:], "It holds a conversation now")
    }

    func testCancelLeavesTheSessionAsItWas() async throws {
        let fixture = shown(ScriptedSessionClient(conversations: [Self.older]))
        await fixture.connect()
        fixture.screen.resumeConversation()
        await waitUntil("the list") { fixture.screen.conversationPicker != nil }
        let picker = try XCTUnwrap(fixture.screen.conversationPicker)
        let cancel = try XCTUnwrap(picker.navigationItem.leftBarButtonItem?.primaryAction)
        cancel.performWithSender(nil, target: nil)
        XCTAssertTrue(fixture.dismissedSheets.last === picker.navigationController)
        XCTAssertTrue(fixture.resumed.isEmpty)
        XCTAssertTrue(fixture.screen.canResumeConversation, "It can be asked again")
    }

    func testAnAgentWithNoOtherConversationsSaysSo() async throws {
        let fixture = shown(ScriptedSessionClient(conversations: []))
        await fixture.connect()
        fixture.screen.resumeConversation()
        await waitUntil("the list") { fixture.screen.conversationPicker != nil }
        let picker = try XCTUnwrap(fixture.screen.conversationPicker)
        picker.loadViewIfNeeded()
        let empty = try XCTUnwrap(picker.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)
        XCTAssertEqual(empty.text, "No Conversations to Resume")
        XCTAssertEqual(empty.secondaryText, "Claude Code has no other saved conversations in ~/latch.")
        XCTAssertEqual(picker.numberOfSections(in: picker.tableView), 0)
    }

    func testAListThatFailsSaysWhy() async throws {
        let client = ScriptedSessionClient(conversations: [Self.older])
        client.failListing(with: UnreachableServer(message: "vps did not answer."))
        let fixture = shown(client)
        await fixture.connect()
        fixture.screen.resumeConversation()
        await waitUntil("the alert") { fixture.presentedSheets.last is UIAlertController }
        let alert = try XCTUnwrap(fixture.presentedSheets.last as? UIAlertController)
        XCTAssertEqual(alert.title, "Couldn’t List the Conversations")
        XCTAssertEqual(alert.message, "vps did not answer.")
        XCTAssertEqual(alert.actions.map(\.title), ["OK"])
        XCTAssertFalse(fixture.screen.listingConversations)
        XCTAssertTrue(fixture.screen.canResumeConversation)
    }

    /// The session's title is the conversation's, and the agent's own later title replaces it,
    /// as one it gave.
    func testAResumedSessionTakesTheConversationsTitleUntilTheAgentGivesAnother() async throws {
        let connector = ScriptedConnector()
        let session = PhoneSession(serverID: UUID(), path: "/home/simon/latch", agent: .claudeCode, customCommand: "",
                                   connector: connector)
        session.connect()
        await session.settled()
        let client = try XCTUnwrap(connector.latest)
        session.resume(ACPSessionSummary(sessionId: "older-1", cwd: "/home/simon/latch",
                                         title: "Keep the port across restarts\nand test it"))
        XCTAssertEqual(session.title, "Keep the port across restarts")
        await session.settled()
        XCTAssertEqual(session.model.phase, .ready)
        XCTAssertEqual(session.savedSession.agentSessionID, "older-1")
        XCTAssertEqual(session.savedSession.adoptedAgentTitle, "Keep the port across restarts")
        client.title("Reuse the listener's port")
        await waitUntil("the agent's title") { session.title == "Reuse the listener's port" }
        XCTAssertEqual(PhoneSession.title(resuming: ACPSessionSummary(sessionId: "x", cwd: "/", title: "  ")), "Resumed Conversation")
        XCTAssertEqual(PhoneSession.title(resuming: ACPSessionSummary(sessionId: "x", cwd: "/")), "Resumed Conversation")
        client.close()
    }

    // MARK: Fork

    func testForkIsOfferedForAConversationOfAnAgentThatForks() async throws {
        let fixture = shown(ScriptedSessionClient(forks: true))
        await fixture.connect()
        XCTAssertEqual(try conversationItems(fixture), [:], "Nothing to fork yet")
        fixture.type("Why does it fail?")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        XCTAssertEqual(try conversationItems(fixture), ["Fork Conversation": false], "Not while the agent works")
        XCTAssertFalse(fixture.screen.canPerformAction(#selector(SessionDetailViewController.forkConversationCommand), withSender: nil))
        fixture.client.endTurn()
        await waitUntil("the turn's end") { fixture.model.phase == .ready }
        XCTAssertEqual(try conversationItems(fixture), ["Fork Conversation": true])
        XCTAssertTrue(fixture.screen.canPerformAction(#selector(SessionDetailViewController.forkConversationCommand), withSender: nil))

        fixture.screen.forkConversation()
        await waitUntil("the fork") { fixture.forks == [ScriptedSessionClient.forkedSessionID] }
        XCTAssertTrue(fixture.client.commands.contains {
            if case .forkSession(_, ScriptedSessionClient.sessionID, "/home/simon/latch") = $0 { true } else { false }
        })
        XCTAssertFalse(fixture.screen.forking)
        XCTAssertEqual(fixture.model.messages.map(\.text), ["Why does it fail?"], "This conversation stays as it is")
    }

    func testAnAgentThatCannotForkOffersNoFork() async throws {
        let fixture = shown(ScriptedSessionClient())
        await fixture.resume(SampleConversation.messages)
        XCTAssertEqual(try conversationItems(fixture), [:])
        XCTAssertFalse(fixture.screen.canForkConversation)
    }

    /// Through the root, as the menu does it: the fork opens beside the session with a copy of
    /// its transcript, and loads the agent's copy of the conversation. Removing the fork keeps
    /// the pictures of photos the two share.
    func testAForkOpensBesideTheSessionAndGoesOnWithTheCopy() async throws {
        let vps = Fake.server("vps")
        let store = InMemoryServerStore([vps])
        let connector = ForkingConnector()
        let library = SessionLibrary(servers: store, connector: connector, store: nil, listRuntimes: { _ in [] })
        let root = RootViewController(library: library, servers: store, check: { _ in throw LatchRemoteClientError.timedOut },
                                      badge: nil, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        windows.append(Snapshot.host(root, appearance: .light, navigation: false))
        let messages = SampleConversation.messages
        let saved = SavedSession(id: UUID(), workspacePath: "/home/simon/latch", title: "Fix the flaky reconnect test",
                                 agentID: AgentPreset.claudeCode.rawValue, customCommand: "", draft: "Half written",
                                 messages: messages, agentSessionID: ScriptedSessionClient.sessionID,
                                 lastActiveAt: Date(timeIntervalSinceNow: -3600), serverID: vps.id)
        let session = PhoneSession(saved: saved, connector: connector)
        library.add(session)
        SentImageCache.shared.store([UIImage(systemName: "photo")], for: SampleConversation.followUp.id)
        defer { SentImageCache.shared.remove([SampleConversation.followUp.id]) }
        root.show(session)
        let screen = try XCTUnwrap(root.shown?.controller as? SessionDetailViewController)
        try await eventually("the session resumed") { session.model.phase == .ready }
        XCTAssertTrue(screen.canForkConversation)

        screen.forkConversation()
        try await eventually("the fork on screen") { root.shown.map { $0.session !== session } == true }
        let fork = try XCTUnwrap(root.shown?.session)
        XCTAssertTrue(library.sessions.contains { $0 === fork })
        XCTAssertNotEqual(fork.id, session.id)
        XCTAssertEqual(fork.title, "Fix the flaky reconnect test (fork)")
        XCTAssertEqual(fork.draft, "", "The draft stays with the session it was written in")
        XCTAssertEqual(fork.serverID, vps.id)
        XCTAssertEqual(fork.path, "/home/simon/latch")
        XCTAssertEqual(fork.model.messages.map(\.text), messages.map(\.text))
        XCTAssertEqual(library.selectedSessionID, fork.id)
        try await eventually("the fork resumed") { fork.model.phase == .ready }
        let forkClient = try XCTUnwrap(connector.clients.last)
        XCTAssertTrue(forkClient.commands.contains {
            if case .loadSession(_, ScriptedSessionClient.forkedSessionID, "/home/simon/latch") = $0 { true } else { false }
        }, "It loads the agent's copy")
        XCTAssertEqual(fork.model.messages.map(\.text), messages.map(\.text), "The copied transcript stays")
        XCTAssertEqual(fork.savedSession.agentSessionID, ScriptedSessionClient.forkedSessionID)
        XCTAssertNil(fork.savedSession.adoptedAgentTitle)
        XCTAssertEqual(session.draft, "Half written")
        XCTAssertEqual(session.savedSession.agentSessionID, ScriptedSessionClient.sessionID)

        await library.remove(fork)
        XCTAssertFalse(SentImageCache.shared.images(for: SampleConversation.followUp.id).isEmpty,
                       "The session the fork was copied from still shows its photo")
    }

    // MARK: Tool results

    /// Claude Code's Bash output comes fenced as `console`, which the details show without the
    /// fence; an image or a resource the call returned is named, in grey.
    func testToolDetailsUnwrapCommandOutputAndNameImages() async throws {
        let fixture = shown(ScriptedSessionClient())
        await fixture.connect()
        fixture.type("List the files")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        fixture.client.tool("ls", title: "`ls`", status: "completed", content: "```console\n$ ls\nREADME.md\n```",
                            blocks: [.object(["type": .string("image"), "mimeType": .string("image/png"),
                                              "data": .string(String(repeating: "A", count: 4096))]),
                                     .object(["type": .string("resource_link"), "name": .string("notes"),
                                              "uri": .string("file:///home/simon/notes.md")])],
                            kind: "execute")
        await waitUntil("the call") { fixture.transcript.order.count == 2 }
        let id = fixture.model.messages[1].id
        fixture.cell(for: id, as: ToolCallCell.self)?.header.sendActions(for: .primaryActionTriggered)
        await waitUntil("its details") { fixture.cell(for: id, as: ToolCallCell.self)?.isExpanded == true }
        let details = try XCTUnwrap(fixture.cell(for: id, as: ToolCallCell.self)?.detailsView.attributedText)
        XCTAssertTrue(details.string.contains("$ ls\nREADME.md"), details.string)
        XCTAssertFalse(details.string.contains("```"), "No fence: " + details.string)
        let image = (details.string as NSString).range(of: "[Image: image/png · 3 KB]")
        XCTAssertNotEqual(image.location, NSNotFound, details.string)
        XCTAssertEqual(details.attribute(.foregroundColor, at: image.location, effectiveRange: nil) as? UIColor, .secondaryLabel)
        let resource = (details.string as NSString).range(of: "[Resource: notes: file:///home/simon/notes.md]")
        XCTAssertNotEqual(resource.location, NSNotFound, details.string)
        XCTAssertEqual(details.attribute(.foregroundColor, at: resource.location, effectiveRange: nil) as? UIColor, .secondaryLabel)
        let output = (details.string as NSString).range(of: "README.md")
        XCTAssertEqual(details.attribute(.foregroundColor, at: output.location, effectiveRange: nil) as? UIColor, .label)
        fixture.client.endTurn()
    }
}

/// Every session's agent lists and forks; the clients are kept, the latest last.
@MainActor
private final class ForkingConnector: RemoteSessionConnector {
    private(set) var clients: [ScriptedSessionClient] = []

    func makeClient(serverID: UUID) -> AgentServiceClient {
        let client = ScriptedSessionClient(conversations: [], forks: true)
        clients.append(client)
        return client
    }
}
