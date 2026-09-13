import Foundation
import XCTest
@testable import LatchACP

final class ACPSessionModeSelectionTests: XCTestCase {
    func testSelectionWirePayloadsAndOutOfOrderRepliesPreserveRawOptions() async throws {
        let options: [ACPJSONValue] = [.object([
            "id": .string("effort"),
            "currentValue": .string("high"),
            "options": .array([.object(["value": .string("high"), "name": .string("High")])]),
            "extension": .object(["unknown": .bool(true)]),
        ])]
        let modes: ACPJSONValue = .object(["currentModeId": .string("model-a")])
        let server = MockACPServer { message in
            guard case let .object(request) = message, let id = request["id"] else { return nil }
            let result: ACPJSONValue
            switch request["method"] {
            case .string("initialize"):
                result = .object([
                    "protocolVersion": .integer(1),
                    "agentCapabilities": .object(["loadSession": .bool(false)]),
                ])
            case .string("session/new"):
                result = .object([
                    "sessionId": .string("session-1"),
                    "configOptions": .array(options),
                    "modes": modes,
                ])
            default:
                return nil
            }
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        }
        let connection = ACPJSONRPCConnection(incoming: server.clientIncoming) { data in
            await server.receive(data)
        }
        let client = ACPClient(connection: connection)
        let runTask = Task { try await connection.run() }
        var messages = server.receivedMessages.makeAsyncIterator()
        try await client.initialize(clientInfo: ACPImplementation(name: "test", version: "1"))
        _ = await messages.next()
        let session = try await client.newSession(cwd: "/tmp")
        _ = await messages.next()
        XCTAssertEqual(session.configOptions, options)
        XCTAssertEqual(session.modes, modes)

        let configTask = Task { try await client.setSessionConfigOption(configID: "effort", value: "high") }
        let configMessage = await messages.next()
        XCTAssertEqual(configMessage, .object([
            "jsonrpc": .string("2.0"), "id": .integer(3),
            "method": .string("session/set_config_option"),
            "params": .object([
                "sessionId": .string("session-1"), "configId": .string("effort"), "value": .string("high"),
            ]),
        ]))
        let modelTask = Task { try await client.setSessionMode(modeID: "model-b") }
        let modelMessage = await messages.next()
        XCTAssertEqual(modelMessage, .object([
            "jsonrpc": .string("2.0"), "id": .integer(4),
            "method": .string("session/set_mode"),
            "params": .object(["sessionId": .string("session-1"), "modeId": .string("model-b")]),
        ]))
        // The connection must correlate concurrent selection requests, not arrival order.
        await server.send(.object(["jsonrpc": .string("2.0"), "id": .integer(4), "result": .object([:])]))
        let modelSequence = try await modelTask.value
        XCTAssertEqual(modelSequence, 3)
        await server.send(.object([
            "jsonrpc": .string("2.0"), "id": .integer(3),
            "result": .object(["configOptions": .array(options)]),
        ]))
        let response = try await configTask.value
        XCTAssertEqual(response, ACPSetSessionConfigOptionResponse(configOptions: options, localSequence: 4))
        await server.finish()
        _ = try await runTask.value
    }

    func testSelectionRequiresInitializationAndActiveSession() async throws {
        let server = MockACPServer { message in
            guard case let .object(request) = message, let id = request["id"] else { return nil }
            return .object([
                "jsonrpc": .string("2.0"), "id": id,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "agentCapabilities": .object(["loadSession": .bool(false)]),
                ]),
            ])
        }
        let connection = ACPJSONRPCConnection(incoming: server.clientIncoming) { data in
            await server.receive(data)
        }
        let client = ACPClient(connection: connection)
        let runTask = Task { try await connection.run() }
        for expected in [ACPClientError.initializeRequired, .noActiveSession] {
            do {
                _ = try await client.setSessionConfigOption(configID: "effort", value: "high")
                XCTFail("Expected selection guard")
            } catch let error as ACPClientError {
                XCTAssertEqual(error, expected)
            }
            do {
                try await client.setSessionMode(modeID: "model-b")
                XCTFail("Expected selection guard")
            } catch let error as ACPClientError {
                XCTAssertEqual(error, expected)
            }
            if expected == .initializeRequired {
                try await client.initialize(clientInfo: ACPImplementation(name: "test", version: "1"))
            }
        }
        await server.finish()
        _ = try await runTask.value
    }
}
