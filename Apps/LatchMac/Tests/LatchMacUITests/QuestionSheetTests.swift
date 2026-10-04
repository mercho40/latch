import AppKit
import LatchACP
import XCTest
@testable import LatchMacUI
@testable import LatchSessionKit

/// The agent's questions and requests as the Mac shows them.
@MainActor
final class QuestionSheetTests: XCTestCase {
    private func question(_ schema: [String: ACPJSONValue], required: [String] = [], message: String = "Which database?") throws -> QuestionQueue.Question {
        var object: [String: ACPJSONValue] = ["type": .string("object"), "properties": .object(schema)]
        if !required.isEmpty { object["required"] = .array(required.map(ACPJSONValue.string)) }
        let request = ACPElicitationRequest(sessionId: "s", message: message, requestedSchema: .object(object))
        return QuestionQueue.Question(id: UUID(), request: request, form: try XCTUnwrap(QuestionForm(request)))
    }

    private static let database: [String: ACPJSONValue] = [
        "question_0": .object(["type": .string("string"), "oneOf": .array([
            .object(["const": .string("Postgres"), "title": .string("Postgres"), "description": .string("Relational")]),
            .object(["const": .string("SQLite"), "title": .string("SQLite")]),
        ])]),
        "question_0_custom": .object(["type": .string("string"), "title": .string("Other"),
                                      "_meta": .object(["_askUserQuestionCustomAnswer": .object(["questionId": .string("question_0")])])]),
    ]

    /// One option at a time, and an answer of the user's own takes the options' place.
    func testAChoiceOrAnAnswerOfTheUsersOwnIsSent() throws {
        let sheet = QuestionSheet(question: try question(Self.database))
        var outcome: QuestionSheet.Outcome?
        sheet.onFinish = { outcome = $0 }
        XCTAssertEqual(sheet.choices["question_0"]?.map(\.value), ["Postgres", "SQLite"])
        sheet.choose(["Postgres"], for: "question_0")
        sheet.choose(["SQLite"], for: "question_0")
        XCTAssertEqual(sheet.choices["question_0"]?.map { $0.button.state }, [.off, .on])
        sheet.type("MySQL", into: "question_0_custom")
        XCTAssertEqual(sheet.choices["question_0"]?.map { $0.button.state }, [.off, .off])
        XCTAssertTrue(sheet.submit.isEnabled)
        sheet.submit.performClick(nil)
        XCTAssertEqual(outcome, .answer(["question_0_custom": .text("MySQL")]))
        XCTAssertLessThanOrEqual(sheet.panel.frame.width, QuestionSheet.width + 1)
    }

    /// Submit waits for every required field.
    func testSubmitWaitsForWhatIsRequired() throws {
        let sheet = QuestionSheet(question: try question(["name": .object(["type": .string("string")])], required: ["name"], message: "Name it"))
        XCTAssertFalse(sheet.submit.isEnabled)
        sheet.type("box", into: "name")
        XCTAssertTrue(sheet.submit.isEnabled)
    }

    /// A plan to approve shows as the plan, and the agent's words for each choice sit beside
    /// Latch's own label, never in its place.
    func testAPermissionShowsThePlanAndTheAgentsWordsBesideTheLabels() {
        let request = ACPPermissionRequest(
            sessionId: "s",
            toolCall: .object(["toolCallId": .string("plan"), "kind": .string("switch_mode"), "title": .string("Ready to code?"),
                               "content": .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("## Plan\n\n1. Read the code")])])])]),
            options: [ACPPermissionOption(optionId: "exit-plan-default", name: "Yes, manually approve edits", kind: "allow_once"),
                      ACPPermissionOption(optionId: "reject", name: "No, keep planning", kind: "reject_once")]
        )
        let body = SessionViewController.permissionBody(PermissionQueue.Prompt(id: UUID(), request: request)).string
        XCTAssertTrue(body.contains("Read the code") && !body.contains("## Plan"), body)
        XCTAssertTrue(body.contains("Allow Once: Yes, manually approve edits") && body.contains("Reject Once: No, keep planning"), body)
        let command = ACPPermissionRequest(sessionId: "s", toolCall: .object(["toolCallId": .string("b"), "title": .string("git status"),
                                                                               "rawInput": .object(["command": .string("git status")])]),
                                           options: [ACPPermissionOption(optionId: "allow-once", name: "Allow Once", kind: "allow_once")])
        let details = SessionViewController.permissionBody(PermissionQueue.Prompt(id: UUID(), request: command)).string
        XCTAssertTrue(details.contains("git status") && !details.contains("What the agent says"), details)
        XCTAssertTrue(details.contains("Full request") && !body.contains("Full request"), "A plan is shown whole; a command's request in full")
    }
}
