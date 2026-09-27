import Foundation
import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import Synchronization
import XCTest

/// A server as the session screen sees it, scripted by a test: it launches at once (or when
/// released), holds each prompt until the test ends the turn, and records every prompt and
/// command. Events reach the model as a remote channel's would.
final class ScriptedSessionClient: AgentServiceClient {
    let events: AsyncStream<LatchAgentEvent>
    let remoteEvents: AsyncStream<RemoteServiceEvent>?
    private let local: AsyncStream<LatchAgentEvent>.Continuation
    private let remote: AsyncStream<RemoteServiceEvent>.Continuation
    let transportDescription = "scripted session client"
    var isRemote: Bool { true }

    let acceptsImages: Bool
    let configOptions: [ACPJSONValue]?
    static let sessionID = "scripted-session"

    private struct State {
        var runtimeID: AgentRuntimeID?
        var prompts: [[ACPPromptBlock]] = []
        var commands: [LatchAgentCommand] = []
        var turn: CheckedContinuation<LatchAgentResponse, any Error>?
        var holdLaunch = false
        var launchWaiter: CheckedContinuation<Void, Never>?
        var launchFailure: (any Error & Sendable)?
    }
    private let state = Mutex(State())

    init(acceptsImages: Bool = true, configOptions: [ACPJSONValue]? = nil, holdLaunch: Bool = false) {
        self.acceptsImages = acceptsImages
        self.configOptions = configOptions
        (events, local) = AsyncStream.makeStream()
        let (stream, continuation) = AsyncStream<RemoteServiceEvent>.makeStream()
        remoteEvents = stream
        remote = continuation
        state.withLock { $0.holdLaunch = holdLaunch }
    }

    var prompts: [[ACPPromptBlock]] { state.withLock { $0.prompts } }
    var commands: [LatchAgentCommand] { state.withLock { $0.commands } }
    var runtimeID: AgentRuntimeID? { state.withLock { $0.runtimeID } }

    func failNextLaunch(with error: any Error & Sendable) {
        state.withLock { $0.launchFailure = error }
    }

    func releaseLaunch() {
        let waiter = state.withLock { state in
            state.holdLaunch = false
            defer { state.launchWaiter = nil }
            return state.launchWaiter
        }
        waiter?.resume()
    }

    func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        state.withLock { $0.runtimeID = id }
        await withCheckedContinuation { continuation in
            let waiting = state.withLock { state in
                guard state.holdLaunch else { return false }
                state.launchWaiter = continuation
                return true
            }
            if !waiting { continuation.resume() }
        }
        if let failure = state.withLock({ state in defer { state.launchFailure = nil }; return state.launchFailure }) {
            throw failure
        }
        return .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(
            protocolVersion: 1,
            agentCapabilities: ACPAgentCapabilities(loadSession: true, promptCapabilities: .object(["image": .bool(acceptsImages)])),
            agentInfo: ACPImplementation(name: "claude-code", title: "Claude Code", version: "1.0")))
    }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        state.withLock { $0.commands.append(command) }
        switch command {
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: Self.sessionID, configOptions: configOptions))
        case let .loadSession(id, _, _):
            return .sessionLoaded(runtimeID: id, response: ACPLoadSessionResponse(configOptions: configOptions))
        case let .setSessionConfigOption(id, configID, value):
            let options = (configOptions ?? []).map { option -> ACPJSONValue in
                guard case var .object(fields) = option, fields["id"] == .string(configID) else { return option }
                fields["currentValue"] = .string(value)
                return .object(fields)
            }
            return .sessionConfigOptionSet(runtimeID: id, response: ACPSetSessionConfigOptionResponse(configOptions: options))
        case let .resolvePermission(id, requestID, _):
            return .permissionResolved(runtimeID: id, requestID: requestID)
        case let .cancelPrompt(id):
            endTurn(stopReason: "cancelled")
            return .promptCancellationRequested(runtimeID: id)
        case let .stopRuntime(id):
            return .runtimeStopped(runtimeID: id)
        default:
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected command")
        }
    }

    func prompt(runtimeID: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock]) async throws -> LatchAgentResponse {
        state.withLock { $0.prompts.append(blocks) }
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.turn = continuation }
        }
    }

    func endTurn(stopReason: String = "end_turn") {
        guard let id = runtimeID, let turn = state.withLock({ state in defer { state.turn = nil }; return state.turn }) else { return }
        turn.resume(returning: .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: stopReason)))
    }

    func failTurn(_ error: any Error) {
        guard let turn = state.withLock({ state in defer { state.turn = nil }; return state.turn }) else { return }
        turn.resume(throwing: error)
    }

    var hasOpenTurn: Bool { state.withLock { $0.turn != nil } }

    // MARK: Events

    func emit(_ event: RemoteServiceEvent) { remote.yield(event) }

    private func update(_ fields: [String: ACPJSONValue]) {
        guard let id = runtimeID else { return }
        emit(.agent(.sessionUpdate(runtimeID: id, notification: ACPSessionNotification(
            sessionId: Self.sessionID, update: .object(fields))), sequence: nil))
    }

    func chunk(_ text: String) {
        update(["sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)])])
    }

    func tool(_ id: String, title: String, status: String, content: String? = nil) {
        var fields: [String: ACPJSONValue] = ["sessionUpdate": .string("tool_call"), "toolCallId": .string(id),
                                              "title": .string(title), "status": .string(status)]
        if let content {
            fields["content"] = .array([.object(["type": .string("content"),
                                                 "content": .object(["type": .string("text"), "text": .string(content)])])])
        }
        update(fields)
    }

    func availableCommands(_ commands: [(String, String)]) {
        update(["sessionUpdate": .string("available_commands_update"),
                "availableCommands": .array(commands.map { .object(["name": .string($0.0), "description": .string($0.1)]) })])
    }

    @discardableResult
    func requestPermission(title: String, options: [ACPPermissionOption] = ScriptedSessionClient.standardOptions,
                           command: String = "rm -rf build") -> UUID {
        let request = UUID()
        guard let id = runtimeID else { return request }
        emit(.agent(.permissionRequested(runtimeID: id, requestID: request, request: ACPPermissionRequest(
            sessionId: Self.sessionID,
            toolCall: .object(["toolCallId": .string("call-1"), "title": .string(title), "kind": .string("execute"),
                               "rawInput": .object(["command": .string(command)])]),
            options: options)), sequence: nil))
        return request
    }

    func closePermission(_ request: UUID) {
        guard let id = runtimeID else { return }
        emit(.agent(.permissionClosed(runtimeID: id, requestID: request), sequence: nil))
    }

    static let standardOptions = [
        ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once"),
        ACPPermissionOption(optionId: "always", name: "Always", kind: "allow_always"),
        ACPPermissionOption(optionId: "reject", name: "Reject", kind: "reject_once"),
    ]

    func close() {
        local.finish()
        remote.finish()
    }
}

extension XCTestCase {
    /// Waits for main-actor state that arrives through the model's event task.
    @MainActor
    func waitUntil(_ description: String = "condition", timeout: Duration = .seconds(5),
                   file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Config options an agent advertises: grouped models, an effort, and a permission mode.
enum ScriptedConfiguration {
    static let options: [ACPJSONValue] = [
        .object(["id": .string("model"), "name": .string("Model"), "category": .string("model"), "type": .string("select"),
                 "currentValue": .string("sonnet"),
                 "options": .array([
                    .object(["group": .string("claude"), "name": .string("Claude"), "options": .array([
                        .object(["value": .string("sonnet"), "name": .string("Sonnet"), "description": .string("Fast and capable")]),
                        .object(["value": .string("opus"), "name": .string("Opus"), "description": .string("Most capable")]),
                    ])]),
                 ])]),
        .object(["id": .string("effort"), "name": .string("Effort"), "category": .string("thought_level"), "type": .string("select"),
                 "currentValue": .string("medium"),
                 "options": .array([
                    .object(["value": .string("low"), "name": .string("Low")]),
                    .object(["value": .string("medium"), "name": .string("Medium")]),
                    .object(["value": .string("high"), "name": .string("High")]),
                 ])]),
        .object(["id": .string("mode"), "name": .string("Mode"), "category": .string("mode"), "type": .string("select"),
                 "currentValue": .string("default"),
                 "options": .array([
                    .object(["value": .string("default"), "name": .string("Ask First"), "description": .string("Asks before editing")]),
                    .object(["value": .string("acceptEdits"), "name": .string("Accept Edits")]),
                 ])]),
    ]
}

/// A server that could not be reached, as a remote channel reports one.
struct UnreachableServer: RemoteConnectionFailure, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
