import Foundation
import XCTest
@testable import LatchMacUI

final class ChatHistoryRegressionTests: XCTestCase {
    private struct Comparison {
        var actual = ChatHistory()
        var reference = ReferenceHistory()
        var identities: [UUID: UUID] = [:]
        var reverseIdentities: [UUID: UUID] = [:]

        mutating func check(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(actual.messages.map(\.role), reference.messages.map(\.role), file: file, line: line)
            XCTAssertEqual(actual.messages.map(\.text), reference.messages.map(\.text), file: file, line: line)
            XCTAssertEqual(actual.pendingWhitespace, reference.pendingWhitespace, file: file, line: line)
            XCTAssertEqual(actual.transcript, reference.transcript, file: file, line: line)
            for (a, r) in zip(actual.messages, reference.messages) {
                XCTAssertEqual(identities[a.id, default: r.id], r.id, file: file, line: line)
                XCTAssertEqual(reverseIdentities[r.id, default: a.id], a.id, file: file, line: line)
                identities[a.id] = r.id
                reverseIdentities[r.id] = a.id
            }
        }

        mutating func assistant(_ text: String) {
            actual.appendAssistant(text); reference.appendAssistant(text); check()
        }
        mutating func user(_ text: String) {
            actual.appendUser(text); reference.appendUser(text); check()
        }
        mutating func tool(_ id: String, _ title: String? = nil, _ status: String? = nil) {
            actual.updateTool(toolCallID: id, title: title, status: status)
            reference.updateTool(toolCallID: id, title: title, status: status)
            check()
        }
        mutating func restore(_ messages: [ChatMessage]) {
            actual.restore(messages); reference.restore(messages)
            // Both restore the same archive IDs, replacing the oracle's generated IDs.
            identities.removeAll(); reverseIdentities.removeAll()
            XCTAssertEqual(actual.messages, reference.messages)
            check()
        }
    }

    func testUnicodeScalarChunksAtTextBoundAgainstReference() {
        let sequences = [
            "e\u{301}\u{308}", "\r\n", "👩🏽‍💻", "👨‍👩‍👧‍👦",
            "🇦🇧🇨🇩🇪🇫🇬", "\u{600}a\u{301}", "각", "क्‍ष",
            "🏴\u{E0067}\u{E0062}\u{E007F}", "a" + String(repeating: "\u{301}", count: 40)
        ]
        for sequence in sequences {
            var pair = Comparison()
            pair.user("old")
            pair.assistant(String(repeating: "x", count: 199_994))
            for _ in 0..<3 {
                for scalar in sequence.unicodeScalars { pair.assistant(String(scalar)) }
            }
            pair.assistant("end")
            // A later bounds decision exposes any drift in cached counts.
            pair.user("next")
            pair.assistant(String(repeating: "z", count: 199_995))
        }
    }

    func testPendingWhitespaceTruncationRestorationAndToolEvictionAgainstReference() {
        var pair = Comparison()
        pair.user(String(repeating: "u", count: 100_000))
        pair.assistant(String(repeating: "\r", count: 199_999))
        pair.assistant("\n")
        pair.assistant("\r")
        pair.assistant("\n")
        pair.assistant("content")
        pair.assistant(String(repeating: " ", count: 200_001))
        pair.assistant("after whitespace-only suffix")
        pair.tool("old", "Original", "pending")
        for i in 0..<405 { pair.user("row \(i)") }
        pair.tool("old")
        pair.tool("large", "Title", "done" + String(repeating: " ", count: 200_010))
        pair.tool("large")
        pair.restore((0..<405).map {
            ChatMessage(role: .assistant, text: $0.isMultiple(of: 3) ? " \n" : "row \($0)")
        })
        pair.assistant("new stream")
        pair.restore([
            ChatMessage(role: .tool, text: "archived · pending"),
            ChatMessage(role: .user, text: String(repeating: " ", count: 200_001))
        ])
        pair.tool("old")
        pair.restore([ChatMessage(role: .assistant, text: "restored")])
        pair.assistant("not merged")
        pair.restore([])
        pair.tool("growing", "Original", "pending")
        pair.user(String(repeating: "u", count: 100_000))
        // Growing the oldest tool in place evicts that very tool and its metadata.
        pair.tool("growing", String(repeating: "t", count: 150_000), "completed")
        pair.tool("growing")
        pair.tool("growing", "Small", "done")
        pair.assistant(String(repeating: "a", count: 199_980))
    }

    func testDeterministicMixedOperationsAndValueCopiesAgainstReference() {
        var pair = Comparison()
        var seed: UInt64 = 0x123456789abcdef
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(bound))
        }
        let chunks = ["", " ", "\r", "\n", "hello", "\u{301}", "👩", "‍", "💻", "🇦", "ᄀ", "ᅡ", "\u{600}"]
        for step in 0..<1_200 {
            switch next(16) {
            case 0...7: pair.assistant(chunks[next(chunks.count)])
            case 8...10: pair.user(chunks[next(chunks.count)])
            case 11...12: pair.tool("tool-\(next(7))", next(2) == 0 ? nil : chunks[next(chunks.count)], "status-\(next(4))")
            case 13: pair.assistant(String(repeating: chunks[next(chunks.count)], count: 20_001))
            case 14:
                let archived = pair.actual.messages
                pair.restore(archived)
            default:
                var copy = pair
                let snapshot = pair.actual.messages
                copy.assistant("copy-only")
                copy.tool("copy")
                XCTAssertEqual(pair.actual.messages, snapshot)
                pair.check()
            }
            if step.isMultiple(of: 199) {
                pair.actual.reset(); pair.reference.reset(); pair.check()
            }
        }
    }

    func testLongTranscriptStreamingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["LATCH_HISTORY_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LATCH_HISTORY_BENCHMARK=1 to run old/reference versus incremental timing")
        }
        let archived = (0..<350).map { _ in ChatMessage(role: .user, text: String(repeating: "x", count: 400)) }
        let chunks = (0..<4_000).map { $0.isMultiple(of: 5) ? "👩🏽‍💻" : "token " }
        for snapshots in [false, true] {
            var actual = ChatHistory()
            var reference = ReferenceHistory()
            actual.restore(archived); reference.restore(archived)
            actual.appendAssistant(String(repeating: "a", count: 30_000))
            reference.appendAssistant(String(repeating: "a", count: 30_000))
            let clock = ContinuousClock()
            let oldTime = clock.measure {
                for chunk in chunks {
                    if snapshots {
                        let snapshot = reference.messages
                        reference.appendAssistant(chunk)
                        withExtendedLifetime(snapshot) {}
                    } else { reference.appendAssistant(chunk) }
                }
            }
            let newTime = clock.measure {
                for chunk in chunks {
                    if snapshots {
                        let snapshot = actual.messages
                        actual.appendAssistant(chunk)
                        withExtendedLifetime(snapshot) {}
                    } else { actual.appendAssistant(chunk) }
                }
            }
            XCTAssertEqual(actual.messages.map(\.text), reference.messages.map(\.text))
            XCTAssertEqual(actual.messages.map(\.role), reference.messages.map(\.role))
            XCTAssertEqual(actual.pendingWhitespace, reference.pendingWhitespace)
            print("HISTORY_BENCHMARK snapshots=\(snapshots) retained=\(actual.messages.count) chunks=\(chunks.count) old=\(oldTime) incremental=\(newTime)")
        }
    }
}

// Frozen pre-incremental implementation: deliberately recounts the entire history.
private struct ReferenceHistory: Sendable {
    private(set) var messages: [ChatMessage] = []
    static let maximumMessageCount = 400
    static let maximumTextCount = 200_000

    private struct Tool: Sendable {
        let messageID: UUID
        var title: String
        var status: String
    }
    private var tools: [String: Tool] = [:]
    private var adjacentRole: ChatMessage.Role?
    private var adjacentMessageID: UUID?
    private(set) var pendingWhitespace = ""

    var transcript: String {
        messages.map { message in
            let label: String
            switch message.role {
            case .user: label = "You"
            case .assistant: label = "Agent"
            case .tool: label = "Tool"
            }
            return "\(label)\n\(message.text)"
        }.joined(separator: "\n\n")
    }

    mutating func reset() {
        self = ReferenceHistory()
    }

    mutating func restore(_ messages: [ChatMessage]) {
        reset()
        self.messages = messages
        enforceBounds()
    }

    mutating func appendUser(_ text: String) {
        append(text, role: .user, newMessage: true)
    }

    mutating func appendAssistant(_ text: String) {
        append(text, role: .assistant)
    }

    mutating func updateTool(toolCallID: String, title: String?, status: String?) {
        var tool = tools[toolCallID] ?? Tool(messageID: UUID(), title: toolCallID, status: "updated")
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tool.title = String(title.suffix(Self.maximumTextCount))
        }
        if let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tool.status = String(status.suffix(Self.maximumTextCount))
        }
        let text = "\(tool.title) · \(tool.status)"
        if let index = messages.firstIndex(where: { $0.id == tool.messageID }) {
            messages[index].text = text
        } else {
            messages.append(ChatMessage(id: tool.messageID, role: .tool, text: text))
        }
        tools[toolCallID] = tool
        // Even an in-place tool update interrupts adjacent assistant chunks.
        adjacentRole = .tool
        adjacentMessageID = nil
        pendingWhitespace = ""
        enforceBounds()
    }

    private mutating func append(_ text: String, role: ChatMessage.Role, newMessage: Bool = false) {
        if newMessage || adjacentRole != role {
            pendingWhitespace = ""
            adjacentMessageID = nil
        }
        adjacentRole = role
        guard !text.isEmpty else { return }
        if let adjacentMessageID, messages.last?.id == adjacentMessageID {
            messages[messages.count - 1].text += text
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A stream may begin with indentation. Retain it invisibly until content
            // arrives, within the same total text budget as visible messages.
            if !newMessage {
                pendingWhitespace = String((pendingWhitespace + text).suffix(Self.maximumTextCount))
            }
        } else {
            let message = ChatMessage(role: role, text: pendingWhitespace + text)
            pendingWhitespace = ""
            messages.append(message)
            adjacentMessageID = message.id
        }
        enforceBounds()
    }

    private mutating func enforceBounds() {
        if messages.count > Self.maximumMessageCount {
            messages.removeFirst(messages.count - Self.maximumMessageCount)
        }
        var count = messages.reduce(pendingWhitespace.count) { $0 + $1.text.count }
        let minimumVisibleCount = pendingWhitespace.isEmpty ? 1 : 0
        while count > Self.maximumTextCount, messages.count > minimumVisibleCount {
            count -= messages.removeFirst().text.count
        }
        if count > Self.maximumTextCount {
            messages[0].text = String(messages[0].text.suffix(Self.maximumTextCount))
        }
        messages.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let retainedIDs = Set(messages.map(\.id))
        tools = tools.filter { retainedIDs.contains($0.value.messageID) }
    }
}
