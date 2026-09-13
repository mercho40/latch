import Foundation
import LatchACP
import LatchServiceProtocol
import XCTest
@testable import LatchAgentCore

final class LatchAgentServiceTests: XCTestCase {
    func testHandleRejectedPromptUsesOnlyAgentDisplayMessage() async throws {
        let service = LatchAgentService()
        let id = AgentRuntimeID("rejected-prompt")
        let script = sessionServerScript.replacingOccurrences(
            of: #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"working"}}}}"#,
            with: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"Internal error","data":{"message":"Please sign in. token=private-token","stderr":"private-stderr","path":"/private/native-path"}}}"#
        )
        _ = try await service.execute(.startRuntime(id: id, profile: ACPCommandProfile(
            executablePath: "/bin/sh", arguments: ["-c", script], workingDirectoryPath: "/tmp"
        )))
        _ = try await service.execute(.newSession(runtimeID: id, cwd: "/tmp"))
        let request = LatchAgentRequest(command: .prompt(runtimeID: id, text: "go"))
        let reply = await service.handle(request)
        await service.shutdown()
        XCTAssertEqual(reply, LatchAgentReply(requestID: request.requestID, result: .failure(
            LatchAgentFailure(code: .commandFailed, message: "Agent reported: Please sign in. [redacted]")
        )))
    }

    func testNativeLaunchFailureRemainsGeneric() async {
        let service = LatchAgentService()
        let request = LatchAgentRequest(command: .startRuntime(
            id: AgentRuntimeID("invalid"),
            profile: ACPCommandProfile(executablePath: "/nonexistent/private-secret/executable", workingDirectoryPath: "/tmp")
        ))
        let reply = await service.handle(request)
        await service.shutdown()
        XCTAssertEqual(reply, LatchAgentReply(requestID: request.requestID, result: .failure(
            LatchAgentFailure(code: .commandFailed, message: "Agent command failed.")
        )))
    }

    func testHandlesVersionedRequestsAndSanitizesFailures() async {
        let service = LatchAgentService()
        let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let listReply = await service.handle(LatchAgentRequest(
            requestID: requestID,
            command: .listRuntimes
        ))
        XCTAssertEqual(
            listReply,
            LatchAgentReply(requestID: requestID, result: .success(.runtimeList([])))
        )

        let unsupportedReply = await service.handle(LatchAgentRequest(
            protocolVersion: LatchServiceProtocolVersion.current + 1,
            requestID: requestID,
            command: .listRuntimes
        ))
        XCTAssertEqual(
            unsupportedReply,
            LatchAgentReply(
                requestID: requestID,
                result: .failure(LatchAgentFailure(
                    code: .unsupportedProtocolVersion,
                    message: "Unsupported service protocol version."
                ))
            )
        )

        let missingRuntimeReply = await service.handle(LatchAgentRequest(
            requestID: requestID,
            command: .stopRuntime(id: AgentRuntimeID("missing"))
        ))
        XCTAssertEqual(
            missingRuntimeReply,
            LatchAgentReply(
                requestID: requestID,
                result: .failure(LatchAgentFailure(
                    code: .commandFailed,
                    message: "Runtime not found."
                ))
            )
        )
    }

    func testDispatchesCompleteCancelledPromptLifecycle() async throws {
        let service = LatchAgentService()
        let runtimeID = AgentRuntimeID("service-runtime")
        let profile = ACPCommandProfile(
            executablePath: "/bin/sh",
            arguments: ["-c", sessionServerScript],
            workingDirectoryPath: "/tmp"
        )
        var events = service.events.makeAsyncIterator()

        let initialList = try await service.execute(.listRuntimes)
        XCTAssertEqual(initialList, .runtimeList([]))

        let start = try await service.execute(.startRuntime(id: runtimeID, profile: profile))
        guard case let .runtimeStarted(startedID, initialization) = start else {
            return XCTFail("Expected a runtime-started response")
        }
        XCTAssertEqual(startedID, runtimeID)
        XCTAssertEqual(initialization.agentInfo?.name, "mock-agent")

        let readyList = try await service.execute(.listRuntimes)
        XCTAssertEqual(
            readyList,
            .runtimeList([AgentRuntimeSnapshot(id: runtimeID, state: .ready)])
        )

        let newSession = try await service.execute(
            .newSession(runtimeID: runtimeID, cwd: "/tmp/project")
        )
        XCTAssertEqual(
            newSession,
            .sessionCreated(
                runtimeID: runtimeID,
                session: ACPNewSessionResponse(sessionId: "session-1", localSequence: 2)
            )
        )

        let configRequest = LatchAgentRequest(command: .setSessionConfigOption(
            runtimeID: runtimeID, configID: "effort", value: "high"
        ))
        let configReply = await service.handle(configRequest)
        XCTAssertEqual(configReply, LatchAgentReply(
            requestID: configRequest.requestID,
            result: .success(.sessionConfigOptionSet(
                runtimeID: runtimeID,
                response: ACPSetSessionConfigOptionResponse(configOptions: [
                    .object(["id": .string("effort"), "currentValue": .string("high")]),
                ], localSequence: 3)
            ))
        ))
        let modelRequest = LatchAgentRequest(command: .setSessionModel(
            runtimeID: runtimeID, modelID: "model-b"
        ))
        let modelReply = await service.handle(modelRequest)
        XCTAssertEqual(modelReply, LatchAgentReply(
            requestID: modelRequest.requestID,
            result: .success(.sessionModelSet(runtimeID: runtimeID, sequence: 4))
        ))

        let promptTask = Task {
            try await service.execute(.prompt(runtimeID: runtimeID, text: "Keep working"))
        }
        let event = await events.next()
        guard case let .sessionUpdate(eventRuntimeID, notification)? = event else {
            return XCTFail("Expected a streamed session update")
        }
        XCTAssertEqual(eventRuntimeID, runtimeID)
        XCTAssertEqual(notification.localSequence, 5)
        guard case let .messageChunk(chunk) = notification.event else {
            return XCTFail("Expected an agent message chunk")
        }
        XCTAssertEqual(chunk.text, "working")

        let cancellation = try await service.execute(.cancelPrompt(runtimeID: runtimeID))
        XCTAssertEqual(cancellation, .promptCancellationRequested(runtimeID: runtimeID))
        let prompt = try await promptTask.value
        XCTAssertEqual(
            prompt,
            .promptCompleted(
                runtimeID: runtimeID,
                response: ACPPromptResponse(stopReason: "cancelled")
            )
        )

        let stop = try await service.execute(.stopRuntime(id: runtimeID))
        XCTAssertEqual(stop, .runtimeStopped(runtimeID: runtimeID))
        let finalList = try await service.execute(.listRuntimes)
        XCTAssertEqual(finalList, .runtimeList([]))
    }

    func testBrokersPermissionRequestsAsEventsAndCommands() async throws {
        let service = LatchAgentService()
        let runtimeID = AgentRuntimeID("permission-runtime")
        var events = service.events.makeAsyncIterator()
        _ = try await service.execute(.startRuntime(id: runtimeID, profile: ACPCommandProfile(
            executablePath: "/bin/sh", arguments: ["-c", permissionServerScript], workingDirectoryPath: "/tmp"
        )))
        _ = try await service.execute(.newSession(runtimeID: runtimeID, cwd: "/tmp/project"))

        let promptTask = Task { try await service.execute(.prompt(runtimeID: runtimeID, text: "Read the file")) }
        guard case let .permissionRequested(eventRuntimeID, requestID, request)? = await events.next() else {
            return XCTFail("Expected a brokered permission request event")
        }
        XCTAssertEqual(eventRuntimeID, runtimeID)
        XCTAssertEqual(request.sessionId, "session-1")
        XCTAssertEqual(request.options.map(\.optionId), ["allow-once", "reject-once"])

        // Wrong runtime and unknown request IDs are rejected without touching the pending request.
        let wrongRuntime = await service.handle(LatchAgentRequest(command: .resolvePermission(
            runtimeID: AgentRuntimeID("other"), requestID: requestID, outcome: .selected(optionID: "allow-once")
        )))
        guard case .failure(let failure) = wrongRuntime.result else { return XCTFail("Expected a failure") }
        XCTAssertEqual(failure, LatchAgentFailure(code: .commandFailed, message: "Permission request not found."))

        let resolved = try await service.execute(.resolvePermission(
            runtimeID: runtimeID, requestID: requestID, outcome: .selected(optionID: "allow-once")
        ))
        XCTAssertEqual(resolved, .permissionResolved(runtimeID: runtimeID, requestID: requestID))
        guard case let .permissionClosed(closedRuntimeID, closedRequestID)? = await events.next() else {
            return XCTFail("Expected the permission to close")
        }
        XCTAssertEqual(closedRuntimeID, runtimeID)
        XCTAssertEqual(closedRequestID, requestID)
        let completed = try await promptTask.value
        XCTAssertEqual(completed, .promptCompleted(
            runtimeID: runtimeID, response: ACPPromptResponse(stopReason: "end_turn")
        ))

        // Closed requests cannot be answered twice.
        do {
            _ = try await service.execute(.resolvePermission(
                runtimeID: runtimeID, requestID: requestID, outcome: .cancelled
            ))
            XCTFail("Expected a second resolution to fail")
        } catch AgentRuntimeRegistryError.permissionRequestNotFound(let id) {
            XCTAssertEqual(id, requestID)
        }
        _ = try await service.execute(.stopRuntime(id: runtimeID))
    }

    func testCancellingPromptCancelsPendingPermission() async throws {
        let service = LatchAgentService()
        let runtimeID = AgentRuntimeID("permission-cancel-runtime")
        var events = service.events.makeAsyncIterator()
        _ = try await service.execute(.startRuntime(id: runtimeID, profile: ACPCommandProfile(
            executablePath: "/bin/sh", arguments: ["-c", permissionServerScript], workingDirectoryPath: "/tmp"
        )))
        _ = try await service.execute(.newSession(runtimeID: runtimeID, cwd: "/tmp/project"))

        let promptTask = Task { try await service.execute(.prompt(runtimeID: runtimeID, text: "Read the file")) }
        guard case let .permissionRequested(_, requestID, _)? = await events.next() else {
            return XCTFail("Expected a brokered permission request event")
        }
        _ = try await service.execute(.cancelPrompt(runtimeID: runtimeID))
        guard case let .permissionClosed(_, closedRequestID)? = await events.next() else {
            return XCTFail("Expected cancellation to close the pending permission")
        }
        XCTAssertEqual(closedRequestID, requestID)
        let completed = try await promptTask.value
        XCTAssertEqual(completed, .promptCompleted(
            runtimeID: runtimeID, response: ACPPromptResponse(stopReason: "cancelled")
        ))
        _ = try await service.execute(.stopRuntime(id: runtimeID))
    }

    func testStoppingRuntimeCancelsPendingPermission() async throws {
        let service = LatchAgentService()
        let runtimeID = AgentRuntimeID("permission-stop-runtime")
        var events = service.events.makeAsyncIterator()
        _ = try await service.execute(.startRuntime(id: runtimeID, profile: ACPCommandProfile(
            executablePath: "/bin/sh", arguments: ["-c", permissionServerScript], workingDirectoryPath: "/tmp"
        )))
        _ = try await service.execute(.newSession(runtimeID: runtimeID, cwd: "/tmp/project"))
        let promptTask = Task { try? await service.execute(.prompt(runtimeID: runtimeID, text: "Read the file")) }
        guard case let .permissionRequested(_, requestID, _)? = await events.next() else {
            return XCTFail("Expected a brokered permission request event")
        }
        _ = try await service.execute(.stopRuntime(id: runtimeID))
        guard case let .permissionClosed(_, closedRequestID)? = await events.next() else {
            return XCTFail("Expected stop to close the pending permission")
        }
        XCTAssertEqual(closedRequestID, requestID)
        _ = await promptTask.value
        let remaining = try await service.execute(.listRuntimes)
        XCTAssertEqual(remaining, .runtimeList([]))
    }

    /// Prompt (id 3) asks for permission (id 10); the reply to that request decides the stop reason.
    private var permissionServerScript: String {
        #"""
        while IFS= read -r line; do
          case "$line" in
            *\"method\":\"initialize\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
              ;;
            *\"method\":\"session*new\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
              ;;
            *\"method\":\"session*prompt\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":10,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"call-1","title":"Read file"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
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

    private var sessionServerScript: String {
        #"""
        while IFS= read -r line; do
          case "$line" in
            *\"method\":\"initialize\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
              ;;
            *\"method\":\"session*new\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
              ;;
            *\"method\":\"session*set_config_option\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"configOptions":[{"id":"effort","currentValue":"high"}]}}'
              ;;
            *\"method\":\"session*set_model\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{}}'
              ;;
            *\"method\":\"session*prompt\"*)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"working"}}}}'
              ;;
            *\"method\":\"session*cancel\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":5,"result":{"stopReason":"cancelled"}}'
              ;;
          esac
        done
        """#
    }
}
