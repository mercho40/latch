import Foundation
import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest

enum Sample {
    static let runtimeID = AgentRuntimeID("rt-1")
    static let turnID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let requestID = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let frameID = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    /// `latch_` and the bytes 0...31.
    static let token = "latch_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    static let initialization = ACPInitializeResponse(
        protocolVersion: 1,
        agentCapabilities: ACPAgentCapabilities(loadSession: true, promptCapabilities: .object(["image": .bool(true)])),
        agentInfo: ACPImplementation(name: "mock-agent", version: "1.0.0")
    )
    static let newSession = ACPNewSessionResponse(
        sessionId: "session-1",
        modes: .object(["currentModeId": .string("ask")]),
        localSequence: 2
    )
    static let loadSession = ACPLoadSessionResponse(models: .object(["currentModelId": .string("model-b")]), localSequence: 9)
    static let configOptions: [ACPJSONValue] = [.object(["id": .string("effort"), "currentValue": .string("high")])]
    static let notification = ACPSessionNotification(
        sessionId: "session-1",
        update: .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("a/b")]),
        ]),
        localSequence: 5
    )
    static let modeNotification = ACPSessionNotification(
        sessionId: "session-1",
        update: .object(["sessionUpdate": .string("current_mode_update"), "currentModeId": .string("code")]),
        localSequence: 6
    )
    static let permission = ACPPermissionRequest(
        sessionId: "session-1",
        toolCall: .object(["toolCallId": .string("call-1"), "title": .string("Read file")]),
        options: [ACPPermissionOption(optionId: "allow-once", name: "Allow", kind: "allow_once")]
    )
    static let configurationSet = LatchRemoteConfigurationSet(
        route: .config, configID: "effort", value: "high", acpSequence: 7, configOptions: configOptions
    )

    static let record = LatchRemoteRuntimeRecord(
        runtimeID: runtimeID,
        agent: .preset("claudeCode"),
        agentTitle: "Claude Code",
        workspace: "/home/me/project",
        lifecycle: .ready,
        initialization: initialization,
        sessionID: "session-1",
        session: .new(newSession),
        state: [modeNotification],
        configurationSets: [configurationSet],
        activeTurnID: turnID,
        turns: [LatchRemoteTurnRecord(turnID: turnID, state: .running)],
        pendingPermissions: [LatchRemotePendingPermission(requestID: requestID, request: permission)],
        lastSequence: 12
    )

    static let exitedRecord = LatchRemoteRuntimeRecord(
        runtimeID: runtimeID,
        agent: .custom("my-agent --acp"),
        agentTitle: "my-agent",
        workspace: "/srv/work",
        lifecycle: .exited,
        exit: LatchRemoteExit(status: 3, stopped: false),
        sessionID: "session-2",
        session: .load(loadSession),
        turns: [LatchRemoteTurnRecord(
            turnID: turnID, state: .ended, error: LatchRemoteError(code: .runtimeExited, message: "The agent exited.")
        )],
        lastSequence: 40,
        loadedThrough: 9
    )
}

func encodedString<Value: Encodable>(_ value: Value, file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let data = try LatchRemoteCoding.encodeLine(value)
    XCTAssertEqual(data.last, 0x0A, file: file, line: line)
    return String(decoding: data.dropLast(), as: UTF8.self)
}

func decoded<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    try LatchRemoteCoding.decode(type, fromLine: Data(json.utf8))
}

/// Encoding `value` yields exactly `fixture`, and decoding `fixture` yields `value`.
func assertGolden<Value: Codable & Equatable>(
    _ value: Value,
    _ fixture: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(try encodedString(value, file: file, line: line), fixture, file: file, line: line)
    XCTAssertEqual(try decoded(Value.self, fixture), value, file: file, line: line)
}
