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
        history.appendDiagnostics("\t")
        history.appendAssistant("new answer")
        XCTAssertEqual(history.messages.map(\.text), ["next turn", "answer", "new answer"])
        history.appendDiagnostics("\n")
        history.appendAssistant("  ")
        history.appendDiagnostics("warning")
        XCTAssertEqual(history.messages.last?.text, "warning")
        history.appendAssistant("  ")
        history.updateTool(toolCallID: "read", title: "Read", status: "pending")
        history.appendAssistant("done")
        XCTAssertEqual(history.messages.last?.text, "done")
        history.appendDiagnostics("\t")
        history.updateTool(toolCallID: "read", title: nil, status: "completed")
        history.appendDiagnostics("finished")
        XCTAssertEqual(history.messages.last?.text, "finished")

        history.appendAssistant("  ")
        history.appendUser("")
        history.appendAssistant("fresh")
        XCTAssertEqual(history.messages.last?.text, "fresh")
        history.appendDiagnostics("  ")
        history.reset()
        XCTAssertTrue(history.pendingWhitespace.isEmpty)
        history.appendDiagnostics("reset")
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

    func testDiagnosticsAreSeparateAndEmptyRowsIgnored() throws {
        var history = ChatHistory()
        history.appendUser("")
        history.appendAssistant(" \n")
        history.appendDiagnostics("")
        XCTAssertTrue(history.messages.isEmpty)
        history.appendAssistant("answer")
        history.appendDiagnostics("warning")
        let id = try XCTUnwrap(history.messages.last).id
        history.appendDiagnostics(" details")
        history.appendAssistant("more")
        XCTAssertEqual(history.messages.map(\.role), [.assistant, .diagnostics, .assistant])
        XCTAssertEqual(history.messages[1].id, id)
        XCTAssertEqual(history.messages[1].text, "warning details")
        XCTAssertTrue(history.transcript.contains("Agent diagnostics\nwarning details"))
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

    @MainActor func testACPEventsAndConnectResetDisconnectRetention() async throws {
        // Extend the existing owned-process fixture without modifying it.
        let extraEvents = #"""
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":" more"}}}}'
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"read-1","title":"Read file","status":"pending"}}}'
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"read-1","status":"completed"}}}'
          printf 'diagnostic sentinel' >&2
        """#
        let lines = SmokeAgent.script.components(separatedBy: "\n")
        var extended = lines
        let chunkIndex = try XCTUnwrap(lines.firstIndex { $0.contains("agent_message_chunk") })
        extended.insert(extraEvents, at: chunkIndex + 1)
        let command = "/bin/sh -c '" + extended.joined(separator: "\n").replacingOccurrences(of: "'", with: "'\\''") + "'"
        let model = SessionModel()
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .ready)
        var firstAssistantID: UUID?
        model.onChange = {
            if firstAssistantID == nil {
                firstAssistantID = model.messages.first { $0.role == .assistant }?.id
            }
        }
        let prompt = Task { await model.send("Go") }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(model.messages.contains { $0.text == "Read file · completed" }
                && model.messages.contains { $0.role == .diagnostics && $0.text.contains("diagnostic sentinel") }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.messages.first?.role, .user)
        XCTAssertEqual(model.messages.first?.text, "Go")
        // stderr and protocol events have independent arrival order.
        XCTAssertEqual(model.messages.filter { $0.role == .assistant }.map(\.text).joined(), "working more")
        XCTAssertEqual(model.messages.first { $0.role == .assistant }?.id, firstAssistantID)
        XCTAssertEqual(model.messages.filter { $0.role == .tool }.map(\.text), ["Read file · completed"])
        XCTAssertTrue(model.messages.contains { $0.role == .diagnostics && $0.text.contains("diagnostic sentinel") })
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
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.transcript.isEmpty)
        await model.disconnect()
        waiter.cancel()
        prompt.cancel()
    }
}
