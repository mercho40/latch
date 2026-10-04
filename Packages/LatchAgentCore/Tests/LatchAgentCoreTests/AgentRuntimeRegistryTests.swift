import Foundation
import LatchACP
import LatchServiceProtocol
import XCTest
@testable import LatchAgentCore

final class AgentRuntimeRegistryTests: XCTestCase {
    func testStartsListsAndStopsMultipleRuntimes() async throws {
        let registry = AgentRuntimeRegistry()
        let firstID = AgentRuntimeID("first")
        let secondID = AgentRuntimeID("second")

        _ = try await registry.start(
            id: secondID,
            configuration: mockConfiguration(),
            clientInfo: clientInfo
        )
        _ = try await registry.start(
            id: firstID,
            configuration: mockConfiguration(),
            clientInfo: clientInfo
        )

        let first = try await registry.runtime(for: firstID)
        let second = try await registry.runtime(for: secondID)
        let runtimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(runtimeIDs, [firstID, secondID])
        let snapshots = await registry.snapshots()
        XCTAssertEqual(
            snapshots,
            [
                AgentRuntimeSnapshot(id: firstID, state: .ready),
                AgentRuntimeSnapshot(id: secondID, state: .ready),
            ]
        )
        let encodedSnapshots = try JSONEncoder().encode(snapshots)
        XCTAssertEqual(try JSONDecoder().decode([AgentRuntimeSnapshot].self, from: encodedSnapshots), snapshots)
        let firstState = await first.state()
        let secondState = await second.state()
        XCTAssertEqual(firstState, .ready)
        XCTAssertEqual(secondState, .ready)

        try await registry.stop(id: firstID)
        let remainingRuntimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(remainingRuntimeIDs, [secondID])
        let stoppedFirstState = await first.state()
        XCTAssertEqual(stoppedFirstState, .stopped)

        await registry.stopAll()
        let emptyRuntimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(emptyRuntimeIDs, [])
        let stoppedSecondState = await second.state()
        XCTAssertEqual(stoppedSecondState, .stopped)
    }

    func testControlsSessionThroughRegistryFacade() async throws {
        let registry = AgentRuntimeRegistry()
        let id = AgentRuntimeID("session")
        _ = try await registry.start(
            id: id,
            configuration: sessionConfiguration(),
            clientInfo: clientInfo
        )
        var events = registry.events.makeAsyncIterator()

        let session = try await registry.newSession(runtimeID: id, cwd: "/tmp/project")
        XCTAssertEqual(session.sessionId, "session-1")

        let promptTask = Task {
            try await registry.prompt(runtimeID: id, text: "Keep working")
        }
        let event = await events.next()
        guard case let .sessionUpdate(runtimeID, notification)? = event else {
            return XCTFail("Expected prompt progress before cancellation")
        }
        XCTAssertEqual(runtimeID, id)
        guard case let .messageChunk(chunk) = notification.event else {
            return XCTFail("Expected an agent message chunk")
        }
        XCTAssertEqual(chunk.text, "working")

        try await registry.cancelPrompt(runtimeID: id)
        let response = try await promptTask.value
        XCTAssertEqual(response.stopReason, "cancelled")
        await registry.stopAll()
    }

    func testForwardsStandardErrorThroughRegistryEvents() async throws {
        let registry = AgentRuntimeRegistry()
        let id = AgentRuntimeID("diagnostics")
        let script = #"""
        printf 'agent diagnostic\n' >&2
        while IFS= read -r line; do
          case "$line" in
            *\"method\":\"initialize\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
              ;;
          esac
        done
        """#
        var events = registry.events.makeAsyncIterator()

        _ = try await registry.start(
            id: id,
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            clientInfo: clientInfo
        )

        let event = await events.next()
        XCTAssertEqual(
            event,
            .standardError(runtimeID: id, data: Data("agent diagnostic\n".utf8))
        )
        await registry.stopAll()
    }

    /// A question the agent asks during a turn is brokered as an event and answered by command;
    /// one still open when the turn ends is withdrawn and the agent hears it refused.
    func testBrokersQuestionsAndWithdrawsThemWithTheirTurn() async throws {
        let registry = AgentRuntimeRegistry()
        let id = AgentRuntimeID("questions")
        let script = #"""
        prompt_id=
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *\"method\":\"initialize\"*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\n' "$id" ;;
            *\"method\":\"session*/new\"*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"session-1"}}\n' "$id" ;;
            *\"method\":\"session*/prompt\"*)
              prompt_id=$id
              printf '%s\n' '{"jsonrpc":"2.0","id":901,"method":"elicitation/create","params":{"sessionId":"session-1","mode":"form","message":"Which?","requestedSchema":{"type":"object","properties":{"answer":{"type":"string"}}}}}' ;;
            *\"id\":901[,}]*)
              case "$line" in
                *accept*) printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$prompt_id" ;;
                *) printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"cancelled"}}\n' "$prompt_id" ;;
              esac ;;
          esac
        done
        """#
        _ = try await registry.start(
            id: id,
            configuration: ACPProcessConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                                   workingDirectoryURL: URL(fileURLWithPath: "/tmp")),
            clientInfo: clientInfo
        )
        _ = try await registry.newSession(runtimeID: id, cwd: "/tmp")
        var events = registry.events.makeAsyncIterator()

        let answered = Task { try await registry.prompt(runtimeID: id, text: "ask") }
        guard case let .elicitationRequested(askedBy, requestID, request)? = await events.next() else { return XCTFail("A question") }
        XCTAssertEqual(askedBy, id)
        XCTAssertEqual(request.message, "Which?")
        let pending = await registry.pendingElicitationRequestIDs(runtimeID: id)
        XCTAssertEqual(pending, [requestID])
        try await registry.resolveElicitation(runtimeID: id, requestID: requestID,
                                              response: ACPElicitationResponse(action: .accept, content: ["answer": .string("this")]))
        guard case .elicitationClosed(id, requestID)? = await events.next() else { return XCTFail("The question closed") }
        let firstStop = try await answered.value.stopReason
        XCTAssertEqual(firstStop, "end_turn")
        do {
            try await registry.resolveElicitation(runtimeID: id, requestID: requestID, response: .cancelled)
            XCTFail("An answered question takes no second answer")
        } catch AgentRuntimeRegistryError.elicitationRequestNotFound {}

        let withdrawn = Task { try await registry.prompt(runtimeID: id, text: "ask") }
        guard case let .elicitationRequested(_, secondID, _)? = await events.next() else { return XCTFail("A second question") }
        try await registry.cancelPrompt(runtimeID: id)
        guard case .elicitationClosed(id, secondID)? = await events.next() else { return XCTFail("The question withdrawn") }
        let secondStop = try await withdrawn.value.stopReason
        XCTAssertEqual(secondStop, "cancelled")
        await registry.stopAll()
    }

    func testEvictsRuntimeAfterProcessTermination() async throws {
        let registry = AgentRuntimeRegistry()
        let id = AgentRuntimeID("terminating")
        let script = #"""
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
        sleep 0.1
        exit 7
        """#
        let configuration = ACPProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        _ = try await registry.start(
            id: id,
            configuration: configuration,
            clientInfo: clientInfo
        )
        var events = registry.events.makeAsyncIterator()
        let event = await events.next()

        XCTAssertEqual(event, .processTerminated(runtimeID: id, status: 7))
        let encodedEvent = try JSONEncoder().encode(event)
        XCTAssertEqual(
            try JSONDecoder().decode(LatchAgentEvent.self, from: encodedEvent),
            event
        )
        let runtimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(runtimeIDs, [])
        do {
            _ = try await registry.runtime(for: id)
            XCTFail("Expected terminated runtime to be evicted")
        } catch let error as AgentRuntimeRegistryError {
            XCTAssertEqual(error, .runtimeNotFound(id))
        }
    }

    func testRejectsDuplicateRuntimeID() async throws {
        let registry = AgentRuntimeRegistry()
        let id = AgentRuntimeID("duplicate")
        _ = try await registry.start(
            id: id,
            configuration: mockConfiguration(),
            clientInfo: clientInfo
        )

        do {
            _ = try await registry.start(
                id: id,
                configuration: mockConfiguration(),
                clientInfo: clientInfo
            )
            XCTFail("Expected duplicate runtime ID to be rejected")
        } catch let error as AgentRuntimeRegistryError {
            XCTAssertEqual(error, .duplicateRuntime(id))
        }

        await registry.stopAll()
    }

    func testFailedStartReleasesReservedID() async throws {
        let registry = AgentRuntimeRegistry()
        let id = AgentRuntimeID("retry")
        let invalidConfiguration = ACPProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/path/that/does/not/exist"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        do {
            _ = try await registry.start(
                id: id,
                configuration: invalidConfiguration,
                clientInfo: clientInfo
            )
            XCTFail("Expected process launch to fail")
        } catch {
            // The process error is platform-specific; only registry recovery matters here.
        }

        let initialRuntimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(initialRuntimeIDs, [])
        _ = try await registry.start(
            id: id,
            configuration: mockConfiguration(),
            clientInfo: clientInfo
        )
        let recoveredRuntimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(recoveredRuntimeIDs, [id])
        await registry.stopAll()
    }

    private var clientInfo: ACPImplementation {
        ACPImplementation(name: "latch-agent-core-tests", version: "0.1.0")
    }

    private func sessionConfiguration() -> ACPProcessConfiguration {
        let script = #"""
        while IFS= read -r line; do
          case "$line" in
            *\"method\":\"initialize\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
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
        return ACPProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
    }

    private func mockConfiguration() -> ACPProcessConfiguration {
        let script = #"""
        while IFS= read -r line; do
          case "$line" in
            *\"method\":\"initialize\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
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
