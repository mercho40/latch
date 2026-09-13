import Foundation
import XCTest
@testable import LatchACP

final class ACPLoadSessionTests: XCTestCase {
    func testRuntimeRequiresReadyBeforeLoading() async throws {
        let runtime = ACPAgentRuntime(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            clientInfo: ACPImplementation(name: "test", version: "1")
        )
        do {
            _ = try await runtime.loadSession(sessionID: "saved", cwd: "/tmp")
            XCTFail("Expected runtime readiness guard")
        } catch let error as ACPAgentRuntimeError {
            XCTAssertEqual(error, .invalidState(expected: .ready, actual: .idle))
        }
    }

    func testLoadReplaySequenceAndActiveSessionBeforeResponse() async throws {
        let harness = Harness()
        let run = Task { try await harness.connection.run() }
        try await harness.initialize()
        var sent = harness.sent.makeAsyncIterator()
        let load = Task { try await harness.client.loadSession(sessionID: "saved", cwd: "/tmp/project") }
        let received = await sent.next()
        let request = try XCTUnwrap(received)
        XCTAssertEqual(request["method"], .string("session/load"))
        XCTAssertEqual(request["params"], .object([
            "sessionId": .string("saved"), "cwd": .string("/tmp/project"), "mcpServers": .array([]),
        ]))
        try harness.send(.object([
            "jsonrpc": .string("2.0"), "method": .string("session/update"),
            "params": .object([
                "sessionId": .string("saved"), "localSequence": .string("forged"),
                "update": .object(["sessionUpdate": .string("agent_message_chunk"),
                                   "content": .object(["type": .string("text"), "text": .string("history")])]),
            ]),
        ]))
        var updates = harness.client.sessionUpdates.makeAsyncIterator()
        let replay = await updates.next()
        XCTAssertEqual(replay?.sessionId, "saved")
        XCTAssertEqual(replay?.localSequence, 2)
        // Load is still waiting: even cancellation must already target the saved ID.
        try await harness.client.cancelPrompt()
        let cancel = await sent.next()
        XCTAssertEqual(cancel?["params"], .object(["sessionId": .string("saved")]))
        let modes: ACPJSONValue = .object(["currentModeId": .string("ask")])
        let models: ACPJSONValue = .object(["currentModelId": .string("model-a")])
        try harness.reply(request, result: .object([
            "modes": modes, "models": models, "configOptions": .array([]),
            "_meta": .object(["saved": .bool(true)]), "localSequence": .string("forged"),
        ]))
        let response = try await load.value
        XCTAssertEqual(response, ACPLoadSessionResponse(
            modes: modes, models: models, configOptions: [],
            meta: .object(["saved": .bool(true)]), localSequence: 3
        ))
        let prompt = Task { try await harness.client.prompt("continue") }
        let receivedPrompt = await sent.next()
        let promptRequest = try XCTUnwrap(receivedPrompt)
        guard case let .object(params)? = promptRequest["params"] else { return XCTFail("Missing params") }
        XCTAssertEqual(params["sessionId"], .string("saved"))
        do {
            _ = try await harness.client.loadSession(sessionID: "other", cwd: "/tmp")
            XCTFail("Expected active prompt guard")
        } catch let error as ACPClientError { XCTAssertEqual(error, .promptAlreadyActive) }
        try harness.reply(promptRequest, result: .object(["stopReason": .string("end_turn")]))
        let result = try await prompt.value
        XCTAssertEqual(result.stopReason, "end_turn")
        harness.finish()
        _ = try await run.value
    }

    func testInitializationAndCapabilityGuardsSendNoLoadRequest() async throws {
        for capabilities: ACPJSONValue in [.object([:]), .object(["loadSession": .bool(false)])] {
            let harness = Harness(capabilities: capabilities)
            do {
                _ = try await harness.client.loadSession(sessionID: "saved", cwd: "/tmp")
                XCTFail("Expected initializeRequired")
            } catch let error as ACPClientError { XCTAssertEqual(error, .initializeRequired) }
            let run = Task { try await harness.connection.run() }
            try await harness.initialize()
            do {
                _ = try await harness.client.loadSession(sessionID: "saved", cwd: "/tmp")
                XCTFail("Expected capability guard")
            } catch let error as ACPClientError { XCTAssertEqual(error, .loadSessionUnsupported) }
            harness.finish()
            _ = try await run.value
            var sent = harness.sent.makeAsyncIterator()
            let unexpected = await sent.next()
            XCTAssertNil(unexpected)
        }
    }

    func testStaleNewAndLoadCompletionsCannotReplaceNewerSelection() async throws {
        for (olderIsNew, newerIsNew) in [(false, false), (false, true), (true, false), (true, true)] {
            for olderFails in [false, true] {
                let harness = Harness()
                let run = Task { try await harness.connection.run() }
                try await harness.initialize()
                var sent = harness.sent.makeAsyncIterator()
                let old = Task {
                    if olderIsNew { _ = try await harness.client.newSession(cwd: "/tmp") }
                    else { _ = try await harness.client.loadSession(sessionID: "old", cwd: "/tmp") }
                }
                let receivedOld = await sent.next()
                let oldRequest = try XCTUnwrap(receivedOld)
                let newer = Task {
                    if newerIsNew { _ = try await harness.client.newSession(cwd: "/tmp") }
                    else { _ = try await harness.client.loadSession(sessionID: "newer", cwd: "/tmp") }
                }
                let receivedNew = await sent.next()
                let newRequest = try XCTUnwrap(receivedNew)
                try harness.reply(newRequest, result: newerIsNew
                    ? .object(["sessionId": .string("newer")]) : .object([:]))
                _ = try await newer.value
                if olderFails {
                    try harness.send(.object(["jsonrpc": .string("2.0"), "id": oldRequest["id"]!,
                                              "error": .object(["code": .integer(-32603), "message": .string("failed")])]))
                } else {
                    try harness.reply(oldRequest, result: olderIsNew
                        ? .object(["sessionId": .string("old")]) : .object([:]))
                }
                do { try await old.value; XCTFail("Expected stale operation failure") }
                catch {
                    if !olderFails { XCTAssertEqual(error as? ACPClientError, .sessionOperationSuperseded) }
                }
                try await harness.client.cancelPrompt()
                let cancel = await sent.next()
                XCTAssertEqual(cancel?["params"], .object(["sessionId": .string("newer")]))
                harness.finish()
                _ = try await run.value
            }
        }
    }

    func testFailedLoadClearsSelectionAndCanRetry() async throws {
        let harness = Harness()
        let run = Task { try await harness.connection.run() }
        try await harness.initialize()
        var sent = harness.sent.makeAsyncIterator()
        let load = Task { try await harness.client.loadSession(sessionID: "missing", cwd: "/tmp") }
        let received = await sent.next()
        let request = try XCTUnwrap(received)
        // Invalid response must not leave the failed session active either.
        try harness.reply(request, result: .object(["configOptions": .string("invalid")]))
        do { _ = try await load.value; XCTFail("Expected decoding failure") } catch {}
        do { try await harness.client.cancelPrompt(); XCTFail("Expected no session") }
        catch let error as ACPClientError { XCTAssertEqual(error, .noActiveSession) }
        let retry = Task { try await harness.client.loadSession(sessionID: "saved", cwd: "/tmp", mcpServers: [.object(["name": .string("test")])]) }
        let receivedRetry = await sent.next()
        let retryRequest = try XCTUnwrap(receivedRetry)
        guard case let .object(params)? = retryRequest["params"] else { return XCTFail("Missing params") }
        XCTAssertEqual(params["mcpServers"], .array([.object(["name": .string("test")])]))
        try harness.reply(retryRequest, result: .object([:]))
        let response = try await retry.value
        XCTAssertEqual(response, ACPLoadSessionResponse(localSequence: 3))
        harness.finish()
        _ = try await run.value
    }

    private struct Harness {
        let incoming = AsyncStream<Data>.makeStream()
        let sent: AsyncStream<[String: ACPJSONValue]>
        let sentContinuation: AsyncStream<[String: ACPJSONValue]>.Continuation
        let connection: ACPJSONRPCConnection
        let client: ACPClient

        init(capabilities: ACPJSONValue = .object(["loadSession": .bool(true)])) {
            let pair = AsyncStream<[String: ACPJSONValue]>.makeStream()
            sent = pair.stream
            sentContinuation = pair.continuation
            let continuation = incoming.continuation
            connection = ACPJSONRPCConnection(incoming: incoming.stream) { data in
                guard case let .object(request) = try JSONDecoder().decode(ACPJSONValue.self, from: data) else { return }
                if request["method"] == .string("initialize") {
                    let reply: ACPJSONValue = .object([
                        "jsonrpc": .string("2.0"), "id": request["id"]!,
                        "result": .object(["protocolVersion": .integer(1), "agentCapabilities": capabilities]),
                    ])
                    var frame = try JSONEncoder().encode(reply)
                    frame.append(0x0A)
                    continuation.yield(frame)
                } else { pair.continuation.yield(request) }
            }
            client = ACPClient(connection: connection)
        }

        func initialize() async throws {
            try await client.initialize(clientInfo: ACPImplementation(name: "test", version: "1"))
        }

        func send(_ value: ACPJSONValue) throws {
            var frame = try JSONEncoder().encode(value)
            frame.append(0x0A)
            incoming.continuation.yield(frame)
        }

        func reply(_ request: [String: ACPJSONValue], result: ACPJSONValue) throws {
            try send(.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": result]))
        }

        func finish() {
            incoming.continuation.finish()
            sentContinuation.finish()
        }
    }
}
