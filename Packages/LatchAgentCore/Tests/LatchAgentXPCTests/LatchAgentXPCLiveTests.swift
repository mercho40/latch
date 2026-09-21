import Foundation
import LatchAgentCore
import LatchAgentXPC
import LatchServiceProtocol
import XCTest

/// Opt-in: uses the local Codex login, network access, and subscription/model quota.
/// The XPC listener is in the test process; Codex runs as a real subprocess.
final class LatchAgentXPCLiveTests: XCTestCase {
    func testLiveCodexPromptStreamsThroughXPC() async throws {
        guard ProcessInfo.processInfo.environment["LATCH_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Set LATCH_LIVE_CODEX_TEST=1 to run the live Codex smoke test.")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let service = LatchAgentService()
        let hub = LatchAgentXPCEventHub(events: service.events)
        await hub.start()
        let receiver = TestEventReceiver()
        let delegate = TestListenerDelegate(adapter: LatchAgentXPCAdapter(service: service), eventHub: hub)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = LatchAgentXPCAdapter.interface()
        connection.exportedInterface = LatchAgentXPCEventHub.interface()
        connection.exportedObject = receiver
        connection.resume()
        defer {
            connection.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }

        do {
            try await exercise(connection: connection, receiver: receiver, workspace: workspace)
        } catch {
            await hub.shutdown()
            await service.shutdown()
            throw error
        }
        await hub.shutdown()
        await service.shutdown()
    }

    private func exercise(
        connection: NSXPCConnection,
        receiver: TestEventReceiver,
        workspace: URL
    ) async throws {
        let id = AgentRuntimeID("live-codex")
        let initial = try await request(.listRuntimes, on: connection)
        XCTAssertEqual(initial, .runtimeList([]))
        let start = try await request(.startRuntime(id: id, profile: ACPCommandProfile(
            executablePath: "/usr/bin/env",
            arguments: ["INITIAL_AGENT_MODE=read-only", "npx", "-y", "@agentclientprotocol/codex-acp@1.7.0"],
            workingDirectoryPath: workspace.path
        )), on: connection)
        guard case let .runtimeStarted(startedID, initialization) = start else {
            return XCTFail("Expected live runtime initialization")
        }
        XCTAssertEqual(startedID, id)
        XCTAssertEqual(initialization.protocolVersion, 1)
        print("LIVE: initialized agent=\(initialization.agentInfo?.name ?? "unknown") protocol=\(initialization.protocolVersion)")

        let ready = try await request(.listRuntimes, on: connection)
        XCTAssertEqual(ready, .runtimeList([AgentRuntimeSnapshot(id: id, state: .ready)]))
        let sessionReply = try await request(.newSession(runtimeID: id, cwd: workspace.path), on: connection)
        guard case let .sessionCreated(sessionRuntimeID, session) = sessionReply else {
            return XCTFail("Expected live session creation")
        }
        XCTAssertEqual(sessionRuntimeID, id)
        XCTAssertFalse(session.sessionId.isEmpty)
        print("LIVE: session created")

        let expected = "Latch XPC connected."
        let promptReply = try await request(.prompt(
            runtimeID: id,
            text: "Reply exactly: \(expected) Do not use tools or inspect any files."
        ), on: connection)
        guard case let .promptCompleted(promptRuntimeID, response) = promptReply else {
            return XCTFail("Expected live prompt completion")
        }
        XCTAssertEqual(promptRuntimeID, id)
        XCTAssertEqual(response.stopReason, "end_turn")

        // Request replies and event callbacks are independent XPC channels.
        let deadline = ContinuousClock.now + .seconds(15)
        while Self.assistantText(receiver.envelopes, runtimeID: id).trimmingCharacters(in: .whitespacesAndNewlines) != expected,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let envelopes = receiver.envelopes
        let text = Self.assistantText(envelopes, runtimeID: id).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(text, expected)
        XCTAssertEqual(envelopes.map(\.sequence), (1...max(1, envelopes.count)).map { UInt64($0) })
        for envelope in envelopes {
            XCTAssertEqual(envelope.protocolVersion, LatchServiceProtocolVersion.current)
            if case let .sessionUpdate(_, notification) = envelope.event,
               case .toolCall = notification.event {
                XCTFail("The no-tools smoke test unexpectedly used a tool")
            }
        }
        print("LIVE: received \(envelopes.count) sequenced XPC events; assistant=\(text); stopReason=\(response.stopReason)")

        let stopped = try await request(.stopRuntime(id: id), on: connection)
        XCTAssertEqual(stopped, .runtimeStopped(runtimeID: id))
        let final = try await request(.listRuntimes, on: connection)
        XCTAssertEqual(final, .runtimeList([]))
        print("LIVE: runtime stopped; registry empty")
    }

    private static func assistantText(_ envelopes: [LatchAgentEventEnvelope], runtimeID: AgentRuntimeID) -> String {
        envelopes.compactMap { envelope -> String? in
            guard case let .sessionUpdate(id, notification) = envelope.event,
                  id == runtimeID,
                  case let .messageChunk(chunk) = notification.event,
                  chunk.role == .agent else { return nil }
            return chunk.text
        }.joined()
    }

    private func request(_ command: LatchAgentCommand, on connection: NSXPCConnection) async throws -> LatchAgentResponse {
        let request = LatchAgentRequest(command: command)
        let codec = LatchServiceCodec()
        let payload = try codec.encode(request)
        let completed = expectation(description: "Live XPC request \(request.requestID)")
        let result = LiveReplyBox()
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { error in
            if result.store(.failure(error)) { completed.fulfill() }
        } as? LatchAgentXPCProtocol)
        proxy.sendRequest(payload) { data, error in
            let reply: Result<LatchAgentReply, any Error>
            do {
                if let error { throw error }
                guard let data else { throw LiveTestError.missingReply }
                reply = .success(try codec.decode(LatchAgentReply.self, from: data))
            } catch {
                reply = .failure(error)
            }
            if result.store(reply) { completed.fulfill() }
        }
        await fulfillment(of: [completed], timeout: 120)
        let reply = try XCTUnwrap(result.value).get()
        XCTAssertEqual(reply.requestID, request.requestID)
        XCTAssertEqual(reply.protocolVersion, LatchServiceProtocolVersion.current)
        switch reply.result {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }
}

private enum LiveTestError: Error { case missingReply }

/// The lock protects XPC callback writes and async test reads, and allows only one completion.
private final class LiveReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<LatchAgentReply, any Error>?
    var value: Result<LatchAgentReply, any Error>? { lock.withLock { stored } }

    func store(_ value: Result<LatchAgentReply, any Error>) -> Bool {
        lock.withLock {
            guard stored == nil else { return false }
            stored = value
            return true
        }
    }
}
