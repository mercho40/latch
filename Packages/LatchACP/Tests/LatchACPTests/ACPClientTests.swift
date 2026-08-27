import Foundation
import XCTest
@testable import LatchACP

final class ACPClientTests: XCTestCase {
    func testInitializesAndCreatesSessionAgainstMockServer() async throws {
        let server = MockACPServer { message in
            guard
                case let .object(request) = message,
                let id = request["id"],
                case let .string(method)? = request["method"]
            else {
                return nil
            }

            switch method {
            case "initialize":
                return .object([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object([
                        "protocolVersion": .integer(1),
                        "agentCapabilities": .object([
                            "loadSession": .bool(true),
                            "promptCapabilities": .object(["image": .bool(true)]),
                        ]),
                        "agentInfo": .object([
                            "name": .string("mock-agent"),
                            "title": .string("Mock Agent"),
                            "version": .string("1.0.0"),
                        ]),
                    ]),
                ])
            case "session/new":
                return .object([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object([
                        "sessionId": .string("session-1"),
                        "modes": .object([
                            "currentModeId": .string("ask"),
                            "availableModes": .array([]),
                        ]),
                    ]),
                ])
            default:
                return nil
            }
        }
        let connection = ACPJSONRPCConnection(incoming: server.clientIncoming) { data in
            await server.receive(data)
        }
        let client = ACPClient(connection: connection)
        let runTask = Task { try await connection.run() }
        var receivedMessages = server.receivedMessages.makeAsyncIterator()

        let initializeResponse = try await client.initialize(
            clientInfo: ACPImplementation(name: "latch", title: "Latch", version: "0.1.0")
        )
        XCTAssertEqual(initializeResponse.protocolVersion, 1)
        XCTAssertEqual(initializeResponse.agentInfo?.name, "mock-agent")
        XCTAssertTrue(initializeResponse.agentCapabilities.loadSession)
        let negotiatedCapabilities = try await client.negotiatedCapabilities()
        XCTAssertEqual(negotiatedCapabilities, initializeResponse.agentCapabilities)

        let initializeMessage = await receivedMessages.next()
        XCTAssertEqual(
            initializeMessage,
            .object([
                "jsonrpc": .string("2.0"),
                "id": .integer(1),
                "method": .string("initialize"),
                "params": .object([
                    "protocolVersion": .integer(1),
                    "clientCapabilities": .object([
                        "fs": .object([
                            "readTextFile": .bool(false),
                            "writeTextFile": .bool(false),
                        ]),
                        "terminal": .bool(false),
                    ]),
                    "clientInfo": .object([
                        "name": .string("latch"),
                        "title": .string("Latch"),
                        "version": .string("0.1.0"),
                    ]),
                ]),
            ])
        )

        let session = try await client.newSession(cwd: "/tmp/project")
        XCTAssertEqual(session.sessionId, "session-1")
        XCTAssertEqual(
            session.modes,
            .object([
                "currentModeId": .string("ask"),
                "availableModes": .array([]),
            ])
        )

        let newSessionMessage = await receivedMessages.next()
        XCTAssertEqual(
            newSessionMessage,
            .object([
                "jsonrpc": .string("2.0"),
                "id": .integer(2),
                "method": .string("session/new"),
                "params": .object([
                    "cwd": .string("/tmp/project"),
                    "mcpServers": .array([]),
                ]),
            ])
        )

        await server.finish()
        _ = try await runTask.value
    }

    func testRequiresInitializeBeforeCreatingSession() async throws {
        let server = MockACPServer()
        let connection = ACPJSONRPCConnection(incoming: server.clientIncoming) { data in
            await server.receive(data)
        }
        let client = ACPClient(connection: connection)

        do {
            _ = try await client.newSession(cwd: "/tmp/project")
            XCTFail("Expected initialize to be required")
        } catch let error as ACPClientError {
            XCTAssertEqual(error, .initializeRequired)
        }

        await server.finish()
    }

    func testRejectsUnsupportedProtocolVersion() async throws {
        let server = MockACPServer { message in
            guard case let .object(request) = message, let id = request["id"] else {
                return nil
            }
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([
                    "protocolVersion": .integer(2),
                    "agentCapabilities": .object(["loadSession": .bool(false)]),
                ]),
            ])
        }
        let connection = ACPJSONRPCConnection(incoming: server.clientIncoming) { data in
            await server.receive(data)
        }
        let client = ACPClient(connection: connection)
        let runTask = Task { try await connection.run() }

        do {
            _ = try await client.initialize(
                clientInfo: ACPImplementation(name: "latch", version: "0.1.0")
            )
            XCTFail("Expected protocol negotiation to fail")
        } catch let error as ACPClientError {
            XCTAssertEqual(
                error,
                .unsupportedProtocolVersion(expected: 1, received: 2)
            )
        }

        await server.finish()
        _ = try await runTask.value
    }
}
