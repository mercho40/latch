import Foundation
import XCTest
@testable import LatchMacUI

final class ChatMessageTests: XCTestCase {
    func testMessageAPI() {
        let id = UUID()
        var message = ChatMessage(id: id, role: .assistant, text: "hello")
        message.text += "!"
        XCTAssertEqual(message, ChatMessage(id: id, role: .assistant, text: "hello!"))
        XCTAssertNotEqual(ChatMessage(role: .user, text: "x").id, ChatMessage(role: .user, text: "x").id)
    }

    func testStreamingStableIDsAndDistinctTurns() throws {
        var history = ChatHistory()
        history.appendUser("first")
        history.appendAssistant("Hello")
        let id = try XCTUnwrap(history.messages.last).id
        history.appendAssistant(" ")
        history.appendAssistant("world")
        XCTAssertEqual(history.messages.last?.id, id)
        XCTAssertEqual(history.messages.last?.text, "Hello world")
        history.appendUser("second")
        history.appendUser("third")
        history.appendAssistant("Again")
        XCTAssertEqual(history.messages.map(\.role), [.user, .assistant, .user, .user, .assistant])
        XCTAssertEqual(Set(history.messages.map(\.id)).count, 5)
        XCTAssertEqual(history.transcript, "You\nfirst\n\nAgent\nHello world\n\nYou\nsecond\n\nYou\nthird\n\nAgent\nAgain")
    }

    func testLeadingWhitespaceAndWhitespaceBetweenChunks() throws {
        var history = ChatHistory()
        history.appendAssistant("    ")
        history.appendAssistant("\t")
        history.appendAssistant("")
        XCTAssertTrue(history.messages.isEmpty)
        XCTAssertTrue(history.transcript.isEmpty)
        history.appendAssistant("code")
        let id = try XCTUnwrap(history.messages.first).id
        XCTAssertEqual(history.messages.first?.text, "    \tcode")
        XCTAssertTrue(history.pendingWhitespace.isEmpty)
        history.appendAssistant("\n    ")
        history.appendAssistant("more")
        XCTAssertEqual(history.messages, [ChatMessage(id: id, role: .assistant, text: "    \tcode\n    more")])
    }

    func testPendingWhitespaceDoesNotBleedAcrossTurnsRolesToolsOrReset() {
        var history = ChatHistory()
        history.appendAssistant("    ")
        history.appendUser("next turn")
        history.appendAssistant("answer")
        XCTAssertEqual(history.messages.map(\.text), ["next turn", "answer"])

        // Even an invisible role change interrupts the previous assistant message.
        history.appendUser("\t")
        history.appendAssistant("new answer")
        XCTAssertEqual(history.messages.map(\.text), ["next turn", "answer", "new answer"])
        history.appendUser("\n")
        history.appendAssistant("  ")
        history.updateTool(toolCallID: "read", title: "Read", status: "pending")
        XCTAssertTrue(history.pendingWhitespace.isEmpty)
        history.appendAssistant("done")
        XCTAssertEqual(history.messages.last?.text, "done")
        let doneID = history.messages.last?.id
        history.updateTool(toolCallID: "read", title: nil, status: "completed")
        history.appendAssistant("finished")
        XCTAssertEqual(history.messages.last?.text, "finished")
        XCTAssertNotEqual(history.messages.last?.id, doneID)

        history.appendUser("")
        history.appendAssistant("  ")
        history.appendUser("")
        history.appendAssistant("fresh")
        XCTAssertEqual(history.messages.last?.text, "fresh")
        history.appendUser("")
        history.appendAssistant("  ")
        history.reset()
        XCTAssertTrue(history.pendingWhitespace.isEmpty)
        history.appendAssistant("reset")
        XCTAssertEqual(history.messages.map(\.text), ["reset"])
    }

    func testPendingWhitespaceSharesTotalTextBound() {
        var history = ChatHistory()
        history.appendUser(String(repeating: "u", count: 100_000))
        history.appendAssistant(String(repeating: " ", count: 90_000))
        XCTAssertEqual(history.messages.count, 1)
        XCTAssertEqual(history.pendingWhitespace.count, 90_000)
        for _ in 0..<3 {
            history.appendAssistant(String(repeating: " ", count: 90_000))
            XCTAssertLessThanOrEqual(
                history.messages.reduce(history.pendingWhitespace.count) { $0 + $1.text.count },
                ChatHistory.maximumTextCount
            )
        }
        XCTAssertTrue(history.messages.isEmpty)
        XCTAssertEqual(history.pendingWhitespace.count, ChatHistory.maximumTextCount)
        history.appendAssistant("code")
        XCTAssertTrue(history.pendingWhitespace.isEmpty)
        XCTAssertEqual(history.messages.count, 1)
        XCTAssertEqual(history.messages.first?.text, String(repeating: " ", count: 199_996) + "code")
    }

    func testToolUpdatesCoalesceAndPreserveTitleAndStatus() throws {
        var history = ChatHistory()
        history.updateTool(toolCallID: "read-1", title: "Read file", status: "pending")
        let id = try XCTUnwrap(history.messages.first).id
        history.appendAssistant("Reading")
        history.updateTool(toolCallID: "read-1", title: nil, status: "completed")
        XCTAssertEqual(history.messages.count, 2)
        XCTAssertEqual(history.messages[0], ChatMessage(id: id, role: .tool, text: "Read file · completed"))
        history.updateTool(toolCallID: "read-1", title: "Read another file", status: nil)
        XCTAssertEqual(history.messages[0].text, "Read another file · completed")
        history.appendAssistant("Done")
        XCTAssertNotEqual(history.messages[1].id, history.messages[2].id)
        history.updateTool(toolCallID: "read-2", title: nil, status: nil)
        XCTAssertEqual(history.messages.last?.text, "read-2 · updated")
    }

    func testCountBoundAndEvictedToolMetadata() throws {
        var history = ChatHistory()
        history.updateTool(toolCallID: "old", title: "Old title", status: "pending")
        let oldID = try XCTUnwrap(history.messages.first).id
        for index in 0..<450 { history.appendUser("\(index)") }
        XCTAssertEqual(history.messages.count, 400)
        XCTAssertEqual(history.messages.first?.text, "50")
        history.updateTool(toolCallID: "old", title: nil, status: nil)
        XCTAssertEqual(history.messages.count, 400)
        XCTAssertNotEqual(history.messages.last?.id, oldID)
        XCTAssertEqual(history.messages.last?.text, "old · updated")
    }

    func testTextBoundTrimsOldestAndSingleOversizedMessage() throws {
        var history = ChatHistory()
        history.appendUser(String(repeating: "a", count: 100_000))
        history.appendAssistant(String(repeating: "b", count: 100_001))
        XCTAssertEqual(history.messages.count, 1)
        let id = try XCTUnwrap(history.messages.first).id
        history.appendAssistant(String(repeating: "c", count: 200_001))
        XCTAssertEqual(history.messages.first?.id, id)
        XCTAssertEqual(history.messages.first?.text, String(repeating: "c", count: 200_000))
        history.updateTool(toolCallID: "big", title: String(repeating: "t", count: 210_000), status: "completed")
        XCTAssertLessThanOrEqual(history.messages.reduce(0) { $0 + $1.text.count }, 200_000)
        XCTAssertTrue(history.messages.last?.text.hasSuffix(" · completed") == true)
        history.reset()
        XCTAssertTrue(history.messages.isEmpty)
        XCTAssertTrue(history.transcript.isEmpty)
        history.updateTool(toolCallID: "big", title: nil, status: nil)
        XCTAssertEqual(history.messages.first?.text, "big · updated")
    }

    @MainActor func testStderrDoesNotEnterHistorySplitChunksOrEvictMessagesAndLifecycleRetention() async throws {
        // Extend the existing owned-process fixture without modifying it.
        let extraEvents = #"""
          sleep 0.1
          printf 'stderr sentinel\n' >&2
          /usr/bin/awk 'BEGIN { for (i = 0; i < 250001; i++) printf "x"; printf "\n" }' >&2
          sleep 0.1
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":" more"}}}}'
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"read-1","title":"Read file","status":"pending"}}}'
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"read-1","status":"completed"}}}'
        """#
        let lines = SmokeAgent.script.components(separatedBy: "\n")
        var extended = lines
        let chunkIndex = try XCTUnwrap(lines.firstIndex { $0.contains("agent_message_chunk") })
        extended.insert(extraEvents, at: chunkIndex + 1)
        // Startup stderr must not create chat/Copy Conversation content either.
        let script = "printf 'startup stderr sentinel\\n' >&2\n" + extended.joined(separator: "\n")
        let command = "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let model = SessionModel()
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.transcript.isEmpty)
        var firstAssistantID: UUID?
        model.onChange = {
            if firstAssistantID == nil {
                firstAssistantID = model.messages.first { $0.role == .assistant }?.id
            }
        }
        // Leave little history headroom: even a small stderr entry would evict this turn.
        let userText = String(repeating: "u", count: ChatHistory.maximumTextCount - 100)
        let prompt = Task { await model.send(userText) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.messages.contains(where: { $0.text == "Read file · completed" }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(model.messages.map(\.text), [userText, "working more", "Read file · completed"])
        XCTAssertNotNil(firstAssistantID)
        XCTAssertEqual(model.messages.first { $0.role == .assistant }?.id, firstAssistantID)
        // transcript is the Copy Conversation source; no pasteboard mutation is needed.
        XCTAssertEqual(model.transcript, "You\n\(userText)\n\nAgent\nworking more\n\nTool\nRead file · completed")
        XCTAssertNil(model.errorMessage)
        await model.cancel()
        let finished = expectation(description: "Cancelled prompt returns")
        let waiter = Task { await prompt.value; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        let conversation = model.messages
        let transcript = model.transcript
        model.onChange = nil
        await model.disconnect()
        XCTAssertEqual(model.messages, conversation)
        XCTAssertEqual(model.transcript, transcript)
        // Intentionally start an empty context; this fixture cannot resume (see SessionResumeTests).
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"), startNewSession: true)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.transcript.isEmpty)
        await model.disconnect()
        waiter.cancel()
        prompt.cancel()
    }
}
