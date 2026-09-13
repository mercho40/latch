import Foundation
import LatchACP
import XCTest
@testable import LatchServiceProtocol

final class LatchAgentMessagesTests: XCTestCase {
    func testCommandsRoundTripThroughJSON() throws {
        let id = AgentRuntimeID("runtime-1")
        let profile = ACPCommandProfile(
            executablePath: "/usr/bin/env",
            arguments: ["fx", "acp"],
            workingDirectoryPath: "/tmp/project",
            environment: ["MODE": "read-only"]
        )
        let commands: [LatchAgentCommand] = [
            .listRuntimes,
            .startRuntime(id: id, profile: profile),
            .stopRuntime(id: id),
            .newSession(runtimeID: id, cwd: "/tmp/project"),
            .prompt(runtimeID: id, text: "Hello"),
            .cancelPrompt(runtimeID: id),
            .setSessionConfigOption(runtimeID: id, configID: "effort", value: "high"),
            .setSessionModel(runtimeID: id, modelID: "model-b"),
            .setSessionMode(runtimeID: id, modeID: "ask"),
            .resolvePermission(runtimeID: id, requestID: UUID(), outcome: .selected(optionID: "allow-once")),
            .resolvePermission(runtimeID: id, requestID: UUID(), outcome: .cancelled),
        ]

        for command in commands {
            try assertJSONRoundTrip(command)
        }
    }

    func testResponsesRoundTripThroughJSON() throws {
        let id = AgentRuntimeID("runtime-1")
        let responses: [LatchAgentResponse] = [
            .runtimeList([AgentRuntimeSnapshot(id: id, state: .ready)]),
            .runtimeStarted(
                runtimeID: id,
                initialization: ACPInitializeResponse(
                    protocolVersion: 1,
                    agentCapabilities: ACPAgentCapabilities(loadSession: true),
                    agentInfo: ACPImplementation(name: "mock-agent", version: "1.0.0")
                )
            ),
            .runtimeStopped(runtimeID: id),
            .sessionCreated(
                runtimeID: id,
                session: ACPNewSessionResponse(sessionId: "session-1", localSequence: 2)
            ),
            .promptCompleted(
                runtimeID: id,
                response: ACPPromptResponse(stopReason: "end_turn")
            ),
            .promptCancellationRequested(runtimeID: id),
            .sessionConfigOptionSet(
                runtimeID: id,
                response: ACPSetSessionConfigOptionResponse(configOptions: [
                    .object(["id": .string("effort"), "currentValue": .string("high")]),
                ], localSequence: 3)
            ),
            .sessionModelSet(runtimeID: id, sequence: 4),
            .sessionModeSet(runtimeID: id, sequence: 5),
            .permissionResolved(runtimeID: id, requestID: UUID()),
        ]

        for response in responses {
            try assertJSONRoundTrip(response)
        }
    }

    func testEventsRoundTripThroughJSON() throws {
        let id = AgentRuntimeID("runtime-1")
        let notification = ACPSessionNotification(
            sessionId: "session-1",
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("hello"),
                ]),
            ]),
            localSequence: 5
        )
        let events: [LatchAgentEvent] = [
            .sessionUpdate(runtimeID: id, notification: notification),
            .standardError(runtimeID: id, data: Data("diagnostic".utf8)),
            .processTerminated(runtimeID: id, status: 7),
            .permissionRequested(runtimeID: id, requestID: UUID(), request: ACPPermissionRequest(
                sessionId: "session-1",
                toolCall: .object(["toolCallId": .string("call-1"), "title": .string("Read file")]),
                options: [ACPPermissionOption(optionId: "allow-once", name: "Allow", kind: "allow_once")]
            )),
            .permissionClosed(runtimeID: id, requestID: UUID()),
        ]

        for event in events {
            try assertJSONRoundTrip(event)
        }
    }

    func testCommandProfileCreatesProcessConfiguration() {
        let profile = ACPCommandProfile(
            executablePath: "/usr/bin/env",
            arguments: ["fx", "acp"],
            workingDirectoryPath: "/tmp/project",
            environment: ["MODE": "read-only"]
        )

        XCTAssertEqual(
            profile.processConfiguration,
            ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["fx", "acp"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp/project"),
                environment: ["MODE": "read-only"]
            )
        )
    }

    private func assertJSONRoundTrip<Value: Codable & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(Value.self, from: data), value)
    }
}
