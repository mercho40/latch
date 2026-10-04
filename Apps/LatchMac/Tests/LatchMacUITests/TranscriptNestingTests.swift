import AppKit
import LatchACP
import XCTest
@testable import LatchMacUI
@testable import LatchSessionKit

/// A subagent's calls, words and thinking show under the row of its call, folded with it.
@MainActor
final class TranscriptNestingTests: XCTestCase {
    private func subagent(_ title: String, status: String = "in_progress", parent: UUID? = nil) -> ChatMessage {
        ChatMessage(role: .tool, text: "\(title) · \(status)", tool: ToolSummary(callID: title, kind: "think", status: status, runsSubagent: true),
                    parentID: parent)
    }

    private func step(_ title: String, under parent: UUID?) -> ChatMessage {
        ChatMessage(role: .tool, text: "\(title) · completed", tool: ToolSummary(callID: title, kind: "read", status: "completed"), parentID: parent)
    }

    /// Depth first, wherever the main agent's words fell between; a row whose parent is not
    /// shown, or that would close a loop, stays where it came.
    func testRowsOrderDepthFirstUnderTheirSubagents() {
        let question = ChatMessage(role: .user, text: "Look")
        let outer = subagent("Outer")
        let meanwhile = ChatMessage(role: .assistant, text: "Meanwhile")
        let read = step("Read", under: outer.id)
        let inner = subagent("Inner", parent: outer.id)
        let grep = step("Grep", under: inner.id)
        let thought = ChatMessage(role: .thought, text: "Hmm", parentID: outer.id)
        let orphan = step("Orphan", under: UUID())
        let loopID = UUID()
        let loop = ChatMessage(id: loopID, role: .assistant, text: "Self", parentID: loopID)
        let (order, parents) = ChatTranscriptView.nesting(of: [question, outer, meanwhile, read, inner, grep, thought, orphan, loop])
        XCTAssertEqual(order, [question.id, outer.id, read.id, inner.id, grep.id, thought.id, meanwhile.id, orphan.id, loop.id])
        XCTAssertEqual(parents, [read.id: outer.id, inner.id: outer.id, grep.id: inner.id, thought.id: outer.id])
    }

    func testRowsUnderAFoldedSubagentAreHiddenAndShowIndentedWhenItOpens() throws {
        let outer = subagent("Outer")
        let read = step("Read the unique file", under: outer.id)
        let after = ChatMessage(role: .assistant, text: "After")
        let transcript = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        transcript.update(messages: [outer, read, after], isWorking: false)
        transcript.layoutSubtreeIfNeeded()
        XCTAssertNil(transcript.visibleFrame(of: read.id), "Folded by default")
        XCTAssertEqual(transcript.rowFrames.count, 2)

        transcript.toggleDisclosure(of: outer.id)
        transcript.layoutSubtreeIfNeeded()
        let outerFrame = try XCTUnwrap(transcript.visibleFrame(of: outer.id))
        let readFrame = try XCTUnwrap(transcript.visibleFrame(of: read.id))
        let afterFrame = try XCTUnwrap(transcript.visibleFrame(of: after.id))
        XCTAssertEqual(readFrame.minX, outerFrame.minX + ChatTranscriptView.nestingIndent - TranscriptMessageViewGuide.width, accuracy: 0.5)
        XCTAssertGreaterThan(readFrame.minY, outerFrame.minY)
        XCTAssertGreaterThan(afterFrame.minY, readFrame.minY)

        transcript.toggleDisclosure(of: outer.id)
        transcript.layoutSubtreeIfNeeded()
        XCTAssertNil(transcript.visibleFrame(of: read.id))
    }

    /// Find looks only in what can be revealed: a step's details are not searched while folded.
    func testFindSkipsRowsUnderAFoldedSubagent() {
        let outer = subagent("Outer")
        let words = ChatMessage(role: .assistant, text: "needle in the subagent", parentID: outer.id)
        let transcript = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        transcript.update(messages: [outer, words], isWorking: false)
        transcript.search("needle")
        XCTAssertEqual(transcript.matchCount, 0)
        transcript.toggleDisclosure(of: outer.id)
        XCTAssertEqual(transcript.matchCount, 1)
    }

    func testPlanSummaryCountsDoneStepsAndNamesTheOneInHand() {
        let entries = [ACPPlanEntry(content: "Read", status: .completed), ACPPlanEntry(content: "Fix", status: .inProgress),
                       ACPPlanEntry(content: "Ship", status: .pending)]
        let summary = PlanPanel.summary(of: entries)
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.current, "Fix")
        XCTAssertEqual(PlanPanel.summary(of: [ACPPlanEntry(content: "Next", status: .pending)]).current, "Next")
        XCTAssertNil(PlanPanel.summary(of: [ACPPlanEntry(content: "Done", status: .completed)]).current)
        let list = PlanPanel.checklist(entries, font: .systemFont(ofSize: 12)).string
        XCTAssertTrue(list.contains(" Read\n") && list.contains(" Fix\n") && list.hasSuffix(" Ship"), list)
    }
}
