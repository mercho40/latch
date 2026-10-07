import Foundation
import LatchACP
import LatchRemoteProtocol
import XCTest
@testable import LatchAgentServer

final class RemoteHistoryCondenserTests: XCTestCase {
    func testAMessagesChunksJoinAndToolUpdatesFoldIntoTheCall() throws {
        let output: ACPJSONValue = .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("42 lines")])])])
        let ended = LatchRemoteEvent.turnEnded(turnID: UUID(), stopReason: "end_turn", error: nil)
        let block = events([
            .sessionUpdate(notification: chunk("Let me ")),
            .sessionUpdate(notification: chunk("look.")),
            .sessionUpdate(notification: tool("tool_call", ["title": .string("Read"), "status": .string("pending"), "kind": .string("read")])),
            .sessionUpdate(notification: tool("tool_call_update", ["status": .string("in_progress"), "title": .string(" ")])),
            .sessionUpdate(notification: chunk("Found ")),
            .sessionUpdate(notification: tool("tool_call_update", ["status": .string("completed"), "content": output])),
            .sessionUpdate(notification: chunk("it.")),
            ended,
        ])
        let condensed = RemoteHistoryCondenser.condense(block, maxEncodedEventBytes: 1 << 20)

        XCTAssertEqual(condensed.map(\.sequence), [1, 3, 5, 6, 7, 8])
        XCTAssertEqual(try decode(condensed), [
            .sessionUpdate(notification: chunk("Let me look.")),
            .sessionUpdate(notification: tool("tool_call", [
                "title": .string("Read"), "status": .string("completed"), "kind": .string("read"), "content": output,
            ])),
            .sessionUpdate(notification: chunk("Found ")),
            // The folded update still parts the two chunks, as it did.
            .sessionUpdate(notification: tool("tool_call_update", [:])),
            .sessionUpdate(notification: chunk("it.")),
            ended,
        ])
        // What is not condensed goes out as it was journaled.
        XCTAssertEqual(condensed.last?.encodedEvent, block.last?.encodedEvent)
        XCTAssertEqual(condensed[2].encodedEvent, block[4].encodedEvent)
    }

    func testTheLastEventCarriesTheBlocksLastSequence() throws {
        let block = events([
            .sessionUpdate(notification: tool("tool_call", ["title": .string("Edit")])),
            .sessionUpdate(notification: tool("tool_call_update", ["status": .string("completed")])),
        ])
        let condensed = RemoteHistoryCondenser.condense(block, maxEncodedEventBytes: 1 << 20)
        XCTAssertEqual(condensed.map(\.sequence), [2])
        XCTAssertEqual(condensed.map(\.order), [100])
        XCTAssertEqual(RemoteHistoryCondenser.condense([], maxEncodedEventBytes: 1 << 20), [])
    }

    func testMetaMergesAndBlankFieldsChangeNothing() {
        var call: [String: ACPJSONValue] = [
            "title": .string("Run tests"), "rawInput": .object(["command": .string("swift test")]),
            "_meta": .object(["claudeCode": .object(["toolName": .string("Bash")])]),
        ]
        RemoteHistoryCondenser.fold([
            "sessionUpdate": .string("tool_call_update"), "toolCallId": .string("call"),
            "title": .string(""), "status": .null, "rawOutput": .string("ok"),
            "_meta": .object(["claudeCode": .object(["parentToolUseId": .string("agent")])]),
        ], into: &call)
        XCTAssertEqual(call, [
            "title": .string("Run tests"), "rawInput": .object(["command": .string("swift test")]), "rawOutput": .string("ok"),
            "_meta": .object(["claudeCode": .object(["toolName": .string("Bash"), "parentToolUseId": .string("agent")])]),
        ])
    }

    func testOnlyLikeChunksSideBySideJoin() throws {
        let plan = ACPSessionNotification(sessionId: "s", update: .object(["sessionUpdate": .string("plan"), "entries": .array([])]))
        let block = events([
            .sessionUpdate(notification: chunk("history ", kind: "user_message_chunk"), replay: true),
            .sessionUpdate(notification: chunk("again", kind: "user_message_chunk"), replay: true),
            .sessionUpdate(notification: chunk("replayed ", kind: "agent_message_chunk"), replay: true),
            .sessionUpdate(notification: chunk("again"), replay: true),
            .sessionUpdate(notification: chunk(" live")),
            .sessionUpdate(notification: chunk(" thinking", kind: "agent_thought_chunk")),
            .sessionUpdate(notification: plan),
            .sessionUpdate(notification: chunk(" more thinking", kind: "agent_thought_chunk")),
            .sessionUpdate(notification: chunk(" other message", kind: "agent_thought_chunk", messageID: "m2")),
        ])
        XCTAssertEqual(try decode(RemoteHistoryCondenser.condense(block, maxEncodedEventBytes: 1 << 20)), [
            // The user's own words stay as the agent replayed them.
            .sessionUpdate(notification: chunk("history ", kind: "user_message_chunk"), replay: true),
            .sessionUpdate(notification: chunk("again", kind: "user_message_chunk"), replay: true),
            .sessionUpdate(notification: chunk("replayed again"), replay: true),
            .sessionUpdate(notification: chunk(" live")),
            .sessionUpdate(notification: chunk(" thinking", kind: "agent_thought_chunk")),
            .sessionUpdate(notification: plan),
            .sessionUpdate(notification: chunk(" more thinking", kind: "agent_thought_chunk")),
            .sessionUpdate(notification: chunk(" other message", kind: "agent_thought_chunk", messageID: "m2")),
        ])
    }

    func testACallTooLargeToGrowStartsAgain() throws {
        let title = "Write Sources/LatchAgentServer/RemoteHistoryCondenser.swift"
        let big = String(repeating: "x", count: 600)
        let block = events([
            .sessionUpdate(notification: tool("tool_call", ["title": .string(title)])),
            .sessionUpdate(notification: tool("tool_call_update", ["rawInput": .string(big)])),
            .sessionUpdate(notification: tool("tool_call_update", ["status": .string("completed")])),
        ])
        // Room for the big update and the last, but not for the call and the big update.
        let limit = block[0].encodedEvent.count + block[1].encodedEvent.count - 1
        XCTAssertLessThanOrEqual(block[1].encodedEvent.count + block[2].encodedEvent.count, limit)
        let condensed = RemoteHistoryCondenser.condense(block, maxEncodedEventBytes: limit)
        XCTAssertEqual(try decode(condensed), [
            .sessionUpdate(notification: tool("tool_call", ["title": .string(title)])),
            .sessionUpdate(notification: tool("tool_call_update", ["rawInput": .string(big), "status": .string("completed")])),
        ])
        XCTAssertTrue(condensed.allSatisfy { $0.encodedEvent.count <= limit })
    }

    // MARK: Helpers

    private func chunk(_ text: String, kind: String = "agent_message_chunk", messageID: String = "m1") -> ACPSessionNotification {
        ACPSessionNotification(sessionId: "s", update: .object([
            "sessionUpdate": .string(kind), "messageId": .string(messageID),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ]))
    }

    private func tool(_ kind: String, _ fields: [String: ACPJSONValue]) -> ACPSessionNotification {
        var update = fields
        update["sessionUpdate"] = .string(kind)
        update["toolCallId"] = .string("call-1")
        return ACPSessionNotification(sessionId: "s", update: .object(update))
    }

    /// Journaled events with sequences from 1 and publish orders from 100.
    private func events(_ events: [LatchRemoteEvent]) -> [RemoteHistoryCondenser.Event] {
        events.enumerated().map { index, event in
            RemoteHistoryCondenser.Event(sequence: UInt64(index + 1), encodedEvent: try! LatchRemoteCoding.encodeEvent(event),
                                         order: UInt64(index + 100))
        }
    }

    private func decode(_ events: [RemoteHistoryCondenser.Event]) throws -> [LatchRemoteEvent] {
        try events.map { try LatchRemoteCoding.makeDecoder().decode(LatchRemoteEvent.self, from: $0.encodedEvent) }
    }
}
