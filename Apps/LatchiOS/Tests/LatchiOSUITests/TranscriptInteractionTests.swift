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

    /// `rows` when not every message is shown, as with collapsed subagents.
    private func shown(_ messages: [ChatMessage] = SampleConversation.messages, rows: Int? = nil) async -> SessionScreenFixture {
        let fixture = SessionScreenFixture()
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.resume(messages)
        await waitUntil("the transcript") { fixture.transcript.order.count == rows ?? messages.count }
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
                       ["Your Messages", "Replies", "Thinking", "Tool Calls", "Code"])
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

    // MARK: Thinking and subagents

    /// A thought is one line, "Thinking" and its first words, until it is opened to the whole
    /// thought in the secondary colour, which can then be selected as well as copied.
    func testAThoughtFoldsToALineAndOpensToTheWholeThought() async throws {
        let fixture = await shown(SampleSubagents.messages, rows: 4)
        let transcript = fixture.transcript
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        transcript.pasteboard = pasteboard
        let thought = SampleSubagents.thought
        var cell = try XCTUnwrap(fixture.cell(for: thought.id, as: ThoughtCell.self))
        XCTAssertFalse(cell.isExpanded)
        XCTAssertEqual(cell.header.accessibilityLabel, "Thinking")
        XCTAssertTrue(cell.header.accessibilityValue?.hasPrefix("Splitting the work The failure is either") ?? false,
                      cell.header.accessibilityValue ?? "")
        XCTAssertTrue(cell.textViews.isEmpty, "Folded")
        XCTAssertEqual(titles(transcript.menu(for: thought)), ["Copy"])

        cell.header.sendActions(for: .primaryActionTriggered)
        await waitUntil("the thought to open") { fixture.cell(for: thought.id, as: ThoughtCell.self)?.isExpanded == true }
        cell = try XCTUnwrap(fixture.cell(for: thought.id, as: ThoughtCell.self))
        XCTAssertEqual(cell.textView.attributedText.string, thought.text)
        XCTAssertEqual(cell.textView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
                       .secondaryLabel)
        XCTAssertEqual(cell.header.accessibilityExpandedStatus, .expanded)
        let menu = transcript.menu(for: thought)
        XCTAssertEqual(titles(menu), ["Copy", "Select Text"])
        perform("Copy", in: menu)
        XCTAssertEqual(pasteboard.string, thought.text)
    }

    /// A subagent's row stands for everything it did: collapsed, it counts its steps and names
    /// the latest while it runs; open, its steps, words and thinking follow it, one step in,
    /// before whatever came after it at the top.
    func testASubagentsStepsShowUnderItsRow() async throws {
        let fixture = SessionScreenFixture()
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.connect()
        fixture.type("Find the flaky test")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        let client = fixture.client
        client.thought("Two places to look.")
        client.tool("a", title: "Read the server", status: "in_progress", kind: "think", toolName: "Agent", subagent: true)
        client.tool("b", title: "Read the client", status: "in_progress", kind: "think", toolName: "Agent", subagent: true)
        client.tool("a1", title: "Read Server.swift", status: "completed", kind: "read", parent: "a")
        client.tool("b1", title: "Search for backoff", status: "in_progress", kind: "search", parent: "b")
        client.chunk("The server binds a new port.", parent: "a")
        client.tool("a2", title: "`swift test`", status: "in_progress", kind: "execute", parent: "a")
        await waitUntil("every row") { fixture.model.messages.count == 8 }
        let ids = fixture.model.messages.map(\.id)
        let (prompt, thought, a, b, a1, b1, words, a2) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7])
        let transcript = fixture.transcript
        await waitUntil("the subagents alone") { transcript.order == [prompt, thought, a, b] }
        let header = try XCTUnwrap(fixture.cell(for: a, as: ToolCallCell.self)?.header)
        XCTAssertEqual(header.accessibilityLabel, "Subagent: Read the server, 2 steps, Running")
        XCTAssertEqual(header.accessibilityValue, "Latest step: swift test")
        XCTAssertEqual(fixture.cell(for: b, as: ToolCallCell.self)?.header.accessibilityLabel,
                       "Subagent: Read the client, 1 step, Running")

        header.sendActions(for: .primaryActionTriggered)
        await waitUntil("its steps") { transcript.order == [prompt, thought, a, a1, words, a2, b] }
        XCTAssertEqual(fixture.cell(for: a1, as: ToolCallCell.self)?.indent, TranscriptCell.indentWidth)
        XCTAssertEqual(fixture.cell(for: words, as: AssistantMessageCell.self)?.indent, TranscriptCell.indentWidth)
        XCTAssertEqual(fixture.cell(for: b, as: ToolCallCell.self)?.indent, 0)
        XCTAssertFalse(transcript.order.contains(b1), "The other subagent stays collapsed")

        client.tool("a2", title: "`swift test`", status: "completed", kind: "execute", parent: "a")
        client.tool("a", title: "Read the server", status: "completed", kind: "think", toolName: "Agent", subagent: true)
        await waitUntil("the subagent to finish") {
            fixture.cell(for: a, as: ToolCallCell.self)?.header.accessibilityLabel == "Subagent: Read the server, 2 steps, Done"
        }
        XCTAssertNil(fixture.cell(for: a, as: ToolCallCell.self)?.header.accessibilityValue, "No latest step once done")

        fixture.cell(for: a, as: ToolCallCell.self)?.header.sendActions(for: .primaryActionTriggered)
        await waitUntil("its steps folded away") { transcript.order == [prompt, thought, a, b] }
        client.endTurn()
    }

    /// A call shown at the top that a later update places under a folded subagent goes under
    /// it, rather than being drawn again where it no longer is.
    func testACallThatLaterNamesAFoldedSubagentGoesUnderIt() async throws {
        let fixture = SessionScreenFixture()
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.connect()
        fixture.type("Find it")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        let client = fixture.client
        client.tool("a", title: "Explore", status: "in_progress", kind: "think", toolName: "Agent", subagent: true)
        client.tool("a1", title: "Read Server.swift", status: "in_progress", kind: "read")
        await waitUntil("both at the top") { fixture.transcript.order.count == 3 }
        client.tool("a1", title: "Read Server.swift", status: "completed", kind: "read", parent: "a")
        await waitUntil("the call under the folded subagent") { fixture.transcript.order.count == 2 }
        client.endTurn()
    }

    /// Opening a subagent with a long run of steps while the transcript follows its end keeps
    /// the subagent's row in sight, rather than following the end past it.
    func testOpeningALongSubagentAtTheEndKeepsItInView() async throws {
        let agent = ChatMessage(role: .tool, text: "Explore the code · completed",
                                tool: ToolSummary(callID: "agent", status: "completed", runsSubagent: true))
        let history = (0..<8).flatMap { index in
            [ChatMessage(role: .user, text: "Question \(index)"),
             ChatMessage(role: .assistant, text: String(repeating: "A line of the answer that wraps. ", count: 6))]
        } + [agent] + (0..<30).map { index in
            ChatMessage(role: .tool, text: "Read File\(index).swift · completed",
                        tool: ToolSummary(callID: "read\(index)", kind: "read", status: "completed"), parentID: agent.id)
        }
        let fixture = await shown(history, rows: 17)
        let transcript = fixture.transcript
        let collection = transcript.collectionView
        await waitUntil("the end") {
            collection.layoutIfNeeded()
            return abs(transcript.distanceFromBottom) < 1
        }
        XCTAssertTrue(transcript.isPinned)
        transcript.toggle(agent.id)
        await waitUntil("its steps") { transcript.order.count == 47 }
        try await Task.sleep(for: .milliseconds(400))
        collection.layoutIfNeeded()
        XCTAssertFalse(transcript.isPinned, "The reader is reading what they opened")
        let row = try XCTUnwrap(transcript.order.firstIndex(of: agent.id))
        let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame)
        XCTAssertGreaterThanOrEqual(frame.minY, collection.contentOffset.y + collection.adjustedContentInset.top - 1)
        XCTAssertLessThan(frame.maxY, collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom)
        await waitUntil("Jump to Latest") { !fixture.screen.jumpButton.isHidden }
    }

    // MARK: Plan

    /// The agent's plan sits over the composer while it has one, and the conversation makes
    /// room for it.
    func testThePlanSitsOverTheComposerWhileThereIsOne() async throws {
        let fixture = SessionScreenFixture()
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.connect()
        let plan = fixture.screen.composer.planView
        XCTAssertTrue(plan.isHidden)
        fixture.screen.view.layoutIfNeeded()
        let inset = fixture.transcript.collectionView.contentInset.bottom
        fixture.client.plan(SampleSubagents.plan)
        await waitUntil("the plan") { !plan.isHidden }
        XCTAssertEqual(plan.header.accessibilityLabel, "Plan, 1 of 4 done, now: Read the client's reconnect backoff")
        XCTAssertEqual(plan.header.accessibilityExpandedStatus, .collapsed)
        fixture.screen.view.layoutIfNeeded()
        XCTAssertGreaterThan(fixture.transcript.collectionView.contentInset.bottom, inset + 30)
        let field = fixture.screen.composer.textView.convert(fixture.screen.composer.textView.bounds, to: fixture.screen.composer)
        XCTAssertLessThanOrEqual(plan.frame.maxY, field.minY, "Over the field")

        plan.header.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(plan.isExpanded)
        XCTAssertEqual(plan.header.accessibilityExpandedStatus, .expanded)
        fixture.screen.view.layoutIfNeeded()
        XCTAssertLessThanOrEqual(plan.frame.height, fixture.screen.view.bounds.height / 2, "The conversation keeps most of the screen")

        fixture.client.plan([])
        await waitUntil("the plan gone") { plan.isHidden }
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

    // MARK: Tool calls

    /// A wrapped tool title breaks where a path or an option would, never mid-name.
    func testAToolTitleBreaksBetweenPartsOfAPath() {
        let zw = "\u{200B}", joiner = "\u{2060}"
        XCTAssertEqual(ToolCallHeader.breakable("Read Tests/Remote.swift", command: false), "Read Tests/\(zw)Remote.\(zw)swift")
        XCTAssertEqual(ToolCallHeader.breakable("swift test --filter a_b", command: true),
                       "swift test -\(joiner)-\(joiner)filter a_\(zw)b")
        XCTAssertEqual(ToolCallHeader.breakable("x --a=b re-run", command: true),
                       "x -\(joiner)-\(joiner)a=\(zw)b re\(zw)-\(joiner)run")
        XCTAssertEqual(ToolCallHeader.breakable("RemoteSessionLiveTests", command: true),
                       "RemoteSession\(zw)LiveTests", "A long name gives way between words, not every one")
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
