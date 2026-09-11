import Foundation
import XCTest
@testable import LatchACP

final class ACPJSONRPCConnectionTests: XCTestCase {
    private struct InitializeResult: Codable, Equatable, Sendable {
        let protocolVersion: Int
        let agentName: String
    }

    func testRequestReceivesTypedResponse() async throws {
        let server = MockACPServer { message in
            guard
                case let .object(request) = message,
                let id = request["id"],
                request["method"] == .string("initialize")
            else {
                return nil
            }

            return .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([
                    "protocolVersion": .integer(1),
                    "agentName": .string("mock-agent"),
                ]),
            ])
        }
        let connection = makeConnection(server: server)
        let runTask = Task { try await connection.run() }

        let result: InitializeResult = try await connection.request(
            "initialize",
            params: .object(["protocolVersion": .integer(1)])
        )

        XCTAssertEqual(
            result,
            InitializeResult(protocolVersion: 1, agentName: "mock-agent")
        )

        await server.finish()
        _ = try await runTask.value
    }

    func testReceivesNotification() async throws {
        let server = MockACPServer()
        let connection = makeConnection(server: server)
        let runTask = Task { try await connection.run() }
        var notifications = connection.notifications.makeAsyncIterator()

        await server.send(
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/update"),
                "params": .object(["text": .string("hello")]),
            ])
        )

        let notification = await notifications.next()
        XCTAssertEqual(
            notification,
            ACPJSONRPCNotification(
                method: "session/update",
                params: .object(["text": .string("hello")]),
                sequence: 1
            )
        )

        await server.finish()
        _ = try await runTask.value
    }

    func testHandlesServerRequest() async throws {
        let server = MockACPServer()
        let connection = makeConnection(server: server)
        await connection.setRequestHandler { request in
            XCTAssertEqual(request.method, "session/request_permission")
            XCTAssertEqual(request.params, .object(["tool": .string("shell")]))
            return .object(["outcome": .string("allow_once")])
        }
        let runTask = Task { try await connection.run() }
        var receivedMessages = server.receivedMessages.makeAsyncIterator()

        await server.send(
            .object([
                "jsonrpc": .string("2.0"),
                "id": .string("permission-1"),
                "method": .string("session/request_permission"),
                "params": .object(["tool": .string("shell")]),
            ])
        )

        let response = await receivedMessages.next()
        XCTAssertEqual(
            response,
            .object([
                "jsonrpc": .string("2.0"),
                "id": .string("permission-1"),
                "result": .object(["outcome": .string("allow_once")]),
            ])
        )

        await server.finish()
        _ = try await runTask.value
    }

    func testSurfacesRemoteError() async throws {
        let server = MockACPServer { message in
            guard case let .object(request) = message, let id = request["id"] else {
                return nil
            }
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object([
                    "code": .integer(-32_001),
                    "message": .string("Session not found"),
                ]),
            ])
        }
        let connection = makeConnection(server: server)
        let runTask = Task { try await connection.run() }

        do {
            let _: ACPJSONValue = try await connection.request("session/load")
            XCTFail("Expected the remote error")
        } catch let error as ACPJSONRPCErrorObject {
            XCTAssertEqual(
                error,
                ACPJSONRPCErrorObject(code: -32_001, message: "Session not found")
            )
        }

        await server.finish()
        _ = try await runTask.value
    }

    func testSendsNotificationWithoutID() async throws {
        let server = MockACPServer()
        let connection = makeConnection(server: server)
        let runTask = Task { try await connection.run() }
        var receivedMessages = server.receivedMessages.makeAsyncIterator()

        try await connection.notify(
            "session/cancel",
            params: .object(["sessionId": .string("session-1")])
        )

        let message = await receivedMessages.next()
        XCTAssertEqual(
            message,
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/cancel"),
                "params": .object(["sessionId": .string("session-1")]),
            ])
        )

        await server.finish()
        _ = try await runTask.value
    }

    func testWaitingServerRequestDoesNotBlockResponsesNotificationsOrEOF() async throws {
        let server = MockACPServer { message in
            guard case let .object(object) = message, let id = object["id"] else { return nil }
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": .string("done")])
        }
        let connection = makeConnection(server: server)
        let started = expectation(description: "Permission handler waiting")
        let cancelled = expectation(description: "EOF cancels permission handler")
        await connection.setRequestHandler { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill() }
            return .null
        }
        let run = Task { try await connection.run() }
        await server.send(.object([
            "jsonrpc": .string("2.0"), "id": .string("permission"),
            "method": .string("session/request_permission"),
        ]))
        await fulfillment(of: [started], timeout: 2)
        let responded = expectation(description: "Response while handler waits")
        let request = Task {
            let result: String = try await connection.request("probe")
            XCTAssertEqual(result, "done")
            responded.fulfill()
        }
        let notified = expectation(description: "Notification while handler waits")
        let notifications = Task {
            for await notification in connection.notifications {
                XCTAssertEqual(notification.method, "session/update")
                notified.fulfill()
                break
            }
        }
        await server.send(.object(["jsonrpc": .string("2.0"), "method": .string("session/update")]))
        await fulfillment(of: [responded, notified], timeout: 2)
        await server.finish()
        _ = try await run.value
        await fulfillment(of: [cancelled], timeout: 2)
        request.cancel()
        notifications.cancel()
    }

    func testDuplicateAndExcessiveIncomingRequestsCloseConnection() async throws {
        for ids in [["same", "same"], (0..<33).map { String($0) }] {
            let server = MockACPServer()
            let connection = makeConnection(server: server)
            await connection.setRequestHandler { _ in
                try await Task.sleep(for: .seconds(60))
                return .null
            }
            let run = Task { try await connection.run() }
            for id in ids {
                await server.send(.object([
                    "jsonrpc": .string("2.0"), "id": .string(id), "method": .string("permission"),
                ]))
            }
            do {
                try await run.value
                XCTFail("Expected request admission failure")
            } catch let error as ACPJSONRPCConnectionError {
                XCTAssertEqual(error, .invalidMessage(ids.count == 2
                    ? "Duplicate in-flight request id" : "Too many in-flight requests"))
            }
            await server.finish()
        }
    }

    private func makeConnection(server: MockACPServer) -> ACPJSONRPCConnection {
        ACPJSONRPCConnection(incoming: server.clientIncoming) { data in
            await server.receive(data)
        }
    }
}

actor MockACPServer {
    typealias AutomaticReply = @Sendable (ACPJSONValue) -> ACPJSONValue?

    nonisolated let clientIncoming: AsyncStream<Data>
    nonisolated let receivedMessages: AsyncStream<ACPJSONValue>

    private let clientContinuation: AsyncStream<Data>.Continuation
    private let receivedContinuation: AsyncStream<ACPJSONValue>.Continuation
    private let automaticReply: AutomaticReply
    private var decoder = ACPFrameDecoder()

    init(automaticReply: @escaping AutomaticReply = { _ in nil }) {
        let clientPair = AsyncStream<Data>.makeStream()
        let receivedPair = AsyncStream<ACPJSONValue>.makeStream()
        self.clientIncoming = clientPair.stream
        self.clientContinuation = clientPair.continuation
        self.receivedMessages = receivedPair.stream
        self.receivedContinuation = receivedPair.continuation
        self.automaticReply = automaticReply
    }

    func receive(_ data: Data) {
        for event in decoder.append(data) {
            guard case let .frame(frame) = event else {
                continue
            }
            guard let message = try? JSONDecoder().decode(ACPJSONValue.self, from: frame) else {
                continue
            }
            receivedContinuation.yield(message)
            if let response = automaticReply(message) {
                send(response)
            }
        }
    }

    func send(_ message: ACPJSONValue) {
        guard var data = try? JSONEncoder().encode(message) else {
            return
        }
        data.append(0x0A)
        clientContinuation.yield(data)
    }

    func finish() {
        clientContinuation.finish()
        receivedContinuation.finish()
    }
}
