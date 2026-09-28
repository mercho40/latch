import LatchACP
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class TranscriptInteractionTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach(Snapshot.tearDown)
        windows = []
        try await super.tearDown()
    }

    private func shown(_ messages: [ChatMessage] = SampleConversation.messages) async -> SessionScreenFixture {
        let fixture = SessionScreenFixture()
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.resume(messages)
        await waitUntil("the transcript") { fixture.transcript.order.count == messages.count }
        return fixture
    }

    private func titles(_ menu: UIMenu?) -> [String] {
        (menu?.children ?? []).flatMap { element -> [String] in
            if let group = element as? UIMenu { return group.children.compactMap { ($0 as? UIAction)?.title } }
            return [(element as? UIAction)?.title].compactMap { $0 }
        }
    }

    private func perform(_ title: String, in menu: UIMenu?) {
        let actions = (menu?.children ?? []).flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { $0 as? UIAction }
        actions.first { $0.title == title }?.performWithSender(nil, target: nil)
    }

    // MARK: Menus

    /// A long press on a message offers what Messages does: copy it, whole or in parts, or
    /// select its text.
    func testEachKindOfMessageHasItsMenu() async throws {
        let fixture = await shown()
        let transcript = fixture.transcript
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        transcript.pasteboard = pasteboard

        let prompt = transcript.menu(for: SampleConversation.prompt)
        XCTAssertEqual(titles(prompt), ["Copy", "Select Text"])
        perform("Copy", in: prompt)
        XCTAssertEqual(pasteboard.string, SampleConversation.prompt.text)

        let reply = transcript.menu(for: SampleConversation.answer)
        XCTAssertEqual(titles(reply), ["Copy", "Copy as Markdown", "Select Text", "Copy Code", "Open SO_REUSEADDR"])
        perform("Copy", in: reply)
        let plain = try XCTUnwrap(pasteboard.string)
        XCTAssertTrue(plain.hasPrefix("What I found\n\nThe test restarts"), plain)
        XCTAssertFalse(plain.contains("**"), "Copy is the text as it reads")
        XCTAssertTrue(plain.contains("1. The restart binds a new port."), plain)
        perform("Copy as Markdown", in: reply)
        XCTAssertEqual(pasteboard.string, SampleConversation.answer.text)
        perform("Copy Code", in: reply)
        XCTAssertEqual(pasteboard.string, "let port = try await server.restart(keepingPort: true)")
        var opened: [URL] = []
        transcript.openURL = { opened.append($0) }
        perform("Open SO_REUSEADDR", in: transcript.menu(for: SampleConversation.answer))
        XCTAssertEqual(opened.map(\.host), ["man7.org"])

        let command = transcript.menu(for: SampleConversation.run)
        XCTAssertEqual(titles(command), ["Copy Command", "Copy Details"])
        perform("Copy Command", in: command)
        XCTAssertEqual(pasteboard.string, "swift test --filter RemoteSessionLiveTests/testReconnectAfterServerRestart")
        perform("Copy Details", in: command)
        XCTAssertEqual(pasteboard.string, "Output:\nerror: testReconnect: timed out after 5.0 seconds",
                       "The history's raw heading reads plainly")
        XCTAssertEqual(titles(transcript.menu(for: SampleConversation.read)), ["Copy Title", "Copy Details"])

        let notice = ChatMessage(role: .assistant, text: "_\(SessionModel.promptNotSent)_")
        XCTAssertNil(transcript.menu(for: notice), "Latch's own notices have nothing to copy")

        let row = try XCTUnwrap(transcript.order.firstIndex(of: SampleConversation.prompt.id))
        XCTAssertNotNil(transcript.collectionView(transcript.collectionView, contextMenuConfigurationForItemsAt:
            [IndexPath(item: row, section: 0)], point: .zero), "The collection view asks the transcript")
    }

    /// Text is not selectable until Select Text, so a long press opens the menu; Select Text
    /// selects the message, and the text goes back to unselectable when it lets go.
    func testSelectTextSelectsTheMessageUntilItLetsGo() async throws {
        let fixture = await shown()
        let cell = try XCTUnwrap(fixture.cell(for: SampleConversation.prompt.id, as: UserMessageCell.self))
        XCTAssertFalse(cell.textView.isSelectable)
        cell.window?.makeKey()
        fixture.transcript.select(SampleConversation.prompt.id, at: .zero)
        XCTAssertTrue(cell.textView.isSelectable)
        try await Task.sleep(for: .milliseconds(100))
        // Taking the focus needs the window to be the one UIKit gives the keyboard to, which in
        // a full run an earlier test's window can keep; run alone, it always is.
        if cell.textView.isFirstResponder {
            XCTAssertEqual(cell.textView.selectedRange.length, (SampleConversation.prompt.text as NSString).length)
            XCTAssertTrue(cell.textView.resignFirstResponder())
        } else {
            cell.textView.endSelecting()
        }
        XCTAssertFalse(cell.textView.isSelectable, "Selectable only while selecting")
    }

    /// Links open with a tap though the text is not selectable, and only the allowed ones.
    func testATapOnALinkOpensIt() async throws {
        let fixture = await shown()
        let reply = try XCTUnwrap(fixture.cell(for: SampleConversation.answer.id, as: AssistantMessageCell.self))
        let text = try XCTUnwrap(reply.markdown.textViews.last)
        let range = (text.attributedText.string as NSString).range(of: "SO_REUSEADDR")
        let start = try XCTUnwrap(text.position(from: text.beginningOfDocument, offset: range.location + 2))
        let end = try XCTUnwrap(text.position(from: start, offset: 1))
        let rect = text.firstRect(for: try XCTUnwrap(text.textRange(from: start, to: end)))
        XCTAssertEqual(text.link(at: CGPoint(x: rect.midX, y: rect.midY))?.host, "man7.org")
        XCTAssertNil(text.link(at: CGPoint(x: 1, y: 1)), "Plain text is no link")
    }

    // MARK: VoiceOver

    /// VoiceOver's three-finger scroll is the reader leaving the end, as a drag is: the reply
    /// keeps streaming below without pulling the view back.
    func testAVoiceOverScrollLetsGoOfTheEnd() async throws {
        let history = (0..<10).flatMap { index in
            [ChatMessage(role: .user, text: "Question \(index)"),
             ChatMessage(role: .assistant, text: String(repeating: "A line of the answer that wraps. ", count: 8))]
        }
        let fixture = await shown(history)
        let collection = fixture.transcript.collectionView
        await waitUntil("the end") {
            collection.layoutIfNeeded()
            return abs(fixture.transcript.distanceFromBottom) < 1
        }
        fixture.type("More")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        fixture.client.chunk(String(repeating: "Streaming. ", count: 30))
        XCTAssertTrue(fixture.transcript.isPinned)
        _ = collection.accessibilityScroll(.up)
        XCTAssertFalse(fixture.transcript.isPinned)
        let offset = collection.contentOffset.y
        fixture.client.chunk(String(repeating: "More streaming. ", count: 40))
        await waitUntil("more output") { fixture.model.messages.last?.text.contains("More streaming") == true }
        try await Task.sleep(for: .milliseconds(150))
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.contentOffset.y, offset, accuracy: 1)
        fixture.client.endTurn()
    }

    func testTheTranscriptHasRotorsForEachKindOfMessage() async {
        let fixture = await shown()
        XCTAssertEqual(fixture.transcript.collectionView.accessibilityCustomRotors?.map(\.name),
                       ["Your Messages", "Replies", "Tool Calls", "Code"])
    }

    func testCodeIsSpokenSymbolBySymbolAndTablesByColumn() async throws {
        let fixture = await shown()
        let reply = try XCTUnwrap(fixture.cell(for: SampleConversation.answer.id, as: AssistantMessageCell.self))
        let spoken = try XCTUnwrap(reply.accessibilityAttributedLabel)
        let code = (spoken.string as NSString).range(of: "server.restart(keepingPort: true)")
        XCTAssertNotEqual(code.location, NSNotFound)
        XCTAssertEqual(spoken.attribute(.accessibilitySpeechPunctuation, at: code.location, effectiveRange: nil) as? Bool, true)
        let inline = (spoken.string as NSString).range(of: "TIME_WAIT")
        XCTAssertEqual(spoken.attribute(.accessibilitySpeechPunctuation, at: inline.location, effectiveRange: nil) as? Bool, true)
        XCTAssertTrue(spoken.string.contains("Table, 2 rows, 3 columns. Runner: macOS, Runs: 50, Failures: 0"), spoken.string)

        let tool = try XCTUnwrap(fixture.cell(for: SampleConversation.run.id, as: ToolCallCell.self))
        let label = try XCTUnwrap(tool.header.accessibilityAttributedLabel)
        let command = (label.string as NSString).range(of: "swift test")
        XCTAssertEqual(label.attribute(.accessibilitySpeechPunctuation, at: command.location, effectiveRange: nil) as? Bool, true)
    }

    // MARK: Tool rows

    /// A call without details is a line of text, not a dimmed button; a running one spins.
    func testToolRowsSayWhatTheyAre() {
        let header = ToolCallHeader()
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        header.show(ToolCallPresentation(text: "Read a · completed"), expanded: false, hasDetails: false, traits: traits)
        XCTAssertFalse(header.accessibilityTraits.contains(.button))
        XCTAssertEqual(header.accessibilityExpandedStatus, .unsupported)
        header.show(ToolCallPresentation(text: "Read a · in_progress\n\nContent:\nx"), expanded: false, hasDetails: true,
                    traits: traits)
        XCTAssertTrue(header.accessibilityTraits.contains(.button))
        XCTAssertEqual(header.accessibilityExpandedStatus, .collapsed)
        XCTAssertEqual(ToolCallPresentation(text: "Read a · in_progress").statusColor, .secondaryLabel,
                       "Running is as quiet as done")
    }

    func testRunningShowsStoppingOnceStopIsChosen() async throws {
        let fixture = await shown([SampleConversation.prompt])
        fixture.type("Go")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        fixture.transcript.update(messages: fixture.model.messages, isWorking: true, isStopping: true)
        let collection = fixture.transcript.collectionView
        collection.layoutIfNeeded()
        let working = try XCTUnwrap(collection.visibleCells.compactMap { $0 as? WorkingCell }.first)
        XCTAssertEqual(working.accessibilityLabel, "Stopping")
        fixture.client.endTurn()
    }

    // MARK: Photos

    /// A photo sent from here comes back as its picture, above the bubble; one from another
    /// device, or whose picture is gone, is listed by name.
    func testASentPhotoShowsAsItsPicture() async throws {
        let fixture = SessionScreenFixture()
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.connect()
        let image = try XCTUnwrap(ComposerImage.make(from: SessionDetailViewControllerTests.pngData(width: 600, height: 400),
                                                     name: "Screenshot"))
        fixture.screen.add([image])
        fixture.type("What is wrong here?")
        fixture.screen.send()
        await waitUntil("the prompt") { fixture.client.hasOpenTurn }
        let sent = try XCTUnwrap(fixture.model.messages.first { $0.role == .user })
        await waitUntil("the picture kept") { fixture.screen.sentImages.images(for: sent.id).count == 1 }
        let picture = try XCTUnwrap(fixture.screen.sentImages.images(for: sent.id).first ?? nil)
        XCTAssertLessThanOrEqual(max(picture.size.width, picture.size.height) * picture.scale, SentImageCache.maximumPixelSize)
        let cell = try XCTUnwrap(fixture.cell(for: sent.id, as: UserMessageCell.self))
        let pictures = cell.contentView.allSubviews.compactMap { $0 as? UIImageView }.filter { $0.layer.cornerRadius == 12 }
        XCTAssertFalse(pictures.isEmpty)
        XCTAssertTrue(pictures.allSatisfy(\.accessibilityIgnoresInvertColors))
        XCTAssertEqual(cell.accessibilityLabel, "You: What is wrong here?. Attached: Screenshot.jpg")
        XCTAssertFalse(cell.contentView.allSubviews.contains { $0 is AttachmentChip }, "No name chip for a photo shown")
        fixture.client.endTurn()

        fixture.screen.sentImages.remove([sent.id])
        fixture.transcript.update(messages: [], isWorking: false)
        fixture.transcript.update(messages: fixture.model.messages, isWorking: false)
        let named = try XCTUnwrap(fixture.cell(for: sent.id, as: UserMessageCell.self))
        XCTAssertTrue(named.contentView.allSubviews.contains { $0 is AttachmentChip }, "Gone: listed by name again")
    }

    // MARK: Code and tables

    /// A code line or a table wider than the reply fades at the edge it continues past.
    func testWideContentFadesWhereItContinues() {
        let scroll = FadingScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        scroll.contentSize = CGSize(width: 600, height: 40)
        scroll.layoutIfNeeded()
        XCTAssertTrue(scroll.fadingEdges.trailing)
        XCTAssertFalse(scroll.fadingEdges.leading)
        XCTAssertNotNil(scroll.layer.mask)
        scroll.contentOffset.x = 200
        scroll.layoutIfNeeded()
        XCTAssertTrue(scroll.fadingEdges.leading && scroll.fadingEdges.trailing)
        scroll.contentOffset.x = 400
        scroll.layoutIfNeeded()
        XCTAssertFalse(scroll.fadingEdges.trailing, "At the end, nothing more to hint at")
        scroll.contentSize = CGSize(width: 100, height: 40)
        scroll.contentOffset.x = 0
        scroll.layoutIfNeeded()
        XCTAssertNil(scroll.layer.mask, "No mask when it all fits")
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}
