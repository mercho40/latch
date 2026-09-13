import Foundation
import LatchACP
import LatchAgentCore
import LatchAgentXPC
import LatchServiceProtocol
import XCTest

final class LatchAgentXPCClientTests: XCTestCase {
    func testRejectedPromptMessageCrossesXPC() async throws {
        // Authentication-looking prose with a different RPC code must remain commandFailed.
        try await assertRejectedPromptCrossesXPC(rpcCode: -32603, expectedCode: .commandFailed)
    }

    func testAuthenticationRequiredPromptCrossesXPC() async throws {
        try await assertRejectedPromptCrossesXPC(rpcCode: -32000, expectedCode: .authenticationRequired)
    }

    private func assertRejectedPromptCrossesXPC(
        rpcCode: Int, expectedCode: LatchAgentFailureCode
    ) async throws {
        let host = LatchAgentXPCHost(authorize: { _ in true })
        await host.start()
        let listener = NSXPCListener.anonymous()
        listener.delegate = host
        listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(host) {} }
        let client = LatchAgentXPCClient(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        defer { client.close() }
        let script = Self.permissionAgent.replacingOccurrences(
            of: #"{"jsonrpc":"2.0","id":10,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"call-1","title":"Write file"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"}]}}"#,
            with: #"{"jsonrpc":"2.0","id":3,"error":{"code":\#(rpcCode),"message":"Internal error","data":{"message":"Not logged in. Please run /login. https://user:secret@example.com/?token=private","stderr":"private-stderr"}}}"#
        )
        let id = AgentRuntimeID("xpc-rejected")
        _ = try await client.request(.startRuntime(id: id, profile: ACPCommandProfile(
            executablePath: "/bin/sh", arguments: ["-c", script], workingDirectoryPath: "/tmp"
        )))
        _ = try await client.request(.newSession(runtimeID: id, cwd: "/tmp"))
        do {
            _ = try await client.request(.prompt(runtimeID: id, text: "go"))
            XCTFail("Expected a rejected prompt")
        } catch let failure as LatchAgentFailure {
            XCTAssertEqual(failure.code, expectedCode)
            XCTAssertEqual(failure.message, "Agent reported: Not logged in. Please run /login. [redacted]")
            XCTAssertEqual(failure.localizedDescription, failure.message)
        }
        await host.shutdown()
    }

    func testClientAndHostRoundTripCommandsEventsAndPermissions() async throws {
        let host = LatchAgentXPCHost(authorize: { _ in true })
        await host.start()
        let listener = NSXPCListener.anonymous()
        listener.delegate = host
        listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(host) {} }
        let client = LatchAgentXPCClient(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        defer { client.close() }

        let initial = try await client.request(.listRuntimes)
        XCTAssertEqual(initial, .runtimeList([]))
        do {
            _ = try await client.request(.stopRuntime(id: AgentRuntimeID("missing")))
            XCTFail("Expected a service failure")
        } catch let failure as LatchAgentFailure {
            XCTAssertEqual(failure.message, "Runtime not found.")
            XCTAssertEqual(failure.localizedDescription, "Runtime not found.")
        }

        let id = AgentRuntimeID("xpc-client")
        _ = try await client.request(.startRuntime(id: id, profile: ACPCommandProfile(
            executablePath: "/bin/sh", arguments: ["-c", Self.permissionAgent], workingDirectoryPath: "/tmp"
        )))
        _ = try await client.request(.newSession(runtimeID: id, cwd: "/tmp"))
        let prompt = Task { try await client.request(.prompt(runtimeID: id, text: "go")) }
        var events = client.events.makeAsyncIterator()
        guard case let .permissionRequested(eventID, requestID, request)? = await events.next() else {
            return XCTFail("Expected a brokered permission over XPC")
        }
        XCTAssertEqual(eventID, id)
        XCTAssertEqual(request.options.first?.optionId, "allow-once")
        let resolved = try await client.request(.resolvePermission(
            runtimeID: id, requestID: requestID, outcome: .selected(optionID: "allow-once")
        ))
        XCTAssertEqual(resolved, .permissionResolved(runtimeID: id, requestID: requestID))
        guard case let .permissionClosed(_, closedID)? = await events.next() else {
            return XCTFail("Expected the permission to close over XPC")
        }
        XCTAssertEqual(closedID, requestID)
        let completed = try await prompt.value
        XCTAssertEqual(completed, .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn")))
        _ = try await client.request(.stopRuntime(id: id))

        await host.shutdown()
        var remaining = 0
        while await events.next() != nil { remaining += 1 } // Stream finishes once the host drops the peer.
        do {
            _ = try await client.request(.listRuntimes)
            XCTFail("Expected the closed client to reject requests")
        } catch {}
    }

    func testUnauthorizedPeerIsRejected() async throws {
        let host = LatchAgentXPCHost(authorize: { _ in false })
        await host.start()
        let listener = NSXPCListener.anonymous()
        listener.delegate = host
        listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(host) {} }
        let client = LatchAgentXPCClient(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        defer { client.close() }
        do {
            _ = try await client.request(.listRuntimes)
            XCTFail("Expected the rejected connection to fail")
        } catch {}
        var events = client.events.makeAsyncIterator()
        let event = await events.next()
        XCTAssertNil(event)
        await host.shutdown()
    }

    private static let permissionAgent = #"""
    while IFS= read -r line; do
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
          ;;
        *\"method\":\"session*new\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
          ;;
        *\"method\":\"session*prompt\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":10,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"call-1","title":"Write file"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"}]}}'
          ;;
        *\"id\":10*)
          case "$line" in
            *\"selected\"*) printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}' ;;
            *) printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}' ;;
          esac
          ;;
      esac
    done
    """#
}
