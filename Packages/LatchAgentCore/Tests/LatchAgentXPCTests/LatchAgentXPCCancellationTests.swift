import Foundation
import LatchAgentCore
import LatchAgentXPC
import LatchServiceProtocol
import XCTest

final class LatchAgentXPCCancellationTests: XCTestCase {
    func testCancelsPendingPromptOnSameXPCConnection() async throws {
        let service = LatchAgentService()
        let delegate = TestListenerDelegate(adapter: LatchAgentXPCAdapter(service: service))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = LatchAgentXPCAdapter.interface()
        connection.resume()
        defer {
            connection.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }

        do {
            try await exerciseCancellation(service: service, connection: connection)
        } catch {
            await service.shutdown()
            throw error
        }
        await service.shutdown()
    }

    private func exerciseCancellation(
        service: LatchAgentService,
        connection: NSXPCConnection
    ) async throws {
        let runtimeID = AgentRuntimeID("xpc-cancellation")
        let start = try send(.startRuntime(id: runtimeID, profile: ACPCommandProfile(
            executablePath: "/bin/sh",
            arguments: ["-c", Self.serverScript],
            workingDirectoryPath: "/tmp"
        )), on: connection) { response in
            guard case let .runtimeStarted(id, _) = response else {
                return XCTFail("Expected runtime start")
            }
            XCTAssertEqual(id, runtimeID)
        }
        await fulfillment(of: [start], timeout: 5)

        let session = try send(.newSession(runtimeID: runtimeID, cwd: "/tmp"), on: connection) { response in
            guard case let .sessionCreated(id, session) = response else {
                return XCTFail("Expected session creation")
            }
            XCTAssertEqual(id, runtimeID)
            XCTAssertEqual(session.sessionId, "session-1")
        }
        await fulfillment(of: [session], timeout: 5)

        // Observe the service locally only to synchronize with the mock agent.
        // This does not claim to test event forwarding over XPC.
        let working = expectation(description: "Agent received prompt")
        let observer = Task {
            for await event in service.events {
                guard case let .sessionUpdate(id, notification) = event,
                      id == runtimeID,
                      case let .messageChunk(chunk) = notification.event,
                      chunk.text == "working" else { continue }
                working.fulfill()
                return
            }
        }
        defer { observer.cancel() }

        let prompt = try send(.prompt(runtimeID: runtimeID, text: "Keep working"), on: connection) { response in
            guard case let .promptCompleted(id, result) = response else {
                return XCTFail("Expected prompt completion")
            }
            XCTAssertEqual(id, runtimeID)
            XCTAssertEqual(result.stopReason, "cancelled")
        }
        await fulfillment(of: [working], timeout: 5)

        // Both commands use the same connection while the mock withholds the prompt reply.
        let list = try send(.listRuntimes, on: connection) { response in
            XCTAssertEqual(response, .runtimeList([AgentRuntimeSnapshot(id: runtimeID, state: .ready)]))
        }
        await fulfillment(of: [list], timeout: 5)
        let cancel = try send(.cancelPrompt(runtimeID: runtimeID), on: connection) { response in
            XCTAssertEqual(response, .promptCancellationRequested(runtimeID: runtimeID))
        }
        // The cancellation acknowledgement and prompt reply may arrive in either order.
        await fulfillment(of: [cancel, prompt], timeout: 5)

        let stop = try send(.stopRuntime(id: runtimeID), on: connection) { response in
            XCTAssertEqual(response, .runtimeStopped(runtimeID: runtimeID))
        }
        await fulfillment(of: [stop], timeout: 5)
        let emptyList = try send(.listRuntimes, on: connection) { response in
            XCTAssertEqual(response, .runtimeList([]))
        }
        await fulfillment(of: [emptyList], timeout: 5)
    }

    private func send(
        _ command: LatchAgentCommand,
        on connection: NSXPCConnection,
        check: @escaping @Sendable (LatchAgentResponse) -> Void
    ) throws -> XCTestExpectation {
        let request = LatchAgentRequest(command: command)
        let codec = LatchServiceCodec()
        let payload = try codec.encode(request)
        let finished = expectation(description: "Reply for \(request.requestID)")
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC connection failed: \(error)")
            finished.fulfill()
        } as? LatchAgentXPCProtocol)
        proxy.sendRequest(payload) { data, error in
            defer { finished.fulfill() }
            XCTAssertNil(error)
            guard let data else { return XCTFail("Missing reply payload") }
            do {
                let reply = try codec.decode(LatchAgentReply.self, from: data)
                XCTAssertEqual(reply.requestID, request.requestID)
                XCTAssertEqual(reply.protocolVersion, LatchServiceProtocolVersion.current)
                guard case let .success(response) = reply.result else {
                    return XCTFail("Unexpected service failure: \(reply.result)")
                }
                check(response)
            } catch {
                XCTFail("Invalid service reply: \(error)")
            }
        }
        return finished
    }

    // This fixture expects initialize/new/prompt as ACP request IDs 1/2/3.
    // It never completes the prompt until it receives session/cancel.
    private static let serverScript = #"""
    while IFS= read -r line; do
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
          ;;
        *\"method\":\"session*new\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
          ;;
        *\"method\":\"session*prompt\"*)
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"working"}}}}'
          ;;
        *\"method\":\"session*cancel\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}'
          ;;
      esac
    done
    """#
}
