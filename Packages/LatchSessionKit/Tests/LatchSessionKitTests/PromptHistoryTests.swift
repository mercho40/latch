import XCTest
@testable import LatchSessionKit

final class PromptHistoryTests: XCTestCase {
    private let prompts = ["first", "second", "third"]

    func testThePromptsAreTheUsersOwnInOrderWithoutRepeats() {
        let messages = [
            ChatMessage(role: .user, text: " first "),
            ChatMessage(role: .assistant, text: "answer"),
            ChatMessage(role: .user, text: "first"),
            ChatMessage(role: .user, text: ""),
            ChatMessage(role: .user, text: "a subagent's task", parentID: UUID()),
            ChatMessage(role: .tool, text: "ran"),
            ChatMessage(role: .user, text: "second"),
            ChatMessage(role: .user, text: "first"),
        ]
        XCTAssertEqual(PromptHistory.prompts(in: messages), ["first", "second", "first"])
    }

    func testUpWalksBackFromAnEmptyComposerAndDownWalksForwardToIt() throws {
        var step = try XCTUnwrap(PromptHistory.older(prompts, composer: "", recall: nil))
        XCTAssertEqual(step.text, "third")
        step = try XCTUnwrap(PromptHistory.older(prompts, composer: step.text, recall: step.recall))
        XCTAssertEqual(step.text, "second")
        step = try XCTUnwrap(PromptHistory.older(prompts, composer: step.text, recall: step.recall))
        XCTAssertEqual(step.text, "first")
        XCTAssertNil(PromptHistory.older(prompts, composer: step.text, recall: step.recall), "Nothing older")
        step = try XCTUnwrap(PromptHistory.newer(prompts, composer: step.text, recall: step.recall))
        XCTAssertEqual(step.text, "second")
        step = try XCTUnwrap(PromptHistory.newer(prompts, composer: step.text, recall: step.recall))
        XCTAssertEqual(step.text, "third")
        step = try XCTUnwrap(PromptHistory.newer(prompts, composer: step.text, recall: step.recall))
        XCTAssertEqual(step, PromptHistory.Step(text: "", recall: nil), "Past the newest, an empty composer")
        XCTAssertNil(PromptHistory.newer(prompts, composer: "", recall: nil))
    }

    func testADraftOrAnEditEndsTheWalk() throws {
        XCTAssertNil(PromptHistory.older(prompts, composer: "a draft", recall: nil), "Up moves through a draft")
        XCTAssertNil(PromptHistory.older([], composer: "", recall: nil))
        let step = try XCTUnwrap(PromptHistory.older(prompts, composer: "", recall: nil))
        XCTAssertNil(PromptHistory.older(prompts, composer: "third, edited", recall: step.recall))
        XCTAssertNil(PromptHistory.newer(prompts, composer: "third, edited", recall: step.recall))
        // The conversation moved on under the walk: it starts again rather than step from a stale place.
        XCTAssertNil(PromptHistory.newer(["other"], composer: "third", recall: step.recall))
    }
}
