import LatchACP
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// The order the conversation's rows are shown in, with subagents' rows under their own, and
/// what the rows and the plan bar say, worked out without a screen.
@MainActor
final class TranscriptOutlineTests: XCTestCase {
    private func tool(_ title: String, status: String = "completed", kind: String? = nil, subagent: Bool = false,
                      parent: ChatMessage? = nil) -> ChatMessage {
        ChatMessage(role: .tool, text: "\(title) · \(status)",
                    tool: ToolSummary(callID: title, kind: kind, status: status, runsSubagent: subagent), parentID: parent?.id)
    }

    // MARK: Order

    /// A subagent's rows follow its own, depth-first in the order they came, wherever they
    /// arrived among the rest; while any row above them is collapsed, they are not shown.
    func testASubagentsRowsFollowItDepthFirstAndHideWhileCollapsed() {
        let prompt = ChatMessage(role: .user, text: "Go")
        let agent = tool("Explore", status: "in_progress", subagent: true)
        let early = ChatMessage(role: .assistant, text: "Meanwhile, at the top")
        let read = tool("Read a.swift", kind: "read", parent: agent)
        let thought = ChatMessage(role: .thought, text: "Hmm", parentID: agent.id)
        let nested = tool("Look deeper", status: "in_progress", subagent: true, parent: agent)
        let deep = tool("Read b.swift", kind: "read", parent: nested)
        let words = ChatMessage(role: .assistant, text: "Found it", parentID: agent.id)
        let late = ChatMessage(role: .assistant, text: "Done")
        let messages = [prompt, agent, early, read, thought, nested, deep, words, late]

        XCTAssertEqual(TranscriptOutline(messages, expanded: []).rows, [prompt, agent, early, late].map(\.id),
                       "Collapsed by default")
        XCTAssertEqual(TranscriptOutline(messages, expanded: [agent.id]).rows,
                       [prompt, agent, read, thought, nested, words, early, late].map(\.id))
        let open = TranscriptOutline(messages, expanded: [agent.id, nested.id])
        XCTAssertEqual(open.rows, [prompt, agent, read, thought, nested, deep, words, early, late].map(\.id))
        XCTAssertEqual(open.rows.map { open.info[$0]?.depth }, [0, 0, 1, 1, 1, 2, 1, 0, 0])
        XCTAssertEqual(TranscriptOutline(messages, expanded: [nested.id]).rows, [prompt, agent, early, late].map(\.id),
                       "Hidden while any row above is collapsed")

        let summary = open.info[agent.id]
        XCTAssertEqual(summary?.steps, 3, "Every tool row under it, at any depth")
        XCTAssertEqual(summary?.latestStep, "Read b.swift")
        XCTAssertEqual(summary?.hasChildren, true)
        XCTAssertEqual(open.info[nested.id]?.steps, 1)
        XCTAssertEqual(open.info[read.id]?.hasChildren, false)
        XCTAssertEqual(TranscriptOutline(messages, expanded: []).info[agent.id]?.steps, 3, "Counted while collapsed too")
    }

    /// A parent that is not in the list, is not a tool row, or would make a loop leaves the row
    /// at the top, where it arrived; a prompt is always at the top. Nothing is lost.
    func testAMessageWithoutAUsableParentStandsAtTheTop() {
        let gone = ChatMessage(role: .assistant, text: "Its subagent was evicted", parentID: UUID())
        let reply = ChatMessage(role: .assistant, text: "A reply")
        let underReply = ChatMessage(role: .assistant, text: "Under a reply", parentID: reply.id)
        let agent = tool("Agent", subagent: true)
        let prompt = ChatMessage(role: .user, text: "A prompt", parentID: agent.id)
        let selfParent = ChatMessage(id: UUID(), role: .tool, text: "Self · completed")
        let looped = ChatMessage(id: selfParent.id, role: .tool, text: "Self · completed", parentID: selfParent.id)
        var first = tool("First")
        let second = tool("Second", parent: first)
        first.parentID = second.id
        let messages = [gone, reply, underReply, agent, prompt, looped, first, second]
        let outline = TranscriptOutline(messages, expanded: Set(messages.map(\.id)))
        XCTAssertEqual(outline.rows, [gone, reply, underReply, agent, prompt, looped, second, first].map(\.id),
                       "Of two rows naming each other, the later stays at the top with the earlier under it")
        XCTAssertEqual(outline.rows.map { outline.info[$0]?.depth }, [0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(TranscriptOutline(messages + [gone], expanded: []).rows.filter { $0 == gone.id }.count, 1,
                       "A message twice is shown once")
    }

    /// A row given its parent after a later row arrived still goes under it.
    func testARowGivenItsParentLaterMovesUnderIt() {
        var early = tool("Read early.swift")
        let agent = tool("Agent", subagent: true)
        early.parentID = agent.id
        XCTAssertEqual(TranscriptOutline([early, agent], expanded: [agent.id]).rows, [agent.id, early.id])
    }

    // MARK: Rows

    /// The symbol comes from the call's kind, or for a row without one, from its title; the
    /// status from the summary.
    func testAToolRowsSymbolComesFromItsKind() {
        XCTAssertEqual(ToolCallPresentation(tool("Check the build", kind: "execute")).symbolName, "terminal")
        XCTAssertEqual(ToolCallPresentation(tool("Explore", kind: "think", subagent: true)).symbolName, "person.2")
        XCTAssertEqual(ToolCallPresentation(tool("Update the todos", kind: "think")).symbolName, "lightbulb")
        XCTAssertEqual(ToolCallPresentation(tool("Find usages", kind: "search")).symbolName, "magnifyingglass")
        XCTAssertEqual(ToolCallPresentation(tool("Read a", kind: "other")).symbolName, "doc.text", "Other says nothing: guessed")
        XCTAssertEqual(ToolCallPresentation(ChatMessage(role: .tool, text: "Edit a.swift · completed")).symbolName, "pencil",
                       "Saved before the summary: guessed from the title")
        var stale = tool("Run", status: "in_progress", kind: "execute")
        stale.tool?.status = "failed"
        XCTAssertEqual(ToolCallPresentation(stale).statusText, "Failed")
        XCTAssertEqual(ToolCallPresentation.displayTitle(of: "`ls -la` · completed\n\nOutput:\nx"), "ls -la")
    }

    /// A subagent's header counts its steps and, while it runs, names the latest.
    func testASubagentsHeaderCountsItsSteps() {
        let header = ToolCallHeader()
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let running = ToolCallPresentation(tool("Explore the code", status: "in_progress", subagent: true))
        header.show(running, expanded: false, hasDetails: false, traits: traits,
                    row: TranscriptRowInfo(depth: 0, hasChildren: true, steps: 4, latestStep: "Read a.swift"))
        XCTAssertEqual(header.accessibilityLabel, "Subagent: Explore the code, 4 steps, Running")
        XCTAssertEqual(header.accessibilityValue, "Latest step: Read a.swift")
        XCTAssertTrue(header.accessibilityTraits.contains(.button), "Its steps are something to show")
        XCTAssertEqual(header.accessibilityHint, "Shows its steps.")
        XCTAssertTrue(header.allLabels.contains { $0.text == "4 steps · Running" })
        XCTAssertTrue(header.allLabels.contains { $0.text == "Read a.swift" && !$0.isHidden })

        let done = ToolCallPresentation(tool("Explore the code", subagent: true))
        header.show(done, expanded: true, hasDetails: false, traits: traits,
                    row: TranscriptRowInfo(depth: 0, hasChildren: true, steps: 1, latestStep: "Read a.swift"))
        XCTAssertEqual(header.accessibilityLabel, "Subagent: Explore the code, 1 step, Done")
        XCTAssertNil(header.accessibilityValue, "Finished: no latest step")
        XCTAssertFalse(header.allLabels.contains { $0.text == "Read a.swift" && !$0.isHidden })
        XCTAssertEqual(header.accessibilityExpandedStatus, .expanded)
    }

    /// A thought folds to "Thinking" and its first words on one line.
    func testAThoughtsPreviewIsOneLineOfPlainText() {
        XCTAssertEqual(ThoughtPresentation.preview("**Planning**\n\nI need   to\tcheck\nthe server."),
                       "Planning I need to check the server.")
        XCTAssertEqual(ThoughtPresentation.preview("  \n  "), "")
        let long = ThoughtPresentation.preview(String(repeating: "word ", count: 200))
        XCTAssertTrue(long.hasSuffix("…"), long)
        XCTAssertLessThanOrEqual(long.count, 161)

        let header = ToolCallHeader()
        header.showThought("Planning I need to check", expanded: false, traits: UITraitCollection(preferredContentSizeCategory: .large))
        XCTAssertEqual(header.accessibilityLabel, "Thinking")
        XCTAssertEqual(header.accessibilityValue, "Planning I need to check")
        XCTAssertEqual(header.accessibilityExpandedStatus, .collapsed)
        XCTAssertEqual(header.accessibilityHint, "Shows the whole thought.")
    }

    // MARK: Plan

    func testThePlanBarSaysHowFarThePlanHasGot() {
        let plan = [ACPPlanEntry(content: "Read", status: .completed), ACPPlanEntry(content: "Think", status: .completed),
                    ACPPlanEntry(content: "Write the tests", status: .inProgress), ACPPlanEntry(content: "Fix", status: .pending),
                    ACPPlanEntry(content: "Ship", status: .pending)]
        let summary = PlanSummary(plan)
        XCTAssertEqual(summary.title, "Plan · 2 of 5")
        XCTAssertEqual(summary.current, "Write the tests")
        XCTAssertEqual(summary.spoken, "Plan, 2 of 5 done, now: Write the tests")
        let notStarted = PlanSummary([ACPPlanEntry(content: "Read", status: .completed), ACPPlanEntry(content: "Fix", status: .pending)])
        XCTAssertEqual(notStarted.spoken, "Plan, 1 of 2 done, next: Fix", "The first step still to do")
        XCTAssertEqual(PlanSummary([ACPPlanEntry(content: "Read", status: .completed)]).spoken, "Plan, 1 of 1 done")

        let view = SessionPlanView()
        XCTAssertTrue(view.isHidden, "No plan, no bar")
        view.show(plan)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.header.accessibilityLabel, "Plan, 2 of 5 done, now: Write the tests")
        XCTAssertEqual(view.header.accessibilityExpandedStatus, .collapsed)
        view.toggle()
        XCTAssertEqual(view.header.accessibilityExpandedStatus, .expanded)
        let rows = view.allSubviews.compactMap { $0 as? UIStackView }.filter(\.isAccessibilityElement)
        XCTAssertEqual(rows.map(\.accessibilityLabel), plan.map(\.content), "Each step is read when open")
        XCTAssertEqual(rows.map(\.accessibilityValue), ["Done", "Done", "In progress", "To do", "To do"])
        let done = rows.first?.allLabels.first
        XCTAssertNotNil(done?.attributedText?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil), "Done is struck through")
        view.show([])
        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.isExpanded, "A new plan starts closed")
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
    var allLabels: [UILabel] { allSubviews.compactMap { $0 as? UILabel } }
}
