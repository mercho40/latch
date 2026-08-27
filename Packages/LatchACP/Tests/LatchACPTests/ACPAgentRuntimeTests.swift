import Foundation
import XCTest
@testable import LatchACP

final class ACPAgentRuntimeTests: XCTestCase {
    func testOwnsProcessConnectionAndSessionLifecycle() async throws {
        let runtime = ACPAgentRuntime(
            configuration: mockProcessConfiguration(),
            clientInfo: ACPImplementation(name: "latch-tests", version: "0.1.0")
        )
        var updates = runtime.sessionUpdates.makeAsyncIterator()
        var standardError = runtime.standardError.makeAsyncIterator()

        let initialized = try await runtime.start()
        XCTAssertEqual(initialized.protocolVersion, 1)
        XCTAssertEqual(initialized.agentInfo?.name, "mock-agent")
        let readyState = await runtime.state()
        XCTAssertEqual(readyState, .ready)

        let session = try await runtime.newSession(cwd: "/tmp/project")
        XCTAssertEqual(session.sessionId, "session-1")
        let response = try await runtime.prompt("Say hello")
        XCTAssertEqual(response.stopReason, "end_turn")

        let update = await updates.next()
        guard case let .messageChunk(chunk)? = update?.event else {
            return XCTFail("Expected an agent message update")
        }
        XCTAssertEqual(chunk.text, "hello")

        let errorData = await standardError.next()
        XCTAssertEqual(errorData.map { String(decoding: $0, as: UTF8.self) }, "mock stderr\n")

        await runtime.stop()
        let stoppedState = await runtime.state()
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testReportsUnexpectedProcessTerminationAndLeavesReadyState() async throws {
        let script = #"""
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
        sleep 0.1
        exit 7
        """#
        let runtime = ACPAgentRuntime(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            clientInfo: ACPImplementation(name: "latch-tests", version: "0.1.0")
        )
        var events = runtime.events.makeAsyncIterator()

        _ = try await runtime.start()
        let event = await events.next()

        XCTAssertEqual(event, .processTerminated(status: 7))
        let stoppedState = await runtime.state()
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testRejectsOperationsBeforeStart() async throws {
        let runtime = ACPAgentRuntime(
            configuration: mockProcessConfiguration(),
            clientInfo: ACPImplementation(name: "latch-tests", version: "0.1.0")
        )

        do {
            _ = try await runtime.newSession(cwd: "/tmp/project")
            XCTFail("Expected runtime to require a ready connection")
        } catch let error as ACPAgentRuntimeError {
            XCTAssertEqual(error, .invalidState(expected: .ready, actual: .idle))
        }
    }

    private func mockProcessConfiguration() -> ACPProcessConfiguration {
        let script = #"""
        printf 'mock stderr\n' >&2
        while IFS= read -r line; do
          case "$line" in
            *\"method\":\"initialize\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
              ;;
            *\"method\":\"session*new\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
              ;;
            *\"method\":\"session*prompt\"*)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
              ;;
          esac
        done
        """#
        return ACPProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
    }
}
