import Foundation
import LatchACP
import LatchServiceProtocol
import XCTest
@testable import LatchAgentCore

final class LatchAgentServiceTests: XCTestCase {
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
