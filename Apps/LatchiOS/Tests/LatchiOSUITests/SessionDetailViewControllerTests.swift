import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class SessionDetailViewControllerTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach(Snapshot.tearDown)
        windows = []
        try await super.tearDown()
    }

    private func show(_ fixture: SessionScreenFixture) {
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
    }

    private func sendPrompt(_ fixture: SessionScreenFixture, _ text: String) async {
        fixture.type(text)
        fixture.screen.send()
        await waitUntil("the prompt to reach the client") { fixture.client.hasOpenTurn }
    }

    // MARK: Transcript

    func testStreamingShowsEachKindOfRowAndReconfiguresOnlyWhatChanged() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Why does it fail?")
        fixture.client.chunk("Looking **now**")
        await waitUntil("the reply") { fixture.model.messages.count == 2 }
        let assistantID = fixture.model.messages[1].id
        await waitUntil("the reply to render") {
            (fixture.cell(for: assistantID, as: AssistantMessageCell.self)?.accessibilityLabel ?? "") == "Claude Code: Looking now"
        }
        let renders = fixture.transcript.cache.renderCount
        fixture.client.chunk(" and more")
        await waitUntil("the reply to grow") {
            (fixture.cell(for: assistantID, as: AssistantMessageCell.self)?.accessibilityLabel ?? "").hasSuffix("now and more")
        }
        XCTAssertEqual(fixture.transcript.cache.renderCount, renders + 1, "Only the reply that changed is rendered again")

        fixture.client.tool("t1", title: "Read Package.swift", status: "in_progress")
        await waitUntil("a tool call") { fixture.transcript.order.count == 3 }
        let messages = fixture.model.messages
        XCTAssertNotNil(fixture.cell(for: messages[0].id, as: UserMessageCell.self))
        XCTAssertNotNil(fixture.cell(for: messages[1].id, as: AssistantMessageCell.self))
        XCTAssertNotNil(fixture.cell(for: messages[2].id, as: ToolCallCell.self))
        fixture.client.tool("t1", title: "Read Package.swift", status: "completed")
        await waitUntil("the tool call to finish") {
            (fixture.cell(for: messages[2].id, as: ToolCallCell.self)?.header.accessibilityLabel ?? "").hasSuffix("Done")
        }
        XCTAssertEqual(fixture.transcript.cache.renderCount, renders + 1, "A tool update re-rendered the reply's Markdown")
        XCTAssertTrue(fixture.transcript.order.count == 3)
        fixture.client.endTurn()
        await waitUntil("the turn to end") { fixture.model.phase == .ready }
    }

    func testRowsSayWhoSpokeToVoiceOver() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.resume(SampleConversation.messages)
        await waitUntil("the transcript") { fixture.transcript.order.count == SampleConversation.messages.count }
        let user = try XCTUnwrap(fixture.cell(for: SampleConversation.prompt.id, as: UserMessageCell.self))
        XCTAssertEqual(user.accessibilityLabel, "You: \(SampleConversation.prompt.text)")
        XCTAssertEqual(user.accessibilityCustomActions?.map(\.name), ["Copy"])
        let reply = try XCTUnwrap(fixture.cell(for: SampleConversation.answer.id, as: AssistantMessageCell.self))
        XCTAssertTrue(reply.accessibilityLabel?.hasPrefix("Claude Code: What I found") ?? false, reply.accessibilityLabel ?? "")
        XCTAssertEqual(reply.accessibilityCustomActions?.map(\.name), ["Copy", "Copy as Markdown", "Copy Code", "Open SO_REUSEADDR"])
        let tool = try XCTUnwrap(fixture.cell(for: SampleConversation.read.id, as: ToolCallCell.self))
        XCTAssertEqual(tool.header.accessibilityLabel, "Tool: Read Tests/RemoteSessionLiveTests.swift, Done")
        let withImage = try XCTUnwrap(fixture.cell(for: SampleConversation.followUp.id, as: UserMessageCell.self))
        XCTAssertEqual(withImage.accessibilityLabel, "You: Here is the CI log from the last failure.. Attached: ci-log.jpg")
    }

    func testAToolCallExpandsToItsDetails() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.resume(SampleConversation.messages)
        await waitUntil("the transcript") { fixture.transcript.order.count == SampleConversation.messages.count }
        let id = SampleConversation.read.id
        var cell = try XCTUnwrap(fixture.cell(for: id, as: ToolCallCell.self))
        XCTAssertFalse(cell.isExpanded)
        XCTAssertEqual(cell.header.accessibilityExpandedStatus, .collapsed)
        cell.header.sendActions(for: .primaryActionTriggered)
        await waitUntil("the row to expand") { fixture.cell(for: id, as: ToolCallCell.self)?.isExpanded == true }
        cell = try XCTUnwrap(fixture.cell(for: id, as: ToolCallCell.self))
        XCTAssertTrue(cell.detailsView.attributedText.string.hasPrefix("Content:"))
        XCTAssertTrue((cell.detailsView.attributedText.attribute(.font, at: 12, effectiveRange: nil) as? UIFont)?
            .fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ?? false)
        XCTAssertFalse(cell.detailsView.superview?.isHidden ?? true)
        XCTAssertEqual(cell.header.accessibilityExpandedStatus, .expanded)
    }

    func testTheTranscriptFollowsTheEndUntilTheReaderScrollsAway() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        let history = (0..<16).flatMap { index in
            [ChatMessage(role: .user, text: "Question \(index)"),
             ChatMessage(role: .assistant, text: "Answer \(index)\n\n" + String(repeating: "A line of the answer that wraps. ", count: 6))]
        }
        await fixture.resume(history)
        let collection = fixture.transcript.collectionView
        await waitUntil("the transcript") { fixture.transcript.order.count == history.count }
        collection.layoutIfNeeded()
        await waitUntil("the end to show") { abs(fixture.transcript.distanceFromBottom) < 1 }
        await sendPrompt(fixture, "And now?")
        for word in ["Streaming ", "more ", "and more ", "text "] {
            fixture.client.chunk(word + String(repeating: "and a long line ", count: 12))
        }
        await waitUntil("the streamed reply") { fixture.model.messages.last?.text.contains("text ") == true }
        await waitUntil("the end to stay in view") {
            collection.layoutIfNeeded()
            return abs(fixture.transcript.distanceFromBottom) < 1
        }
        XCTAssertTrue(fixture.screen.jumpButton.isHidden)

        // The reader drags up; the answer grows below without moving what they read.
        collection.setContentOffset(CGPoint(x: 0, y: collection.contentOffset.y - 600), animated: false)
        fixture.transcript.scrollViewDidEndDragging(collection, willDecelerate: false)
        XCTAssertFalse(fixture.transcript.isPinned)
        let offset = collection.contentOffset.y
        fixture.client.chunk(String(repeating: "Further output. ", count: 40))
        await waitUntil("more output") { fixture.model.messages.last?.text.contains("Further") == true }
        try await Task.sleep(for: .milliseconds(150))
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.contentOffset.y, offset, accuracy: 1)
        await waitUntil("the jump button") { !fixture.screen.jumpButton.isHidden }
        XCTAssertEqual(fixture.screen.jumpButton.accessibilityLabel, "Jump to Latest")

        fixture.screen.jumpButton.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(fixture.transcript.isPinned)
        await waitUntil("the end again") {
            collection.layoutIfNeeded()
            return abs(fixture.transcript.distanceFromBottom) < 1
        }
        fixture.client.endTurn()
    }

    func testJumpToLatestAppearsAfterATapOnTheStatusBarAndWhenTheEndRunsAway() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        let history = (0..<12).flatMap { index in
            [ChatMessage(role: .user, text: "Question \(index)"),
             ChatMessage(role: .assistant, text: String(repeating: "A line of the answer that wraps. ", count: 8))]
        }
        await fixture.resume(history)
        let collection = fixture.transcript.collectionView
        await waitUntil("the end to show") {
            collection.layoutIfNeeded()
            return fixture.transcript.order.count == history.count && abs(fixture.transcript.distanceFromBottom) < 1
        }
        // A tap on the status bar: UIKit asks, then scrolls to the top on its own.
        XCTAssertTrue(fixture.transcript.scrollViewShouldScrollToTop(collection))
        collection.setContentOffset(CGPoint(x: 0, y: -collection.adjustedContentInset.top), animated: false)
        fixture.transcript.scrollViewDidScrollToTop(collection)
        await waitUntil("the jump button") { !fixture.screen.jumpButton.isHidden && fixture.screen.jumpButton.alpha > 0 }

        // Left 30 points from the end: unpinned, and too close for the button, until the reply runs on.
        fixture.screen.jumpButton.sendActions(for: .primaryActionTriggered)
        await waitUntil("the button to go") { fixture.screen.jumpButton.isHidden }
        await sendPrompt(fixture, "More")
        collection.layoutIfNeeded()
        collection.setContentOffset(CGPoint(x: 0, y: collection.contentOffset.y - 30), animated: false)
        fixture.transcript.scrollViewDidEndDragging(collection, willDecelerate: false)
        XCTAssertFalse(fixture.transcript.isPinned)
        XCTAssertTrue(fixture.screen.jumpButton.isHidden)
        fixture.client.chunk(String(repeating: "Streaming on and on. ", count: 60))
        await waitUntil("the jump button once the end runs away") { !fixture.screen.jumpButton.isHidden }
        fixture.client.endTurn()
    }

    func testACommandToolTitleIsMonospacedWithoutItsBackticks() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.resume(SampleConversation.messages)
        await waitUntil("the transcript") { fixture.transcript.order.count == SampleConversation.messages.count }
        let cell = try XCTUnwrap(fixture.cell(for: SampleConversation.run.id, as: ToolCallCell.self))
        XCTAssertEqual(cell.header.accessibilityLabel,
                       "Tool: swift test --filter RemoteSessionLiveTests/testReconnectAfterServerRestart, Failed")
        XCTAssertEqual(ToolCallPresentation(text: "`ls` · completed").displayTitle, "ls")
        XCTAssertTrue(ToolCallPresentation(text: "`ls` · completed").isCommand)
        XCTAssertFalse(ToolCallPresentation(text: "Read `a`.swift · completed").isCommand)
    }

    func testOnlyLatchsOwnNoticesAreDrawnAsNotices() {
        let notice = ChatMessage(role: .assistant, text: "_\(SessionModel.promptNotSentOverLink)_")
        XCTAssertEqual(TranscriptController.kind(of: notice), .notice)
        XCTAssertEqual(TranscriptController.kind(of: ChatMessage(role: .assistant, text: "_Just one italic line from the agent._")),
                       .assistant)
    }

    // MARK: Composer

    func testSendIsReadyOnlyWithSomethingToSendAndBecomesStopWhileATurnRuns() async throws {
        let fixture = SessionScreenFixture(client: ScriptedSessionClient(holdLaunch: true), draft: "Draft kept")
        show(fixture)
        XCTAssertEqual(fixture.screen.composer.text, "Draft kept")
        XCTAssertEqual(fixture.screen.composer.placeholder, "Ask Claude Code…")
        let connecting = Task { await fixture.connect() }
        await waitUntil("connecting") { fixture.model.phase == .connecting }
        XCTAssertEqual(fixture.screen.composer.action, .send(enabled: false), "Drafting is allowed while connecting, sending is not")
        fixture.client.releaseLaunch()
        await connecting.value
        XCTAssertEqual(fixture.screen.composer.action, .send(enabled: true))
        fixture.type("   \n")
        XCTAssertEqual(fixture.screen.composer.action, .send(enabled: false))
        XCTAssertEqual(fixture.drafts.last, "   \n")

        await sendPrompt(fixture, "Run the tests")
        XCTAssertEqual(fixture.client.prompts, [[.text("Run the tests")]])
        XCTAssertEqual(fixture.screen.composer.text, "")
        XCTAssertEqual(fixture.drafts.last, "")
        XCTAssertEqual(fixture.screen.composer.action, .stop(enabled: true))
        XCTAssertTrue(fixture.screen.canPerformAction(#selector(SessionDetailViewController.stopCommand), withSender: nil))
        XCTAssertFalse(fixture.screen.canPerformAction(#selector(SessionDetailViewController.sendCommand), withSender: nil))

        fixture.screen.composer.actionButton.sendActions(for: .primaryActionTriggered)
        await waitUntil("the turn to be cancelled") { fixture.model.phase == .ready }
        XCTAssertTrue(fixture.client.commands.contains { if case .cancelPrompt = $0 { true } else { false } })
        XCTAssertEqual(fixture.screen.composer.action, .send(enabled: false))
        XCTAssertEqual(fixture.model.status, "Cancelled")
    }

    func testTheMenuBarsCommandsSendAndStop() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        XCTAssertNil(fixture.screen.keyCommands, "The menu bar defines the shortcuts")
        fixture.type("Via the keyboard")
        XCTAssertTrue(fixture.screen.canPerformAction(#selector(SessionDetailViewController.sendCommand), withSender: nil))
        fixture.screen.sendCommand()
        await waitUntil("the prompt") { fixture.client.hasOpenTurn }
        XCTAssertEqual(fixture.client.prompts, [[.text("Via the keyboard")]])
        await waitUntil("Stop") { fixture.screen.canStop }
        fixture.screen.stopCommand()
        // Until the agent ends the turn, the transcript says the stop was heard.
        await waitUntil("the stop") { fixture.model.phase == .ready }
    }

    /// Return on a hardware keyboard sends, as in Messages; with nothing to send it types.
    func testReturnSendsFromAHardwareKeyboard() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        let text = fixture.screen.composer.textView
        let returnKey = try XCTUnwrap(text.keyCommands?.first { $0.input == "\r" && $0.modifierFlags.isEmpty })
        XCTAssertTrue(returnKey.wantsPriorityOverSystemBehavior)
        XCTAssertFalse(text.canPerformAction(returnKey.action!, withSender: nil), "Nothing to send: Return types a new line")
        fixture.type("Sent with Return")
        XCTAssertTrue(text.canPerformAction(returnKey.action!, withSender: nil))
        text.perform(returnKey.action!)
        await waitUntil("the prompt") { fixture.client.hasOpenTurn }
        XCTAssertEqual(fixture.client.prompts, [[.text("Sent with Return")]])
        fixture.client.endTurn()
    }

    func testAPhotoGoesAsAnImageBlockBeforeTheText() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        let image = try XCTUnwrap(ComposerImage.make(from: Self.pngData(width: 3000, height: 1500), name: "Screenshot.png"))
        XCTAssertEqual(image.name, "Screenshot.jpg")
        guard case let .image(data, mimeType, source) = image.prompt.content else { return XCTFail("Not an image") }
        XCTAssertEqual(mimeType, "image/jpeg")
        XCTAssertNil(source)
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale), 2048, accuracy: 1,
                       "The longest side is cut to 2048 pixels")

        fixture.screen.add([image])
        XCTAssertEqual(fixture.screen.composer.attachments.count, 1)
        XCTAssertEqual(fixture.screen.composer.action, .send(enabled: true), "A photo alone can be sent")
        fixture.type("What is wrong here?")
        fixture.screen.send()
        await waitUntil("the prompt") { fixture.client.hasOpenTurn }
        XCTAssertEqual(fixture.client.prompts, [[.image(data: data, mimeType: "image/jpeg"), .text("What is wrong here?")]])
        XCTAssertTrue(fixture.screen.composer.attachments.isEmpty)
        XCTAssertEqual(fixture.model.messages.first?.attachments.map(\.name), ["Screenshot.jpg"])
        fixture.client.endTurn()
    }

    func testNoMoreThanFourPhotos() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        let images = try (0..<6).map { try XCTUnwrap(ComposerImage.make(from: Self.pngData(width: 40, height: 40), name: "Photo \($0)")) }
        fixture.screen.add(images)
        XCTAssertEqual(fixture.screen.composer.attachments.map(\.name), ["Photo 0.jpg", "Photo 1.jpg", "Photo 2.jpg", "Photo 3.jpg"])
        XCTAssertFalse(fixture.screen.composer.canAttach)
    }

    func testAnAgentThatTakesNoImagesRefusesThemWithTheReason() async throws {
        let fixture = SessionScreenFixture(client: ScriptedSessionClient(acceptsImages: false))
        show(fixture)
        await fixture.connect()
        let image = try XCTUnwrap(ComposerImage.make(from: Self.pngData(width: 40, height: 40), name: "Photo"))
        fixture.screen.add([image])
        XCTAssertTrue(fixture.screen.composer.attachments.isEmpty)
        XCTAssertEqual(fixture.screen.currentBanner?.title, "Claude Code on vps can’t receive images.")
        XCTAssertEqual(fixture.screen.currentBanner?.message,
                       "Send your message without the image, or start a session with an agent that accepts images.")
        XCTAssertEqual(fixture.screen.currentBanner?.severity, .warning)
        fixture.type("Fine, text only")
        XCTAssertNil(fixture.screen.currentBanner, "Typing on clears the notice")
        fixture.screen.chooseImages()
        XCTAssertNil(fixture.screen.presentedViewController, "The picker never opens for an agent that takes no images")
        XCTAssertNotNil(fixture.screen.currentBanner)
    }

    func testSlashCommandsAreSuggestedAndInserted() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        fixture.client.availableCommands([("compact", "Summarise the conversation"), ("review", "Review the diff"),
                                          ("init", "Write a CLAUDE.md")])
        await waitUntil("the commands") { fixture.model.commands.count == 3 }
        XCTAssertTrue(fixture.screen.suggestions.isHidden)
        fixture.type("/")
        XCTAssertFalse(fixture.screen.suggestions.isHidden)
        XCTAssertEqual(fixture.screen.suggestions.matches.map(\.name), ["compact", "review", "init"])
        fixture.type("/rev")
        XCTAssertEqual(fixture.screen.suggestions.matches.map(\.name), ["review"])
        fixture.type("/diff")
        XCTAssertEqual(fixture.screen.suggestions.matches.map(\.name), ["review"], "Descriptions match after names")
        fixture.type("/co")
        let row = try XCTUnwrap(fixture.screen.suggestions.subviews.lazy.compactMap { $0 as? UIScrollView }.first?
            .subviews.lazy.compactMap { $0 as? UIStackView }.first?.arrangedSubviews.first as? UIButton)
        XCTAssertEqual(row.accessibilityLabel, "/compact")
        row.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(fixture.screen.composer.text, "/compact ")
        XCTAssertEqual(fixture.drafts.last, "/compact ")
        XCTAssertTrue(fixture.screen.suggestions.isHidden, "A chosen command closes the list")
    }

    // MARK: Permission

    func testAPermissionRequestIsASheetThatResolvesThroughTheModel() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Clean the build")
        fixture.client.requestPermission(title: "Run rm -rf build")
        await waitUntil("the sheet") { fixture.screen.permissionSheet != nil }
        let sheet = try XCTUnwrap(fixture.screen.permissionSheet)
        XCTAssertTrue(fixture.presentedSheets.last === sheet)
        XCTAssertEqual(sheet.requestTitle, "Run rm -rf build")
        XCTAssertTrue(sheet.details.contains("rm -rf build"), sheet.details)
        XCTAssertTrue(sheet.isModalInPresentation, "The sheet cannot be swiped away")
        XCTAssertEqual(sheet.sheetPresentationController?.detents.map(\.identifier),
                       [PermissionRequestViewController.fitDetent, .large], "As tall as the request needs, or the whole height")
        XCTAssertTrue(sheet.sheetPresentationController?.prefersGrabberVisible ?? false)
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.optionButtons.map { $0.configuration?.title }, ["Allow Once", "Always Allow", "Reject Once"])
        XCTAssertEqual(Set(sheet.optionButtons.map { $0.configuration?.cornerStyle }).count, 1)
        XCTAssertEqual(Set(sheet.optionButtons.map { $0.configuration?.background.backgroundColor }).count, 1,
                       "Every option has the same look: none is the default")
        XCTAssertEqual(Set(sheet.optionButtons.map { $0.configuration?.baseForegroundColor }).count, 1)
        XCTAssertEqual(sheet.keyCommands?.map(\.input), [UIKeyCommand.inputEscape], "Only Escape, which cancels, has a key")
        XCTAssertEqual(sheet.cancelButton.configuration?.title, "Cancel Request")

        sheet.optionButtons[0].sendActions(for: .primaryActionTriggered)
        await waitUntil("the decision to reach the server") {
            fixture.client.commands.contains { command in
                if case let .resolvePermission(_, _, outcome) = command { outcome == .selected(optionID: "allow") } else { false }
            }
        }
        XCTAssertTrue(fixture.dismissedSheets.last === sheet)
        XCTAssertNil(fixture.screen.permissionSheet)
        sheet.optionButtons[2].sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(fixture.client.commands.count { if case .resolvePermission = $0 { true } else { false } }, 1,
                       "A sheet decides once")
        fixture.client.endTurn()
    }

    func testCancelRequestCancelsAndARequestClosedElsewhereDismissesTheSheet() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Two requests")
        fixture.client.requestPermission(title: "First")
        await waitUntil("the first sheet") { fixture.screen.permissionSheet?.requestTitle == "First" }
        let first = try XCTUnwrap(fixture.screen.permissionSheet)
        first.loadViewIfNeeded()
        first.cancelButton.sendActions(for: .primaryActionTriggered)
        await waitUntil("the cancellation") {
            fixture.client.commands.contains { if case .resolvePermission(_, _, .cancelled) = $0 { true } else { false } }
        }
        XCTAssertNil(fixture.screen.permissionSheet)

        let second = fixture.client.requestPermission(title: "Second")
        await waitUntil("the second sheet") { fixture.screen.permissionSheet?.requestTitle == "Second" }
        let shown = try XCTUnwrap(fixture.screen.permissionSheet)
        fixture.client.closePermission(second)
        await waitUntil("the closed request's sheet to go") { fixture.screen.permissionSheet == nil }
        XCTAssertTrue(fixture.dismissedSheets.last === shown)
        XCTAssertNil(fixture.model.permissions.current)
        XCTAssertEqual(fixture.presentedSheets.count, 2)
        fixture.client.endTurn()
    }

    /// The test host never finishes a presentation, so this covers a sheet taken down by
    /// someone else; presenting over another controller is left to the in-app check.
    func testARequestTakenDownElsewhereIsShownAgain() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Clean")
        fixture.client.requestPermission(title: "Taken down")
        await waitUntil("the sheet") { fixture.presentedSheets.count == 1 }
        let first = try XCTUnwrap(fixture.screen.permissionSheet)
        // The host takes it down, say to show another session: the request is still open,
        // so the screen shows it again.
        first.onDismissedElsewhere?()
        await waitUntil("the sheet again") { fixture.presentedSheets.count == 2 }
        XCTAssertEqual(fixture.screen.permissionSheet?.promptID, first.promptID)
        XCTAssertFalse(fixture.screen.permissionSheet === first)
        fixture.screen.permissionSheet?.finish("allow")
        await waitUntil("the decision") { fixture.screen.permissionSheet == nil }
        first.onDismissedElsewhere?()
        XCTAssertEqual(fixture.presentedSheets.count, 2, "A stale sheet going changes nothing")
        fixture.client.endTurn()
    }

    func testThePermissionSheetKeepsTheRequestInViewAtTheLargestTextSize() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Clean")
        fixture.client.requestPermission(title: "rm -rf .build", command: "rm -rf .build && swift build")
        await waitUntil("the sheet") { fixture.screen.permissionSheet != nil }
        let sheet = try XCTUnwrap(fixture.screen.permissionSheet)
        sheet.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let window = try XCTUnwrap(windows.last)
        sheet.view.frame = CGRect(x: 0, y: 60, width: window.bounds.width, height: window.bounds.height - 60)
        window.addSubview(sheet.view)
        sheet.view.layoutIfNeeded()
        sheet.view.layoutIfNeeded()
        XCTAssertFalse(sheet.actionsArePinned, "The options follow the request instead of covering it")
        let scroll = try XCTUnwrap(sheet.view.subviews.first { $0 is UIScrollView } as? UIScrollView)
        XCTAssertGreaterThan(scroll.bounds.height, window.bounds.height * 0.5)
        let first = try XCTUnwrap(sheet.optionButtons.first)
        XCTAssertTrue(first.isDescendant(of: scroll))
        XCTAssertTrue(sheet.cancelButton.isDescendant(of: scroll), "Cancel goes with the options, never alone in sight")
        // Every line of the note is shown, above the options rather than under them.
        func labels(_ view: UIView) -> [UILabel] { view.subviews.compactMap { $0 as? UILabel } + view.subviews.flatMap(labels) }
        let note = try XCTUnwrap(labels(scroll).first { $0.text?.hasPrefix("“Always”") == true })
        let noteFrame = note.convert(note.bounds, to: scroll)
        XCTAssertGreaterThanOrEqual(note.bounds.height + 1, note.sizeThatFits(CGSize(width: note.bounds.width, height: .greatestFiniteMagnitude)).height)
        XCTAssertLessThanOrEqual(noteFrame.maxY, first.convert(first.bounds, to: scroll).minY)
        sheet.view.removeFromSuperview()
        sheet.finish(nil)
        fixture.client.endTurn()
    }

    func testQueuedRequestsShowOneAtATime() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Many")
        fixture.client.requestPermission(title: "One")
        fixture.client.requestPermission(title: "Two")
        await waitUntil("the first sheet") { fixture.screen.permissionSheet?.requestTitle == "One" }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.presentedSheets.count, 1)
        fixture.screen.permissionSheet?.finish("allow")
        await waitUntil("the second sheet") { fixture.screen.permissionSheet?.requestTitle == "Two" }
        XCTAssertEqual(fixture.presentedSheets.count, 2)
        fixture.client.endTurn()
    }

    // MARK: Menu

    func testTheMenuOffersWhatTheAgentAdvertises() async throws {
        let fixture = SessionScreenFixture(client: ScriptedSessionClient(configOptions: ScriptedConfiguration.options))
        show(fixture)
        await fixture.connect()
        var menu = try XCTUnwrap(fixture.screen.menuButton.menu)
        let sections = menu.children.compactMap { $0 as? UIMenu }
        XCTAssertEqual(sections.count, 3)
        let pickers = sections[0].children.compactMap { $0 as? UIMenu }
        XCTAssertEqual(pickers.map(\.title), ["Model", "Effort", "Permission Mode", "Fast mode"])
        XCTAssertEqual(pickers.map(\.subtitle), ["Sonnet", "Medium", "Ask First", "Off"])
        let group = try XCTUnwrap(pickers[0].children.first as? UIMenu)
        XCTAssertEqual(group.title, "Claude")
        XCTAssertTrue(group.options.contains(.displayInline))
        let models = group.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(models.map(\.title), ["Sonnet", "Opus"])
        XCTAssertEqual(models.map(\.state), [.on, .off])
        XCTAssertEqual(models.map(\.subtitle), ["Fast and capable", "Most capable"])
        XCTAssertTrue(models.allSatisfy { !$0.attributes.contains(.disabled) })
        XCTAssertEqual(sections[1].children.compactMap { ($0 as? UIAction)?.title }, ["Copy Path"])
        XCTAssertEqual(sections[2].children.count, 1, "Nothing to start while the agent runs")
        let stop = try XCTUnwrap(sections[2].children.first as? UIAction)
        XCTAssertEqual(stop.title, "Stop Agent")
        XCTAssertTrue(stop.attributes.contains(.destructive))

        // Choosing waits for the agent before the check moves.
        models[1].performWithSender(nil, target: nil)
        await waitUntil("the change") {
            fixture.client.commands.contains { if case .setSessionConfigOption(_, "model", "opus") = $0 { true } else { false } }
        }
        await waitUntil("the confirmed value") { fixture.model.configuration.model?.currentValue == "opus" }
        menu = try XCTUnwrap(fixture.screen.menuButton.menu)
        let updated = ((menu.children[0] as? UIMenu)?.children.first as? UIMenu)
        XCTAssertEqual(updated?.subtitle, "Opus")

        await sendPrompt(fixture, "Busy")
        menu = try XCTUnwrap(fixture.screen.menuButton.menu)
        let busy = (((menu.children[0] as? UIMenu)?.children.first as? UIMenu)?.children.first as? UIMenu)?.children
            .compactMap { $0 as? UIAction } ?? []
        XCTAssertFalse(busy.isEmpty)
        XCTAssertTrue(busy.allSatisfy { $0.attributes.contains(.disabled) }, "No changes while a turn runs")
        fixture.client.endTurn()
    }

    func testAnAgentWithoutSettingsHasOnlyCopyPathAndStop() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        let menu = try XCTUnwrap(fixture.screen.menuButton.menu)
        XCTAssertEqual((menu.children[0] as? UIMenu)?.children.count, 0)
        let pasteboard = UIPasteboard.withUniqueName()
        fixture.screen.pasteboard = pasteboard
        ((menu.children[1] as? UIMenu)?.children.first as? UIAction)?.performWithSender(nil, target: nil)
        XCTAssertEqual(pasteboard.string, "/home/simon/latch", "The whole path, though the title shows ~")
        UIPasteboard.remove(withName: pasteboard.name)
    }

    // MARK: Title and banner

    func testTheTitleNamesTheSessionAndWhereItRuns() {
        let fixture = SessionScreenFixture()
        XCTAssertEqual(fixture.screen.title, "Fix the flaky reconnect test")
        if #available(iOS 26.0, *) {
            XCTAssertEqual(fixture.screen.navigationItem.subtitle, "vps · ~/latch")
        } else {
            XCTAssertEqual(fixture.screen.navigationItem.titleView?.accessibilityLabel, "Fix the flaky reconnect test")
            XCTAssertEqual(fixture.screen.navigationItem.titleView?.accessibilityValue, "vps, /home/simon/latch")
        }
        fixture.screen.context.title = "Renamed"
        XCTAssertEqual(fixture.screen.title, "Renamed")
    }

    func testALostLinkSaysTheAgentKeepsWorking() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Long job")
        fixture.client.emit(.link(.reconnecting(server: "vps", since: Date())))
        await waitUntil("the banner") { fixture.screen.banner.isShowing }
        let banner = try XCTUnwrap(fixture.screen.currentBanner)
        XCTAssertEqual(banner.title, "Reconnecting to vps…")
        XCTAssertEqual(banner.message, "The agent keeps working on the server. Latch catches up once it answers again.")
        XCTAssertTrue(banner.isWaiting)
        XCTAssertEqual(banner.severity, .info)
        fixture.client.emit(.link(.connected))
        await waitUntil("the banner to go") { fixture.screen.currentBanner == nil }
        fixture.client.endTurn()
    }

    func testAConnectionFailureOffersRetryAndServerSettings() async throws {
        let client = ScriptedSessionClient()
        client.failNextLaunch(with: UnreachableServer(message: "vps did not answer at vps.example:7800."))
        let fixture = SessionScreenFixture(client: client)
        show(fixture)
        await fixture.connect()
        await waitUntil("the banner") { fixture.screen.banner.isShowing }
        let banner = try XCTUnwrap(fixture.screen.currentBanner)
        XCTAssertEqual(banner.title, "Can’t connect to vps")
        XCTAssertEqual(banner.message, "vps did not answer at vps.example:7800.")
        XCTAssertEqual(banner.detail, "", "Latch's own words are not set as the agent's")
        XCTAssertEqual(banner.severity, .error)
        XCTAssertEqual(fixture.screen.banner.displayedActions, ["Retry", "Server Settings"])
        fixture.screen.banner.onAction?("retry")
        fixture.screen.banner.onAction?("serverSettings")
        XCTAssertEqual(fixture.retries, 1)
        XCTAssertEqual(fixture.serverSettings, 1)
    }

    func testTheAgentsWordsAreSetApartFromLatchsAdvice() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Fail")
        fixture.client.failTurn(LatchAgentFailure(code: .commandFailed, message: "Agent reported: rate limited"))
        await waitUntil("the failure") { fixture.model.errorMessage != nil }
        let banner = try XCTUnwrap(fixture.screen.currentBanner)
        XCTAssertEqual(banner.title, "Claude Code reported a problem")
        XCTAssertEqual(banner.severity, .warning)
        XCTAssertEqual(banner.actions, [], "A live session has nothing to retry")
        XCTAssertFalse(banner.detail.hasPrefix("Agent reported:"))
    }

    func testAnAgentStoppedOnTheServerIsAWarningWithRetry() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        let id = try XCTUnwrap(fixture.client.runtimeID)
        fixture.client.emit(.stopped(runtimeID: id, server: "vps", sequence: 1))
        await waitUntil("the stop") { fixture.model.stoppedOnServer }
        let banner = try XCTUnwrap(fixture.screen.currentBanner)
        XCTAssertEqual(banner.title, "Claude Code stopped on vps")
        XCTAssertEqual(banner.detail, "")
        XCTAssertEqual(banner.message, "Another device or the server stopped it. Retry starts it again.")
        XCTAssertEqual(banner.severity, .warning)
        XCTAssertEqual(banner.actions.map(\.title), ["Retry"])
    }

    /// An agent that ends by itself mid-conversation quit; it did not fail to start.
    func testAnAgentThatExitsQuitUnexpectedly() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        let id = try XCTUnwrap(fixture.client.runtimeID)
        fixture.client.emit(.agent(.processTerminated(runtimeID: id, status: 3), sequence: nil))
        await waitUntil("the exit") { fixture.model.phase == .disconnected }
        let banner = try XCTUnwrap(fixture.screen.currentBanner)
        XCTAssertEqual(banner.title, "Claude Code quit unexpectedly on vps")
        XCTAssertEqual(banner.message, "It exited with status 3. Retry starts it again.")
        XCTAssertEqual(banner.detail, "")
        XCTAssertEqual(banner.actions.map(\.title), ["Retry"])
    }

    /// Stopped from this device, the conversation says so and offers to start the agent
    /// again, in the banner and in the menu.
    func testAnAgentStoppedHereOffersToStartAgain() async throws {
        let fixture = SessionScreenFixture()
        show(fixture)
        await fixture.connect()
        await sendPrompt(fixture, "Hello")
        fixture.client.endTurn()
        await waitUntil("the turn's end") { fixture.model.phase == .ready }
        var stopped = false
        fixture.screen.context.isStopped = { stopped }
        await fixture.model.disconnect()
        stopped = true
        fixture.screen.modelDidChange()
        let banner = try XCTUnwrap(fixture.screen.currentBanner)
        XCTAssertEqual(banner.title, "Claude Code is stopped")
        XCTAssertEqual(banner.severity, .info)
        XCTAssertEqual(banner.actions.map(\.title), ["Start Agent"])
        fixture.screen.banner.onAction?(banner.actions[0].id)
        XCTAssertEqual(fixture.retries, 1)
        let menu = try XCTUnwrap(fixture.screen.menuButton.menu)
        let last = try XCTUnwrap(menu.children.compactMap { $0 as? UIMenu }.last)
        XCTAssertEqual(last.children.compactMap { ($0 as? UIAction)?.title }, ["Start Agent", "Stop Agent"])
    }

    /// With its server gone from Servers, nothing on the screen offers settings that would
    /// only add a new server.
    func testASessionWhoseServerIsGoneOffersNoSettings() async throws {
        let client = ScriptedSessionClient()
        client.failNextLaunch(with: RemoteSessionNotConnected.serverRemoved)
        let fixture = SessionScreenFixture(client: client)
        fixture.screen.context.hasServer = { false }
        show(fixture)
        await fixture.connect()
        await waitUntil("the failure") { fixture.model.errorMessage != nil }
        let banner = try XCTUnwrap(fixture.screen.currentBanner)
        XCTAssertEqual(banner.actions, [])
        XCTAssertEqual(banner.message, "vps is no longer in Servers.")
    }

    func testADismissedBannerStaysDismissedUntilRetry() async throws {
        let client = ScriptedSessionClient()
        client.failNextLaunch(with: UnreachableServer(message: "No route."))
        let fixture = SessionScreenFixture(client: client)
        show(fixture)
        await fixture.connect()
        await waitUntil("the banner") { fixture.screen.banner.isShowing }
        let dismiss = try XCTUnwrap(fixture.screen.banner.allSubviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "Dismiss" })
        dismiss.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(fixture.screen.banner.isShowing)
        fixture.screen.modelDidChange()
        XCTAssertFalse(fixture.screen.banner.isShowing, "A refresh does not bring back what was dismissed")
    }

    func testAReadOnlyConversationSaysSoAndTakesNoDraft() async throws {
        let fixture = SessionScreenFixture()
        fixture.model.restore(messages: [SampleConversation.prompt], agentSessionID: nil)
        show(fixture)
        let banner = try XCTUnwrap(fixture.screen.currentBanner)
        XCTAssertEqual(banner.title, "This conversation is read-only")
        XCTAssertEqual(banner.severity, .info)
        XCTAssertFalse(fixture.screen.composer.isEditable)
        XCTAssertEqual(fixture.screen.composer.placeholder, "This conversation is read-only")
    }

    // MARK: Empty states

    func testEmptyStatesSayWhatIsHappening() async throws {
        let fixture = SessionScreenFixture(client: ScriptedSessionClient(holdLaunch: true))
        show(fixture)
        let empty = try XCTUnwrap(fixture.transcript.collectionView.backgroundView as? UIContentUnavailableView)
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.text, "Not Connected")
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.button.title, "Retry")
        let connecting = Task { await fixture.connect() }
        await waitUntil("connecting") { fixture.model.phase == .connecting }
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.text, "Connecting to vps…")
        fixture.client.releaseLaunch()
        await connecting.value
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.text, "Ask Claude Code")
        XCTAssertEqual((empty.configuration as? UIContentUnavailableConfiguration)?.secondaryText, "Works in ~/latch on vps.")
        XCTAssertFalse(empty.isHidden)
        await sendPrompt(fixture, "Hello")
        await waitUntil("the prompt to show") { empty.isHidden }
        fixture.client.endTurn()
    }

    func testTheComposerButtonsOfferTheLargeContentViewer() {
        let fixture = SessionScreenFixture()
        show(fixture)
        let composer = fixture.screen.composer
        XCTAssertTrue(composer.actionButton.showsLargeContentViewer)
        XCTAssertTrue(composer.attachButton.showsLargeContentViewer)
        XCTAssertEqual(composer.attachButton.largeContentTitle, "Add Photos")
        XCTAssertTrue(composer.interactions.contains { $0 is UILargeContentViewerInteraction })
        XCTAssertGreaterThanOrEqual(composer.actionButton.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(composer.attachButton.bounds.height, 44)
    }

    static func pngData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}
