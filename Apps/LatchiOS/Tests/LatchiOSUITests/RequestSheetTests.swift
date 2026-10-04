import LatchACP
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// The agent's questions and the richer permission sheet: answering, skipping and refusing a
/// question, an Other box taking the place of the options, Submit waiting for what is
/// required, the agent's words kept under Latch's labels, a plan shown as Markdown, and one
/// sheet at a time between them.
@MainActor
final class RequestSheetTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach(Snapshot.tearDown)
        windows = []
        try await super.tearDown()
    }

    private func shown() async -> SessionScreenFixture {
        let fixture = SessionScreenFixture()
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.connect()
        fixture.type("Fix the reconnect test")
        fixture.screen.send()
        await waitUntil("the prompt to reach the client") { fixture.client.hasOpenTurn }
        return fixture
    }

    private static var form: QuestionForm { QuestionForm(SampleQuestions.request)! }

    private func sheet(_ form: QuestionForm = RequestSheetTests.form,
                       outcomes: @escaping (QuestionViewController.Outcome) -> Void = { _ in }) -> QuestionViewController {
        let sheet = QuestionViewController(id: UUID(), form: form, agentTitle: "Claude Code", respond: outcomes)
        sheet.loadViewIfNeeded()
        return sheet
    }

    private func tap(_ button: UIButton?) { button?.sendActions(for: .primaryActionTriggered) }

    /// The sheet the screen put up, with its view: the test host never presents it.
    private func questionSheet(_ fixture: SessionScreenFixture) -> QuestionViewController? {
        fixture.screen.questionSheet?.loadViewIfNeeded()
        return fixture.screen.questionSheet
    }

    private func type(_ text: String, in field: UITextField?) {
        field?.text = text
        field?.sendActions(for: .editingChanged)
    }

    // MARK: Questions

    func testAQuestionIsASheetThatAnswersThroughTheModel() async throws {
        let fixture = await shown()
        fixture.client.ask()
        await waitUntil("the question's sheet") { fixture.screen.questionSheet != nil }
        let sheet = try XCTUnwrap(fixture.screen.questionSheet)
        XCTAssertTrue(fixture.presentedSheets.last === sheet)
        XCTAssertNil(fixture.screen.permissionSheet)
        XCTAssertTrue(sheet.isModalInPresentation, "The sheet cannot be swiped away")
        XCTAssertEqual(sheet.modalPresentationStyle, .formSheet)
        XCTAssertEqual(sheet.sheetPresentationController?.detents.map(\.identifier), [RequestSheetViewController.fitDetent, .large])
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.form.message, "Please answer the following questions.")
        let labels = sheet.view.allLabels.compactMap(\.text)
        for text in ["Claude Code asks", "Please answer the following questions.", "Port",
                     "How should the server keep its port across a restart?", "Checks", "Choose any that apply."] {
            XCTAssertTrue(labels.contains(text), "Shows “\(text)”: \(labels)")
        }
        XCTAssertEqual(sheet.optionButtons["question_0"]?.map { $0.configuration?.title }, ["Reuse the port", "Take a new port"])
        XCTAssertEqual(sheet.optionButtons["question_0"]?.first?.configuration?.subtitle,
                       "Set SO_REUSEADDR before bind, as the Mac does by default.")
        XCTAssertEqual(sheet.previews.count, 2, "Each option's preview is shown under it")
        XCTAssertEqual([sheet.submitButton, sheet.skipButton, sheet.cancelButton].map { $0.configuration?.title },
                       ["Submit", "Skip", "Cancel Request"])
        XCTAssertFalse(sheet.submitButton.isEnabled, "Nothing is chosen for the required question")

        tap(sheet.optionButtons["question_0"]?[0])
        XCTAssertTrue(sheet.submitButton.isEnabled, "The second question may go unanswered")
        tap(sheet.optionButtons["question_1"]?[2])
        tap(sheet.optionButtons["question_1"]?[0])
        tap(sheet.submitButton)
        await waitUntil("the answer to reach the server") { !fixture.client.elicitationResponses.isEmpty }
        XCTAssertEqual(fixture.client.elicitationResponses, [ACPElicitationResponse(action: .accept, content: [
            "question_0": .string("reuse"), "question_1": .array([.string("linux"), .string("fifty")]),
        ])], "Several choices go in the agent's order, whatever the order of the taps")
        await waitUntil("the sheet to go") { fixture.screen.questionSheet == nil }
        XCTAssertTrue(fixture.dismissedSheets.last === sheet)
        XCTAssertNil(fixture.model.questions.current)
        tap(sheet.skipButton)
        XCTAssertEqual(fixture.client.elicitationResponses.count, 1, "A sheet answers once")
        fixture.client.endTurn()
    }

    func testSkipDeclinesCancelRefusesAndAWithdrawnQuestionGoes() async throws {
        let fixture = await shown()
        fixture.client.ask()
        await waitUntil("the first sheet") { fixture.screen.questionSheet != nil }
        tap(questionSheet(fixture)?.skipButton)
        await waitUntil("the skip") { fixture.client.elicitationResponses == [ACPElicitationResponse(action: .decline)] }
        await waitUntil("the first sheet to go") { fixture.screen.questionSheet == nil }

        fixture.client.ask()
        await waitUntil("the second sheet") { fixture.screen.questionSheet != nil }
        let second = try XCTUnwrap(questionSheet(fixture))
        XCTAssertEqual(second.keyCommands?.map(\.input), [UIKeyCommand.inputEscape, "\r"], "Escape cancels, ⌘Return submits")
        tap(second.cancelButton)
        await waitUntil("the refusal") { fixture.client.elicitationResponses.last == .cancelled }
        await waitUntil("the second sheet to go") { fixture.screen.questionSheet == nil }

        let third = fixture.client.ask()
        await waitUntil("the third sheet") { fixture.screen.questionSheet != nil }
        let shown = try XCTUnwrap(fixture.screen.questionSheet)
        fixture.client.closeQuestion(third)
        await waitUntil("the withdrawn question's sheet to go") { fixture.screen.questionSheet == nil }
        XCTAssertTrue(fixture.dismissedSheets.last === shown)
        XCTAssertNil(fixture.model.questions.current)
        XCTAssertEqual(fixture.presentedSheets.count, 3)
        fixture.client.endTurn()
    }

    /// What is typed under Other takes the place of the options and the other way round, so
    /// what shows chosen is what is sent.
    func testAnOtherAnswerTakesThePlaceOfTheChoice() throws {
        var outcomes: [QuestionViewController.Outcome] = []
        let sheet = sheet { outcomes.append($0) }
        let options = try XCTUnwrap(sheet.optionButtons["question_0"])
        let other = try XCTUnwrap(sheet.textFields["question_0_custom"])
        tap(options[0])
        XCTAssertTrue(options[0].isSelected)
        type("Keep a socket open across the restart", in: other)
        XCTAssertFalse(options[0].isSelected, "Typing clears the choice")
        XCTAssertNil(sheet.answers["question_0"])
        XCTAssertTrue(sheet.submitButton.isEnabled, "An answer of the user's own answers the required question")
        type("   ", in: other)
        XCTAssertFalse(sheet.submitButton.isEnabled, "Spaces are no answer")
        type("MySQL", in: other)
        tap(options[1])
        XCTAssertTrue(options[1].isSelected)
        XCTAssertEqual(other.text, "", "Choosing clears what was typed")
        XCTAssertNil(sheet.answers["question_0_custom"])

        let checks = try XCTUnwrap(sheet.optionButtons["question_1"])
        tap(checks[0])
        tap(checks[1])
        XCTAssertEqual(checks.map(\.isSelected), [true, true, false], "Any number")
        type("Run it on the Pi", in: sheet.textFields["question_1_custom"])
        XCTAssertEqual(checks.map(\.isSelected), [false, false, false])
        tap(options[1])
        XCTAssertTrue(options[1].isSelected, "The one chosen stays chosen when tapped again: the question is required")
        tap(sheet.submitButton)
        XCTAssertEqual(outcomes, [.answer(["question_0": .choices(["fresh"]), "question_1_custom": .text("Run it on the Pi")])])
        let content = sheet.form.content(for: sheet.answers)
        XCTAssertEqual(content, ["question_0": .string("fresh"), "question_1_custom": .string("Run it on the Pi")])
    }

    /// An MCP server's form: Submit waits for the required fields, and for every number typed
    /// to be one; a switch answers what it shows.
    func testSubmitWaitsForWhatIsRequiredAndForNumbers() throws {
        let request = ACPElicitationRequest(sessionId: "s", message: "Configure the deploy", requestedSchema: .object([
            "type": .string("object"), "required": .array([.string("name"), .string("port")]),
            "properties": .object([
                "name": .object(["type": .string("string"), "title": .string("Name")]),
                "port": .object(["type": .string("integer"), "description": .string("Which port?")]),
                "ratio": .object(["type": .string("number")]),
                "verbose": .object(["type": .string("boolean"), "title": .string("Verbose logging")]),
            ]),
        ]))
        var outcomes: [QuestionViewController.Outcome] = []
        let sheet = sheet(try XCTUnwrap(QuestionForm(request))) { outcomes.append($0) }
        XCTAssertFalse(sheet.submitButton.isEnabled)
        XCTAssertEqual(sheet.submitButton.accessibilityHint, "Answer the required questions first.")
        type("api", in: sheet.textFields["name"])
        type("80a", in: sheet.textFields["port"])
        XCTAssertFalse(sheet.submitButton.isEnabled, "Not a number")
        XCTAssertTrue(sheet.view.allLabels.contains { $0.text == "Enter a whole number." && !$0.isHidden })
        type("8080", in: sheet.textFields["port"])
        XCTAssertTrue(sheet.submitButton.isEnabled)
        XCTAssertFalse(sheet.view.allLabels.contains { $0.text == "Enter a whole number." && !$0.isHidden })
        type("nan", in: sheet.textFields["ratio"])
        XCTAssertFalse(sheet.submitButton.isEnabled, "An optional number still has to be one")
        type("", in: sheet.textFields["ratio"])
        XCTAssertEqual(sheet.textFields["port"]?.keyboardType, .numbersAndPunctuation)
        XCTAssertEqual(sheet.textFields["name"]?.keyboardType, .default)
        XCTAssertEqual(sheet.textFields["port"]?.accessibilityLabel, "Which port?")
        XCTAssertEqual(sheet.switches["verbose"]?.accessibilityLabel, "Verbose logging")
        tap(sheet.submitButton)
        let content = try XCTUnwrap(outcomes.first.flatMap { if case let .answer(answers) = $0 { sheet.form.content(for: answers) } else { nil } })
        XCTAssertEqual(content, ["name": .string("api"), "port": .integer(8080), "verbose": .bool(false)],
                       "The switch is sent as it shows")
    }

    /// Each option is a button that says when it is chosen; a preview is read whole, and a
    /// long one shows its first lines until Show All.
    func testOptionsSayWhenTheyAreChosenAndPreviewsCanBeOpened() throws {
        let long = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let request = ACPElicitationRequest(sessionId: "s", message: "Which layout?", requestedSchema: .object([
            "type": .string("object"), "properties": .object([
                "question_0": .object(["type": .string("string"), "oneOf": .array([
                    SampleQuestions.option("grid", "Grid", "Cards in rows", preview: long),
                    SampleQuestions.option("list", "List", "One per line"),
                ])]),
            ]),
        ]))
        let sheet = sheet(try XCTUnwrap(QuestionForm(request)))
        let options = try XCTUnwrap(sheet.optionButtons["question_0"])
        XCTAssertEqual(options[0].accessibilityLabel, "Grid")
        XCTAssertEqual(options[0].accessibilityValue, "Cards in rows")
        XCTAssertFalse(options[0].accessibilityTraits.contains(.selected))
        tap(options[0])
        XCTAssertTrue(options[0].isSelected)
        XCTAssertTrue(options[0].accessibilityTraits.contains(.selected))
        XCTAssertTrue(options[0].accessibilityTraits.contains(.button))
        XCTAssertEqual(sheet.submitButton.isEnabled, true, "Not required, but answered")
        tap(options[0])
        XCTAssertNil(sheet.answers["question_0"], "A question that may go unanswered can be cleared")
        XCTAssertNil(sheet.textFields["question_0_custom"], "No Other box when the agent takes none")

        let preview = try XCTUnwrap(sheet.previews.first)
        XCTAssertEqual(preview.text, long)
        let label = try XCTUnwrap(preview.allLabels.first)
        XCTAssertEqual(label.accessibilityValue, long, "VoiceOver reads it whole")
        XCTAssertEqual(label.text?.components(separatedBy: "\n").count, QuestionPreviewView.collapsedLines)
        XCTAssertFalse(preview.toggle.isHidden)
        XCTAssertEqual(preview.toggle.configuration?.title, "Show All 20 Lines")
        preview.toggle.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(label.text?.components(separatedBy: "\n").count, 20)
        XCTAssertEqual(preview.toggle.configuration?.title, "Show Less")
        let font = try XCTUnwrap(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    // MARK: One at a time

    /// A question waits while a request's sheet shows, and a request while a question's does.
    func testOneSheetAtATime() async throws {
        let fixture = await shown()
        fixture.client.requestPermission(title: "First")
        await waitUntil("the request's sheet") { fixture.screen.permissionSheet != nil }
        fixture.client.ask()
        await waitUntil("the question") { fixture.model.questions.current != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(fixture.screen.questionSheet, "The question waits")
        XCTAssertEqual(fixture.presentedSheets.count, 1)
        fixture.screen.permissionSheet?.finish("allow")
        await waitUntil("the question's sheet") { fixture.screen.questionSheet != nil }
        XCTAssertNil(fixture.screen.permissionSheet)
        XCTAssertEqual(fixture.presentedSheets.count, 2)

        fixture.client.requestPermission(title: "Second")
        await waitUntil("the request") { fixture.model.permissions.current != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(fixture.screen.permissionSheet, "The request waits for the question")
        XCTAssertEqual(fixture.presentedSheets.count, 2)
        fixture.screen.questionSheet?.cancelRequest()
        await waitUntil("the request's sheet") { fixture.screen.permissionSheet?.requestTitle == "Second" }
        XCTAssertNil(fixture.screen.questionSheet)
        XCTAssertEqual(fixture.presentedSheets.count, 3)
        fixture.screen.permissionSheet?.finish(nil)
        fixture.client.endTurn()
    }

    func testAQuestionTakenDownElsewhereIsShownAgain() async throws {
        let fixture = await shown()
        fixture.client.ask()
        await waitUntil("the sheet") { fixture.presentedSheets.count == 1 }
        let first = try XCTUnwrap(fixture.screen.questionSheet)
        first.onDismissedElsewhere?()
        await waitUntil("the sheet again") { fixture.presentedSheets.count == 2 }
        XCTAssertEqual(fixture.screen.questionSheet?.questionID, first.questionID)
        XCTAssertFalse(fixture.screen.questionSheet === first)
        fixture.screen.questionSheet?.cancelRequest()
        fixture.client.endTurn()
    }

    // MARK: Permission

    /// Latch's labels on the buttons, and the agent's words only under them; its heading and
    /// reason above the details.
    func testThePermissionSheetKeepsTheAgentsWordsUnderLatchsLabels() async throws {
        let fixture = await shown()
        fixture.client.requestPermission(title: "rm -rf build", heading: "Run a command?",
                                         reason: "Reason: the build folder is stale")
        await waitUntil("the sheet") { fixture.screen.permissionSheet != nil }
        let sheet = try XCTUnwrap(fixture.screen.permissionSheet)
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.requestTitle, "Run a command?")
        XCTAssertEqual(sheet.reason, "Reason: the build folder is stale")
        XCTAssertFalse(sheet.isCommand, "The agent's heading is prose, not the command")
        XCTAssertFalse(sheet.detailsRepeatTitle, "The command is in the details, since the heading does not say it")
        let labels = sheet.view.allLabels.compactMap(\.text)
        XCTAssertTrue(labels.contains("Run a command?"))
        XCTAssertTrue(labels.contains("Reason: the build folder is stale"))
        XCTAssertNotNil(sheet.view.allSubviews.first { $0.accessibilityLabel == "Tool details" })
        XCTAssertEqual(sheet.optionButtons.map { $0.configuration?.title }, ["Allow Once", "Always Allow", "Reject Once"])
        XCTAssertEqual(sheet.optionButtons.map { $0.configuration?.subtitle },
                       ["Yes", "Yes, and don’t ask again for rm commands in ~/latch", "No, and tell Claude what to do differently"])
        XCTAssertEqual(sheet.optionButtons.map(\.accessibilityLabel), ["Allow Once", "Always Allow", "Reject Once"],
                       "VoiceOver names each button by Latch's label")
        XCTAssertEqual(sheet.optionButtons.map(\.accessibilityValue), sheet.optionButtons.map { $0.configuration?.subtitle })
        sheet.finish(nil)
        fixture.client.endTurn()
    }

    /// The agent's words never replace a label, even when they claim to be another option.
    func testAnOptionCannotPassItselfOffAsAnother() async throws {
        let fixture = await shown()
        fixture.client.requestPermission(title: "rm -rf ~", options: [
            ACPPermissionOption(optionId: "allow", name: "Reject Once", kind: "allow_once"),
            ACPPermissionOption(optionId: "reject", name: "Reject", kind: "reject_once"),
        ])
        await waitUntil("the sheet") { fixture.screen.permissionSheet != nil }
        let sheet = try XCTUnwrap(fixture.screen.permissionSheet)
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.optionButtons.map { $0.configuration?.title }, ["Allow Once", "Reject Once"])
        XCTAssertNil(sheet.optionButtons.first?.configuration?.subtitle,
                     "Words that say the opposite of Latch's own label are not shown, not even under it")
        sheet.finish(nil)
        fixture.client.endTurn()
    }

    /// Claude Code's plan approval: its heading, and the plan as Markdown in place of the details.
    func testAPlanApprovalShowsThePlanAsMarkdown() async throws {
        let fixture = await shown()
        fixture.client.requestPlanApproval()
        await waitUntil("the sheet") { fixture.screen.permissionSheet != nil }
        let sheet = try XCTUnwrap(fixture.screen.permissionSheet)
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.requestTitle, "Ready to code?")
        XCTAssertEqual(sheet.plan, SamplePlan.text)
        let plan = try XCTUnwrap(sheet.planView)
        XCTAssertTrue(plan.plainText.hasPrefix("Keep the port across a restart"), plan.plainText)
        XCTAssertTrue(plan.plainText.contains("No public API changes."))
        XCTAssertNil(sheet.view.allSubviews.first { $0.accessibilityLabel == "Tool details" }, "The plan is not shown twice")
        XCTAssertTrue(sheet.view.allLabels.contains { $0.text == "Ready to code?" })
        XCTAssertEqual(sheet.optionButtons.map { $0.configuration?.title }, ["Always Allow", "Allow Once", "Reject Once"])
        XCTAssertEqual(sheet.optionButtons.map { $0.configuration?.subtitle },
                       ["Yes, and auto-accept edits", "Yes, and manually approve edits", "No, keep planning"])
        XCTAssertEqual(Set(sheet.optionButtons.map { $0.configuration?.cornerStyle }), [.large], "Every option keeps one look")
        // Measured with the plan in it, so the sheet opens tall enough to show it.
        XCTAssertGreaterThan(sheet.fittingHeight, 400)
        tap(sheet.optionButtons[1])
        await waitUntil("the decision") {
            fixture.client.commands.contains { if case .resolvePermission(_, _, .selected(optionID: "default")) = $0 { true } else { false } }
        }
        fixture.client.endTurn()
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
    var allLabels: [UILabel] { allSubviews.compactMap { $0 as? UILabel } }
}
