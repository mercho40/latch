import Foundation
import LatchACP
import XCTest
@testable import LatchSessionKit

/// The agent's questions as Claude Code asks them, read into forms and answered.
final class QuestionFormTests: XCTestCase {
    /// AskUserQuestion's form for two questions, as claude-agent-acp builds it: each question
    /// a field, its own "Other" box beside it, option descriptions and previews.
    private static let askUserQuestion = ACPElicitationRequest(
        sessionId: "s", message: "Please answer the following questions.",
        requestedSchema: .object(["type": .string("object"), "properties": .object([
            "question_0": .object(["type": .string("string"), "title": .string("Database"), "description": .string("Which database?"),
                                   "oneOf": .array([
                                       .object(["const": .string("Postgres"), "title": .string("Postgres"), "description": .string("Relational"),
                                                "_meta": .object(["_claude/askUserQuestionOption": .object(["preview": .string("CREATE TABLE …")])])]),
                                       .object(["const": .string("SQLite"), "title": .string("SQLite")]),
                                   ])]),
            "question_0_custom": .object(["type": .string("string"), "title": .string("Other"),
                                          "_meta": .object(["_askUserQuestionCustomAnswer": .object(["questionId": .string("question_0"), "isCustomAnswer": .bool(true)])])]),
            "question_10": .object(["type": .string("array"), "title": .string("Extras"), "description": .string("Which extras?"),
                                    "items": .object(["anyOf": .array([
                                        .object(["const": .string("Auth"), "title": .string("Auth")]),
                                        .object(["const": .string("Admin"), "title": .string("Admin")]),
                                    ])])]),
            "question_10_custom": .object(["type": .string("string"), "title": .string("Other"),
                                           "_meta": .object(["_askUserQuestionCustomAnswer": .object(["questionId": .string("question_10")])])]),
            "question_2": .object(["type": .string("string"), "oneOf": .array([.object(["const": .string("Yes"), "title": .string("Yes")])])]),
        ])]),
        toolCallId: "call-1"
    )

    func testReadsClaudeCodesQuestionsInOrderWithTheirOtherBoxes() throws {
        let form = try XCTUnwrap(QuestionForm(Self.askUserQuestion))
        XCTAssertEqual(form.message, "Please answer the following questions.")
        XCTAssertEqual(form.fields.map(\.key), ["question_0", "question_2", "question_10"])
        let database = form.fields[0]
        XCTAssertEqual(database.title, "Database")
        XCTAssertEqual(database.prompt, "Which database?")
        XCTAssertEqual(database.otherKey, "question_0_custom")
        XCTAssertEqual(database.kind, .choice(options: [
            .init(value: "Postgres", title: "Postgres", detail: "Relational", preview: "CREATE TABLE …"),
            .init(value: "SQLite", title: "SQLite", detail: nil, preview: nil),
        ], multiple: false))
        guard case let .choice(_, multiple) = form.fields[2].kind else { return XCTFail("A choice") }
        XCTAssertTrue(multiple)
        XCTAssertEqual(form.fields[2].otherKey, "question_10_custom")
        XCTAssertNil(form.fields[1].otherKey)
    }

    /// One choice goes back as its value, several as a list, and an answer of the user's own
    /// beside the question; what was left empty is left out.
    func testAnswersGoBackAsClaudeCodeReadsThem() throws {
        let form = try XCTUnwrap(QuestionForm(Self.askUserQuestion))
        let content = form.content(for: [
            "question_0": .choices(["SQLite"]),
            "question_10": .choices(["Auth", "Admin"]),
            "question_10_custom": .text("  "),
            "question_2": .choices([]),
        ])
        XCTAssertEqual(content, ["question_0": .string("SQLite"), "question_10": .array([.string("Auth"), .string("Admin")])])
        let own = form.content(for: ["question_0_custom": .text(" MySQL "), "question_0": .choices(["SQLite"])])
        XCTAssertEqual(own["question_0_custom"], .string("MySQL"))
    }

    /// An MCP server's form: plain enums, text, numbers, a switch, and what is required.
    func testReadsAndAnswersOtherKindsOfField() throws {
        let request = ACPElicitationRequest(sessionId: "s", message: "Configure", requestedSchema: .object([
            "type": .string("object"), "required": .array([.string("name"), .string("port")]),
            "properties": .object([
                "colour": .object(["type": .string("string"), "enum": .array([.string("r"), .string("g")]), "enumNames": .array([.string("Red"), .string("Green")])]),
                "name": .object(["type": .string("string")]),
                "port": .object(["type": .string("integer")]),
                "ratio": .object(["type": .string("number")]),
                "verbose": .object(["type": .string("boolean")]),
                "blob": .object(["type": .string("object")]),
            ]),
        ]))
        let form = try XCTUnwrap(QuestionForm(request))
        XCTAssertEqual(form.fields.map(\.key), ["colour", "name", "port", "ratio", "verbose"], "A field no app can show is left out")
        XCTAssertEqual(form.fields[0].kind, .choice(options: [.init(value: "r", title: "Red", detail: nil, preview: nil),
                                                             .init(value: "g", title: "Green", detail: nil, preview: nil)], multiple: false))
        XCTAssertFalse(form.isComplete(["name": .text("box")]))
        let answers: [String: QuestionAnswer] = ["name": .text("box"), "port": .text(" 8080 "), "ratio": .text("0.5"), "verbose": .toggle(true)]
        XCTAssertTrue(form.isComplete(answers))
        XCTAssertEqual(form.content(for: answers), ["name": .string("box"), "port": .integer(8080), "ratio": .double(0.5), "verbose": .bool(true)])
        // No encoder can send NaN or infinity, and blank is no answer; neither completes the form.
        XCTAssertFalse(form.isComplete(answers.merging(["ratio": .text("nan")]) { $1 }))
        XCTAssertFalse(form.isComplete(answers.merging(["ratio": .text("inf")]) { $1 }))
        XCTAssertFalse(form.isComplete(answers.merging(["port": .text("1.0")]) { $1 }), "A whole number is asked for")
        XCTAssertFalse(form.isComplete(answers.merging(["name": .text("  \n ")]) { $1 }))
        XCTAssertTrue(form.isComplete(answers.merging(["ratio": .text(" ")]) { $1 }), "An optional number may be left empty")
        // A form may leave its mode out.
        let unmarked = try JSONDecoder().decode(ACPElicitationRequest.self, from: Data(#"{"sessionId":"s","message":"Pick","requestedSchema":{"type":"object","properties":{"a":{"type":"string"}}}}"#.utf8))
        XCTAssertEqual(unmarked.mode, "form")
        XCTAssertNotNil(QuestionForm(unmarked))
        XCTAssertNil(QuestionForm(ACPElicitationRequest(sessionId: "s", message: "Nothing", requestedSchema: .object(["properties": .object([:])]))))
        XCTAssertNil(QuestionForm(ACPElicitationRequest(sessionId: "s", mode: "url", message: "Open", requestedSchema: nil)))
    }

    /// Answering sends what was given, Skip declines, Cancel refuses, and only the question
    /// showing can be answered.
    @MainActor func testTheQueueAnswersSkipsAndCancels() async throws {
        let queue = QuestionQueue()
        let answered = Task { await queue.ask(Self.askUserQuestion) }
        let skipped = Task { await queue.ask(Self.askUserQuestion) }
        while queue.current == nil { await Task.yield() }
        let first = try XCTUnwrap(queue.current)
        queue.answer(id: UUID(), with: [:])
        XCTAssertEqual(queue.current?.id, first.id, "Only the question showing can be answered")
        queue.answer(id: first.id, with: ["question_0": .choices(["Postgres"])])
        let response = await answered.value
        XCTAssertEqual(response, ACPElicitationResponse(action: .accept, content: ["question_0": .string("Postgres")]))
        while queue.current == nil || queue.current?.id == first.id { await Task.yield() }
        queue.skip(id: try XCTUnwrap(queue.current).id)
        let skippedResponse = await skipped.value
        XCTAssertEqual(skippedResponse, ACPElicitationResponse(action: .decline))

        let cancelled = Task { await queue.ask(Self.askUserQuestion) }
        while queue.current == nil { await Task.yield() }
        queue.cancelAll()
        let cancelledResponse = await cancelled.value
        XCTAssertEqual(cancelledResponse, .cancelled)
        let unshowable = await queue.ask(ACPElicitationRequest(sessionId: "s", message: "Nothing", requestedSchema: .object([:])))
        XCTAssertEqual(unshowable, .cancelled, "A form with nothing to show is refused, so the agent goes on")
    }
}
