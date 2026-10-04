import Foundation
import Synchronization
import XCTest
@testable import LatchACP

final class ACPIngressSequenceTests: XCTestCase {
    func testSessionSnapshotsAndUpdatesUseWireOrderAndIgnoreForgedMetadata() async throws {
        let incoming = AsyncStream<Data>.makeStream()
        let connection = ACPJSONRPCConnection(incoming: incoming.stream) { data in
            let message = try JSONDecoder().decode(ACPJSONValue.self, from: data)
            guard case let .object(request) = message, let id = request["id"] else { return }
            let frames: [ACPJSONValue]
            switch request["method"] {
            case .string("initialize"):
                frames = [Self.reply(id, .object([
                    "protocolVersion": .integer(1),
                    "agentCapabilities": .object(["loadSession": .bool(false)]),
                ]))]
            case .string("session/new"):
                frames = [
                    Self.reply(id, .object([
                        "sessionId": .string("session-1"),
                        "configOptions": .array([]),
                        "localSequence": .object(["forged": .bool(true)]),
                    ])),
                    Self.update(.integer(999_999)),
                ]
            case .string("session/set_config_option"):
                frames = [
                    Self.update(.string("not a sequence")),
                    Self.reply(id, .object([
                        "configOptions": .array([.object(["currentValue": .string("high")])]),
                        "localSequence": .string("forged"),
                    ])),
                    Self.update(.integer(0)),
                ]
            case .string("session/set_model"):
                frames = [
                    Self.reply(id, .object(["localSequence": .integer(999_999)])),
                    Self.update(.null),
                ]
            default:
                return
            }
            // Multiple frames in one chunk must still get distinct ingress sequences.
            incoming.continuation.yield(try Self.encodeFrames(frames))
        }
        let client = ACPClient(connection: connection)
        let runTask = Task { try await connection.run() }
        try await client.initialize(clientInfo: ACPImplementation(name: "test", version: "1"))
        let session = try await client.newSession(cwd: "/tmp")
        let config = try await client.setSessionConfigOption(configID: "effort", value: "high")
        let modelSequence = try await client.setSessionModel(modelID: "model-b")
        // Deliberately consume notifications only after all responses have completed.
        incoming.continuation.finish()
        _ = try await runTask.value
        var updates: [ACPSessionNotification] = []
        for await update in client.sessionUpdates { updates.append(update) }
        XCTAssertEqual(session.localSequence, 2)
        XCTAssertEqual(config.localSequence, 5)
        XCTAssertEqual(modelSequence, 7)
        XCTAssertEqual(updates.map(\.localSequence), [3, 4, 6, 8])
        XCTAssertEqual(config.configOptions, [.object(["currentValue": .string("high")])])
        XCTAssertTrue(updates.allSatisfy { $0.sessionId == "session-1" })
    }

    func testGenericSequenceCountsEveryFrameAndOldRequestStillWorks() async throws {
        let incoming = AsyncStream<Data>.makeStream()
        let connection = ACPJSONRPCConnection(incoming: incoming.stream) { data in
            let message = try JSONDecoder().decode(ACPJSONValue.self, from: data)
            guard case let .object(request) = message,
                  request["method"] == .string("test"), let id = request["id"] else { return }
            incoming.continuation.yield(try Self.encodeFrames([
                // Unmatched responses and incoming requests also occupy ingress positions.
                Self.reply(.integer(999), .null),
                .object(["jsonrpc": .string("2.0"), "id": id, "method": .string("ping")]),
                Self.update(.integer(900)),
                Self.reply(id, .string("ok")),
                Self.update(.integer(1)),
            ]))
        }
        let runTask = Task { try await connection.run() }
        let result = try await connection.requestWithSequence("test", as: String.self)
        XCTAssertEqual(result.response, "ok")
        XCTAssertEqual(result.sequence, 4)
        XCTAssertEqual(result.notifiedThrough, 3)
        let oldResult: String = try await connection.request("test")
        XCTAssertEqual(oldResult, "ok")
        incoming.continuation.finish()
        _ = try await runTask.value
        var sequences: [UInt64] = []
        for await notification in connection.notifications { sequences.append(notification.sequence) }
        XCTAssertEqual(sequences, [3, 5, 8, 10])
        XCTAssertEqual(ACPJSONRPCNotification(method: "manual").sequence, 0)
    }

    /// A prompt's reply names the last update before it, past a notification of another method
    /// and one that does not decode, and never one after it or a value the agent forged.
    func testAPromptSaysWhereItsUpdatesEnd() async throws {
        let incoming = AsyncStream<Data>.makeStream()
        let prompts = Mutex(0)
        let connection = ACPJSONRPCConnection(incoming: incoming.stream) { data in
            let message = try JSONDecoder().decode(ACPJSONValue.self, from: data)
            guard case let .object(request) = message, let id = request["id"] else { return }
            let frames: [ACPJSONValue]
            switch request["method"] {
            case .string("initialize"):
                frames = [Self.reply(id, .object(["protocolVersion": .integer(1), "agentCapabilities": .object([:])]))]
            case .string("session/new"):
                frames = [Self.reply(id, .object(["sessionId": .string("session-1")]))]
            case .string("session/prompt") where prompts.withLock { $0 += 1; return $0 } == 1:
                frames = [
                    Self.update(.null),
                    .object(["jsonrpc": .string("2.0"), "method": .string("_vendor/note"), "params": .object([:])]),
                    .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object(["update": .null])]),
                    Self.reply(id, .object(["stopReason": .string("end_turn"), "updatesThrough": .integer(99)])),
                    Self.update(.null),
                ]
            case .string("session/prompt"):
                frames = [Self.reply(id, .object(["stopReason": .string("end_turn")]))]
            default:
                return
            }
            incoming.continuation.yield(try Self.encodeFrames(frames))
        }
        let client = ACPClient(connection: connection)
        let runTask = Task { try await connection.run() }
        try await client.initialize(clientInfo: ACPImplementation(name: "test", version: "1"))
        _ = try await client.newSession(cwd: "/tmp")
        let first = try await client.prompt("go")
        let second = try await client.prompt("again")
        incoming.continuation.finish()
        _ = try await runTask.value
        var updates: [UInt64?] = []
        for await update in client.sessionUpdates { updates.append(update.localSequence) }
        XCTAssertEqual(first, ACPPromptResponse(stopReason: "end_turn", updatesThrough: 3))
        XCTAssertEqual(updates, [3, 7])
        // Nothing came in before the second reply but the first turn's last update.
        XCTAssertEqual(second.updatesThrough, 7)
    }

    /// A reply that asks before the notification task has reached it waits for it; one that asks
    /// after the task has moved on reads its answer from the recent updates.
    func testUpdateProgressAnswersFromEitherSideOfTheReply() async {
        let progress = UpdateProgress()
        let none = await progress.lastUpdate(through: 0)
        XCTAssertEqual(none, 0)
        let waiting = Task { await progress.lastUpdate(through: 4) }
        progress.took(3, update: true)
        progress.took(4, update: false)
        progress.took(5, update: true)
        let waited = await waiting.value
        let behind = await progress.lastUpdate(through: 4)
        let latest = await progress.lastUpdate(through: 5)
        XCTAssertEqual(waited, 3)
        XCTAssertEqual(behind, 3)
        XCTAssertEqual(latest, 5)

        // Past the recent updates, the newest older one stands in: passed on already, if later.
        for sequence in UInt64(6)...UInt64(6 + UpdateProgress.recentLimit) { progress.took(sequence, update: true) }
        let forgotten = await progress.lastUpdate(through: 4)
        XCTAssertEqual(forgotten, 6)

        let closing = Task { await progress.lastUpdate(through: 1_000) }
        progress.finish()
        let closed = await closing.value
        XCTAssertEqual(closed, UInt64(6 + UpdateProgress.recentLimit))
    }

    private static func reply(_ id: ACPJSONValue, _ result: ACPJSONValue) -> ACPJSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id, "result": result,
            "sequence": .integer(999_999),
        ])
    }

    private static func update(_ forgedSequence: ACPJSONValue) -> ACPJSONValue {
        .object([
            "jsonrpc": .string("2.0"), "method": .string("session/update"),
            "sequence": .integer(999_999),
            "params": .object([
                "sessionId": .string("session-1"),
                "update": .object(["sessionUpdate": .string("config_options_update"), "configOptions": .array([])]),
                "localSequence": forgedSequence,
            ]),
        ])
    }

    private static func encodeFrames(_ frames: [ACPJSONValue]) throws -> Data {
        var data = Data()
        for frame in frames {
            data.append(try JSONEncoder().encode(frame))
            data.append(0x0A)
        }
        return data
    }
}
