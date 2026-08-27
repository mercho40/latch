import Foundation
import XCTest
@testable import LatchACP

final class ACPSessionTests: XCTestCase {
    func testProjectsAgentMessageChunk() {
        let notification = ACPSessionNotification(
            sessionId: "session-1",
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .string("message-1"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("hello"),
                ]),
            ])
        )

        guard case let .messageChunk(chunk) = notification.event else {
            return XCTFail("Expected a message chunk")
        }
        XCTAssertEqual(chunk.role, .agent)
        XCTAssertEqual(chunk.messageID, "message-1")
        XCTAssertEqual(chunk.text, "hello")
    }

    func testProjectsToolCallLifecycle() {
        let created = ACPSessionNotification(
            sessionId: "session-1",
            update: .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tool-1"),
                "title": .string("Run tests"),
                "kind": .string("execute"),
                "status": .string("pending"),
            ])
        )
        let updated = ACPSessionNotification(
            sessionId: "session-1",
            update: .object([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("tool-1"),
                "status": .string("completed"),
                "content": .array([]),
            ])
        )

        guard case let .toolCall(createdTool, initial: initial) = created.event else {
            return XCTFail("Expected an initial tool call")
        }
        XCTAssertTrue(initial)
        XCTAssertEqual(createdTool.toolCallID, "tool-1")
        XCTAssertEqual(createdTool.title, "Run tests")
        XCTAssertEqual(createdTool.kind, "execute")
        XCTAssertEqual(createdTool.status, "pending")

        guard case let .toolCall(updatedTool, initial: updateIsInitial) = updated.event else {
            return XCTFail("Expected a tool call update")
        }
        XCTAssertFalse(updateIsInitial)
        XCTAssertEqual(updatedTool.toolCallID, "tool-1")
        XCTAssertEqual(updatedTool.status, "completed")
        XCTAssertEqual(updatedTool.content, [])
    }

    func testPreservesUnknownSessionUpdate() {
        let update: ACPJSONValue = .object([
            "sessionUpdate": .string("future_update"),
            "value": .integer(42),
        ])
        let notification = ACPSessionNotification(sessionId: "session-1", update: update)

        XCTAssertEqual(notification.event, .other(kind: "future_update", payload: update))
    }

    func testPromptStreamsUpdatesAndReturnsStopReason() async throws {
        let server = lifecycleServer()
        let connection = makeConnection(server)
        let client = ACPClient(connection: connection)
        let runTask = Task { try await connection.run() }
        var updates = client.sessionUpdates.makeAsyncIterator()

        try await initializeAndCreateSession(client)
        await server.send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string("session-1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("hello"),
                    ]),
                ]),
            ]),
        ]))

        let response = try await client.prompt("Say hello")
        XCTAssertEqual(response.stopReason, "end_turn")
        let update = await updates.next()
        XCTAssertEqual(update?.sessionId, "session-1")
        XCTAssertEqual(
            update?.update,
            .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("hello"),
                ]),
            ])
        )

        await server.finish()
        _ = try await runTask.value
    }

    func testCancelSendsNotificationForActiveSession() async throws {
        let server = lifecycleServer()
        let connection = makeConnection(server)
        let client = ACPClient(connection: connection)
        let runTask = Task { try await connection.run() }
        var messages = server.receivedMessages.makeAsyncIterator()

        try await initializeAndCreateSession(client)
        _ = await messages.next()
        _ = await messages.next()
        try await client.cancelPrompt()

        let cancelMessage = await messages.next()
        XCTAssertEqual(
            cancelMessage,
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/cancel"),
                "params": .object(["sessionId": .string("session-1")]),
            ])
        )

        await server.finish()
        _ = try await runTask.value
    }

    func testPermissionHandlerReturnsSelectedOption() async throws {
        let server = MockACPServer()
        let connection = makeConnection(server)
        let client = ACPClient(connection: connection)
        await client.setPermissionHandler { request in
            XCTAssertEqual(request.sessionId, "session-1")
            XCTAssertEqual(request.options.map(\.optionId), ["allow-once", "reject-once"])
            return .selected(optionID: "allow-once")
        }
        let runTask = Task { try await connection.run() }
        var messages = server.receivedMessages.makeAsyncIterator()

        await server.send(.object([
            "jsonrpc": .string("2.0"),
            "id": .string("permission-1"),
            "method": .string("session/request_permission"),
            "params": .object([
                "sessionId": .string("session-1"),
                "toolCall": .object([
                    "toolCallId": .string("tool-1"),
                    "title": .string("Run command"),
                ]),
                "options": .array([
                    .object([
                        "optionId": .string("allow-once"),
                        "name": .string("Allow once"),
                        "kind": .string("allow_once"),
                    ]),
                    .object([
                        "optionId": .string("reject-once"),
                        "name": .string("Reject"),
                        "kind": .string("reject_once"),
                    ]),
                ]),
            ]),
        ]))

        let permissionResponse = await messages.next()
        XCTAssertEqual(
            permissionResponse,
            .object([
                "jsonrpc": .string("2.0"),
                "id": .string("permission-1"),
                "result": .object([
                    "outcome": .object([
                        "outcome": .string("selected"),
                        "optionId": .string("allow-once"),
                    ]),
                ]),
            ])
        )

        await server.finish()
        _ = try await runTask.value
    }

    private func makeConnection(_ server: MockACPServer) -> ACPJSONRPCConnection {
        ACPJSONRPCConnection(incoming: server.clientIncoming) { data in
            await server.receive(data)
        }
    }

    private func initializeAndCreateSession(_ client: ACPClient) async throws {
        try await client.initialize(
            clientInfo: ACPImplementation(name: "latch", version: "0.1.0")
        )
        _ = try await client.newSession(cwd: "/tmp/project")
    }

    private func lifecycleServer() -> MockACPServer {
        MockACPServer { message in
            guard
                case let .object(request) = message,
                let id = request["id"],
                case let .string(method)? = request["method"]
            else {
                return nil
            }

            let result: ACPJSONValue
            switch method {
            case "initialize":
                result = .object([
                    "protocolVersion": .integer(1),
                    "agentCapabilities": .object(["loadSession": .bool(true)]),
                ])
            case "session/new":
                result = .object(["sessionId": .string("session-1")])
            case "session/prompt":
                result = .object(["stopReason": .string("end_turn")])
            default:
                return nil
            }

            return .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": result,
            ])
        }
    }
}
