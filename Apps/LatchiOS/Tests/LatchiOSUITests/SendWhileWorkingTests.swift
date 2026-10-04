import LatchACP
import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// Messages written while the agent works: into its turn for an agent that steers, as Claude
/// Code does, and otherwise waiting over the composer, in order, until the turn ends. Stop
/// gives what waits back to the composer, so nothing written is lost.
@MainActor
final class SendWhileWorkingTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach(Snapshot.tearDown)
        windows = []
        try await super.tearDown()
    }

    /// A session screen with a turn running.
    private func working(_ client: ScriptedSessionClient = ScriptedSessionClient()) async -> SessionScreenFixture {
        let fixture = SessionScreenFixture(client: client)
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.connect()
        fixture.type("Run the tests")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn && fixture.model.phase == .prompting }
        return fixture
    }

    private func queue(_ text: String, in fixture: SessionScreenFixture) {
        fixture.type(text)
        fixture.screen.composer.actionButton.sendActions(for: .primaryActionTriggered)
    }

    private func texts(_ fixture: SessionScreenFixture) -> [String] { fixture.model.messages.map(\.text) }

    func testSendStaysWhileTheAgentWorksAndMessagesWaitTheirTurn() async throws {
        let fixture = await working()
        let composer = fixture.screen.composer
        XCTAssertEqual(composer.action, .stop(enabled: true), "Nothing to send: Stop alone")
        XCTAssertTrue(composer.stopButton.isHidden)
        XCTAssertTrue(composer.queueView.isHidden)

        fixture.type("Then commit")
        XCTAssertEqual(composer.action, .sendWhileWorking(steers: false, canStop: true))
        XCTAssertEqual(composer.actionButton.accessibilityLabel, "Send")
        XCTAssertEqual(composer.actionButton.accessibilityHint, "Sends when the agent finishes.")
        XCTAssertFalse(composer.stopButton.isHidden, "Stop stays in reach beside Send")
        XCTAssertEqual(composer.stopButton.accessibilityLabel, "Stop")
        XCTAssertTrue(fixture.screen.canPerformAction(#selector(SessionDetailViewController.sendCommand), withSender: nil))
        XCTAssertTrue(fixture.screen.canPerformAction(#selector(SessionDetailViewController.stopCommand), withSender: nil))

        composer.actionButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(fixture.model.queuedPrompts.map(\.text), ["Then commit"])
        XCTAssertEqual(composer.text, "")
        XCTAssertEqual(fixture.drafts.last, "", "The saved draft is empty too")
        XCTAssertEqual(composer.action, .stop(enabled: true))
        XCTAssertFalse(composer.queueView.isHidden)
        XCTAssertEqual(composer.queueView.headingLabel.text, "Sends when the agent finishes")
        XCTAssertEqual(composer.queueView.rows.map(\.label.text), ["Then commit"])

        // From the keyboard too.
        fixture.type("And push\nto main")
        fixture.screen.sendCommand()
        XCTAssertEqual(composer.queueView.headingLabel.text, "2 messages send in turn when the agent finishes")
        XCTAssertEqual(composer.queueView.rows.map(\.label.text), ["Then commit", "And push"], "Each by its first line")
        XCTAssertEqual(composer.queueView.rows.map(\.edit.configuration?.title), ["Edit", "Edit"])
        XCTAssertEqual(composer.queueView.rows.map(\.remove.accessibilityLabel), ["Remove", "Remove"])
        XCTAssertEqual(fixture.client.prompts.count, 1, "Nothing goes while the turn runs")

        fixture.client.endTurn()
        await waitUntil("the first to go") { fixture.client.prompts.count == 2 && fixture.client.hasOpenTurn }
        XCTAssertEqual(fixture.client.prompts.last, [.text("Then commit")])
        await waitUntil("the queue to follow") { composer.queueView.rows.map(\.label.text) == ["And push"] }
        XCTAssertEqual(composer.queueView.headingLabel.text, "Sends when the agent finishes")
        fixture.client.endTurn()
        await waitUntil("the second to go") { fixture.client.prompts.count == 3 && fixture.client.hasOpenTurn }
        XCTAssertEqual(fixture.client.prompts.last, [.text("And push\nto main")])
        await waitUntil("the queue to go") { composer.queueView.isHidden }
        fixture.client.endTurn()
        await waitUntil("the end") { fixture.model.phase == .ready }
        XCTAssertEqual(texts(fixture), ["Run the tests", "Then commit", "And push\nto main"])
    }

    func testEditPutsAMessageBackInTheComposerAndRemoveTakesItOut() async throws {
        let fixture = await working()
        let composer = fixture.screen.composer
        queue("First", in: fixture)
        queue("Second\nwith more", in: fixture)
        fixture.type("Half written")

        composer.queueView.rows[1].edit.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(composer.text, "Second\nwith more\n\nHalf written", "Back before what the composer held")
        XCTAssertEqual(fixture.drafts.last, composer.text)
        XCTAssertEqual(fixture.model.queuedPrompts.map(\.text), ["First"])
        XCTAssertEqual(composer.queueView.rows.map(\.label.text), ["First"])

        composer.queueView.rows[0].remove.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(fixture.model.queuedPrompts.isEmpty)
        XCTAssertTrue(composer.queueView.isHidden)
        XCTAssertEqual(composer.text, "Second\nwith more\n\nHalf written", "Removing leaves the composer as it was")

        fixture.client.endTurn()
        await waitUntil("the turn's end") { fixture.model.phase == .ready }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.client.prompts.count, 1, "What was taken out never went")
    }

    func testStopGivesWhatWaitsBackToTheComposerWithItsPhotos() async throws {
        let fixture = await working()
        let composer = fixture.screen.composer
        queue("One", in: fixture)
        let photo = try XCTUnwrap(ComposerImage.make(from: SessionDetailViewControllerTests.pngData(width: 400, height: 300),
                                                     name: "Screen"))
        fixture.screen.add([photo])
        queue("", in: fixture)
        XCTAssertEqual(composer.queueView.rows.map(\.label.text), ["One", "1 photo"], "A photo alone reads as one")
        XCTAssertEqual(composer.queueView.rows.map(\.photos.isHidden), [true, true])
        XCTAssertTrue(composer.attachments.isEmpty, "The photo went with its message")
        fixture.type("Three")

        composer.stopButton.sendActions(for: .primaryActionTriggered)
        await waitUntil("the stop") { fixture.model.phase == .ready }
        XCTAssertTrue(fixture.model.queuedPrompts.isEmpty)
        XCTAssertTrue(composer.queueView.isHidden)
        XCTAssertEqual(composer.text, "One\n\nThree")
        XCTAssertEqual(fixture.drafts.last, "One\n\nThree")
        XCTAssertEqual(composer.attachments.map(\.id), [photo.id], "The photo is back, ready to go again")
        XCTAssertNotNil(composer.attachments.first?.thumbnail)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.client.prompts.count, 1, "Nothing waiting went after Stop")
    }

    /// The text gives way to the buttons; the photos with it stay in sight.
    func testAMessagesPhotosStayInSightBesideItsText() async throws {
        let fixture = await working()
        let photos = (0..<2).compactMap {
            ComposerImage.make(from: SessionDetailViewControllerTests.pngData(width: 40, height: 40), name: "Photo \($0)")
        }
        fixture.screen.add(photos)
        queue("Compare these two runs of the reconnect test on the Linux runner, side by side", in: fixture)
        let row = try XCTUnwrap(fixture.screen.composer.queueView.rows.first)
        XCTAssertEqual(row.label.text, "Compare these two runs of the reconnect test on the Linux runner, side by side")
        XCTAssertEqual(row.photos.text, "+ 2 photos")
        XCTAssertFalse(row.photos.isHidden)
        XCTAssertEqual(row.label.accessibilityLabel,
                       "Compare these two runs of the reconnect test on the Linux runner, side by side + 2 photos")
        fixture.screen.composer.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(row.photos.bounds.width + 0.5, row.photos.intrinsicContentSize.width, "Never cut short")
        fixture.client.endTurn()
    }

    func testAMessageGoesIntoTheTurnOfAnAgentThatSteers() async throws {
        let fixture = await working(ScriptedSessionClient(steers: true))
        let composer = fixture.screen.composer
        XCTAssertTrue(fixture.model.steersPrompts)
        fixture.type("Also check Linux")
        XCTAssertEqual(composer.action, .sendWhileWorking(steers: true, canStop: true))
        XCTAssertEqual(composer.actionButton.accessibilityHint, "The agent takes it at its next step.")
        composer.actionButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(composer.text, "", "The composer clears at once")
        XCTAssertEqual(fixture.drafts.last, "")
        await waitUntil("the steer") { fixture.client.steered == [[.text("Also check Linux")]] }
        await waitUntil("the message where it went in") { self.texts(fixture).last == "Also check Linux" }
        XCTAssertEqual(fixture.model.messages.last?.role, .user)
        XCTAssertTrue(fixture.model.queuedPrompts.isEmpty)
        XCTAssertTrue(composer.queueView.isHidden, "Nothing waits")
        XCTAssertEqual(fixture.client.prompts.count, 1, "It went into the turn, not as a prompt of its own")
        XCTAssertEqual(fixture.model.phase, .prompting)
        fixture.client.endTurn()
    }

    /// After Stop, a message waits for the turn to end rather than going into it.
    func testAfterStopAMessageWaitsRatherThanSteering() async throws {
        let client = ScriptedSessionClient(steers: true)
        client.finishLateOnCancel()
        let fixture = await working(client)
        await fixture.model.cancel()
        XCTAssertTrue(fixture.model.cancellationRequested)
        XCTAssertEqual(fixture.model.phase, .prompting, "Stopping…, until the agent ends the turn")
        fixture.type("Start again with the Linux runner")
        XCTAssertEqual(fixture.screen.composer.action, .sendWhileWorking(steers: false, canStop: false))
        fixture.screen.send()
        XCTAssertEqual(fixture.model.queuedPrompts.map(\.text), ["Start again with the Linux runner"])
        XCTAssertTrue(client.steered.isEmpty)
        client.endTurn(stopReason: "cancelled")
        await waitUntil("it goes once the turn has stopped") { client.prompts.last == [.text("Start again with the Linux runner")] }
        client.endTurn()
    }

    /// One that finds the turn over by the time it arrives waits for the next turn instead.
    func testASteerTheTurnDoesNotTakeWaitsItsTurn() async throws {
        let client = ScriptedSessionClient(steers: true)
        client.declineSteers()
        let fixture = await working(client)
        fixture.type("Too late")
        fixture.screen.send()
        await waitUntil("the message to wait") { fixture.model.queuedPrompts.map(\.text) == ["Too late"] }
        XCTAssertEqual(fixture.screen.composer.queueView.rows.map(\.label.text), ["Too late"])
        fixture.type("Next")
        XCTAssertEqual(fixture.screen.composer.action, .sendWhileWorking(steers: false, canStop: true),
                       "With one waiting, the next waits behind it")
        fixture.client.endTurn()
        await waitUntil("it goes") { fixture.client.prompts.last == [.text("Too late")] }
        fixture.client.endTurn()
    }

    /// With no screen on the session, what Stop gives back goes into the saved draft, and its
    /// photos wait for the next screen.
    func testWithoutAScreenWhatWaitsGoesBackToTheDraft() async throws {
        let connector = ScriptedConnector()
        let session = PhoneSession(serverID: UUID(), path: "/srv", agent: .claudeCode, customCommand: "", connector: connector)
        session.connect()
        await session.settled()
        let client = try XCTUnwrap(connector.latest)
        let turn = Task { await session.model.send("Long job") }
        await waitUntil("the turn") { client.hasOpenTurn }
        let photo = try XCTUnwrap(ComposerImage.make(from: SessionDetailViewControllerTests.pngData(width: 40, height: 40),
                                                     name: "Photo"))
        XCTAssertTrue(session.model.enqueue("Then this", attachments: [photo.prompt]))
        session.draft = "Typed meanwhile"
        XCTAssertEqual(session.savedSession.draft, "Then this\n\nTyped meanwhile",
                       "Saved with the draft, should iOS end the app before the turn does")
        XCTAssertEqual(session.draft, "Typed meanwhile", "The composer's own draft is unchanged while it waits")
        await session.stop()
        XCTAssertEqual(session.draft, "Then this\n\nTyped meanwhile")
        XCTAssertEqual(session.savedSession.draft, "Then this\n\nTyped meanwhile", "Saved once, not twice")
        XCTAssertEqual(session.returnedAttachments.map(\.id), [photo.prompt.id])
        XCTAssertEqual(session.takeReturnedAttachments().map(\.id), [photo.prompt.id])
        XCTAssertTrue(session.returnedAttachments.isEmpty, "Taken once, by the screen that shows them")
        client.endTurn()
        await turn.value
        client.close()
    }

    /// Stop Agent from the list, with the session's screen up: the screen's composer takes back
    /// what waited.
    func testStopAgentFromTheListGivesWhatWaitsToTheOpenScreen() async throws {
        let vps = Fake.server("vps")
        let store = InMemoryServerStore([vps])
        let connector = FakeConnector()
        let library = SessionLibrary(servers: store, connector: connector, store: nil, listRuntimes: { _ in [] })
        let root = RootViewController(library: library, servers: store, check: { _ in throw LatchRemoteClientError.timedOut },
                                      badge: nil, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        windows.append(Snapshot.host(root, appearance: .light, navigation: false))
        let session = library.create(serverID: vps.id, path: "/srv", agent: .fx)
        root.show(session)
        let screen = try XCTUnwrap(root.shown?.controller as? SessionDetailViewController)
        try await eventually("the agent") { session.model.phase == .ready }
        screen.composer.textView.text = "Start"
        screen.composer.textViewDidChange(screen.composer.textView)
        screen.send()
        try await eventually("the turn") { connector.clients.first?.isRunningTurn == true && session.model.phase == .prompting }
        screen.composer.textView.text = "Waiting"
        screen.composer.textViewDidChange(screen.composer.textView)
        screen.send()
        XCTAssertEqual(session.model.queuedPrompts.map(\.text), ["Waiting"])
        XCTAssertEqual(session.draft, "")
        await library.stop(session)
        XCTAssertEqual(screen.composer.text, "Waiting")
        XCTAssertEqual(session.draft, "Waiting", "Saved with the session")
        connector.clients.first?.finishTurn()
    }

    func testAQueuedMessageReadsAsOneLine() {
        func line(_ text: String, photos: Int = 0) -> String { SessionQueueView.line(text: text, photos: photos) }
        XCTAssertEqual(line("Run it again"), "Run it again")
        XCTAssertEqual(line("\n  Run it again  \nand then more"), "Run it again")
        XCTAssertEqual(line("Look", photos: 1), "Look + 1 photo")
        XCTAssertEqual(line("", photos: 3), "3 photos")
        XCTAssertEqual(SessionQueueView.draft(returning: ["A", " "], before: ""), "A")
        XCTAssertEqual(SessionQueueView.draft(returning: ["A", "B"], before: "C"), "A\n\nB\n\nC")
        XCTAssertEqual(SessionQueueView.heading(count: 1), "Sends when the agent finishes")
        XCTAssertEqual(SessionQueueView.heading(count: 3), "3 messages send in turn when the agent finishes")
    }
}
