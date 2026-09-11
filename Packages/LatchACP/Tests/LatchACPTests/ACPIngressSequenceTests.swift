import Foundation
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
        let oldResult: String = try await connection.request("test")
        XCTAssertEqual(oldResult, "ok")
        incoming.continuation.finish()
        _ = try await runTask.value
        var sequences: [UInt64] = []
        for await notification in connection.notifications { sequences.append(notification.sequence) }
        XCTAssertEqual(sequences, [3, 5, 8, 10])
        XCTAssertEqual(ACPJSONRPCNotification(method: "manual").sequence, 0)
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
