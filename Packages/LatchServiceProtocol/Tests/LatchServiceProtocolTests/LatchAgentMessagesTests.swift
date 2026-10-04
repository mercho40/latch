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
            .prompt(runtimeID: id, blocks: [
                .image(data: Data(repeating: 7, count: 64), mimeType: "image/png"),
                .resourceLink(uri: "file:///tmp/project/notes.txt", name: "notes.txt", mimeType: "text/plain"),
                .text("What is in these?"),
            ]),
            .cancelPrompt(runtimeID: id),
            .setSessionConfigOption(runtimeID: id, configID: "effort", value: "high"),
            .setSessionModel(runtimeID: id, modelID: "model-b"),
            .setSessionMode(runtimeID: id, modeID: "ask"),
            .resolvePermission(runtimeID: id, requestID: UUID(), outcome: .selected(optionID: "allow-once")),
            .resolvePermission(runtimeID: id, requestID: UUID(), outcome: .cancelled),
            .resolveElicitation(runtimeID: id, requestID: UUID(), response: ACPElicitationResponse(
                action: .accept, content: ["question_0": .string("SQLite"), "question_1": .array([.string("a"), .string("b")])]
            )),
            .resolveElicitation(runtimeID: id, requestID: UUID(), response: .cancelled),
        ]

        for command in commands {
            try assertJSONRoundTrip(command)
        }
    }

    /// A resized screenshot is up to about a megabyte, and base64 grows it by a third; several
    /// of them in one prompt must still cross the service boundary.
    func testAPromptWithSeveralImagesFitsTheCodec() throws {
        let image = ACPPromptBlock.image(data: Data(repeating: 1, count: 1_000_000), mimeType: "image/png")
        let command = LatchAgentCommand.prompt(runtimeID: AgentRuntimeID("runtime-1"), blocks: Array(repeating: image, count: 4))
        let codec = LatchServiceCodec()
        XCTAssertEqual(try codec.decode(LatchAgentCommand.self, from: try codec.encode(command)), command)
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
            .elicitationResolved(runtimeID: id, requestID: UUID()),
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
            .elicitationRequested(runtimeID: id, requestID: UUID(), request: ACPElicitationRequest(
                sessionId: "session-1", message: "Which?",
                requestedSchema: .object(["type": .string("object"), "properties": .object([:])]), toolCallId: "call-2",
                meta: .object(["k": .string("v")])
            )),
            .elicitationClosed(runtimeID: id, requestID: UUID()),
        ]

        for event in events {
            try assertJSONRoundTrip(event)
        }
    }

    func testDecodingRejectsAnEmptyRuntimeID() throws {
        let id = AgentRuntimeID("runtime-1")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(id), as: UTF8.self), #"{"rawValue":"runtime-1"}"#)
        XCTAssertEqual(try JSONDecoder().decode(AgentRuntimeID.self, from: Data(#"{"rawValue":"runtime-1"}"#.utf8)), id)

        XCTAssertThrowsError(try JSONDecoder().decode(AgentRuntimeID.self, from: Data(#"{"rawValue":""}"#.utf8))) {
            guard case DecodingError.dataCorrupted = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        // A command carrying one fails to decode as a whole rather than trapping.
        var command = String(decoding: try JSONEncoder().encode(LatchAgentCommand.stopRuntime(id: id)), as: UTF8.self)
        command = command.replacingOccurrences(of: #""runtime-1""#, with: #""""#)
        XCTAssertThrowsError(try JSONDecoder().decode(LatchAgentCommand.self, from: Data(command.utf8)))
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
