#if DEBUG
import Foundation
import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import Synchronization

/// A server as the session screen sees it, scripted by a test or a `--ui-fixture` screen: it
/// launches at once (or when released), holds each prompt until the script ends the turn, and
/// records every prompt and command. Events reach the model as a remote channel's would.
/// Debug builds only.
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

    /// What Claude Code adds to an update: the subagent's call it belongs to, the tool's own
    /// name, and whether the call runs a subagent.
    private static func meta(parent: String?, toolName: String? = nil, subagent: Bool = false) -> ACPJSONValue? {
        var fields: [String: ACPJSONValue] = [:]
        if let parent { fields["parentToolUseId"] = .string(parent) }
        if let toolName { fields["toolName"] = .string(toolName) }
        if subagent { fields["subagent"] = .bool(true) }
        return fields.isEmpty ? nil : .object(["claudeCode": .object(fields)])
    }

    /// The agent's words, or with `parent` a subagent's, under that call.
    func chunk(_ text: String, parent: String? = nil) {
        var fields: [String: ACPJSONValue] = ["sessionUpdate": .string("agent_message_chunk"),
                                              "content": .object(["type": .string("text"), "text": .string(text)])]
        fields["_meta"] = Self.meta(parent: parent)
        update(fields)
    }

    /// What the agent, or with `parent` a subagent, thought.
    func thought(_ text: String, parent: String? = nil) {
        var fields: [String: ACPJSONValue] = ["sessionUpdate": .string("agent_thought_chunk"),
                                              "content": .object(["type": .string("text"), "text": .string(text)])]
        fields["_meta"] = Self.meta(parent: parent)
        update(fields)
    }

    /// A tool call, or an update to one. With `subagent` the call runs a subagent; with
    /// `parent` a subagent made it.
    func tool(_ id: String, title: String, status: String, content: String? = nil, kind: String? = nil,
              toolName: String? = nil, subagent: Bool = false, parent: String? = nil) {
        var fields: [String: ACPJSONValue] = ["sessionUpdate": .string("tool_call"), "toolCallId": .string(id),
                                              "title": .string(title), "status": .string(status)]
        if let content {
            fields["content"] = .array([.object(["type": .string("content"),
                                                 "content": .object(["type": .string("text"), "text": .string(content)])])])
        }
        if let kind { fields["kind"] = .string(kind) }
        fields["_meta"] = Self.meta(parent: parent, toolName: toolName, subagent: subagent)
        update(fields)
    }

    /// The agent's plan, whole: each step's words and `pending`, `in_progress` or `completed`.
    func plan(_ steps: [(String, String)]) {
        update(["sessionUpdate": .string("plan"),
                "entries": .array(steps.map { .object(["content": .string($0.0), "status": .string($0.1),
                                                        "priority": .string("medium")]) })])
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

/// A conversation about a flaky test: a prompt, two tool calls, a reply in rich Markdown, and a
/// prompt with a photo. What the tests and the `--ui-fixture` screens show.
enum SampleConversation {
    static let prompt = ChatMessage(role: .user, text: "The reconnect test fails about one run in five on the Linux runner. Can you find out why?")
    static let read = ChatMessage(role: .tool, text: """
        Read Tests/RemoteSessionLiveTests.swift · completed

        Content:
        func testReconnect() async throws {
            let server = try await LoopbackServer.start()
            try await server.restart()
        }
        """)
    static let run = ChatMessage(role: .tool, text: """
        `swift test --filter RemoteSessionLiveTests/testReconnectAfterServerRestart` · failed

        rawOutput (text):
        error: testReconnect: timed out after 5.0 seconds
        """)
    static let answer = ChatMessage(role: .assistant, text: """
        ## What I found

        The test restarts the loopback server and reconnects **before the old port is released**. On Linux the port stays in `TIME_WAIT`, so:

        1. The restart binds a *new* port.
        2. The client still dials the old one:
           - it retries with backoff,
           - and gives up after 5 s.

        ```swift
        let port = try await server.restart(keepingPort: true)
        ```

        | Runner | Runs | Failures |
        | :-- | --: | --: |
        | macOS | 50 | 0 |
        | Linux | 50 | 9 |

        > The Mac never shows it: it sets `SO_REUSEADDR` by default.

        See [SO_REUSEADDR](https://man7.org/linux/man-pages/man7/socket.7.html) for the details.
        """)
    static let followUp = ChatMessage(role: .user, text: "Here is the CI log from the last failure.",
                                      attachments: [ChatAttachment(kind: .image, name: "ci-log.jpg", path: nil)])

    static let messages = [prompt, read, run, answer, followUp]
}

/// A turn that thought first, then ran two subagents side by side, whose rows arrived
/// interleaved: one has finished, the other is still reading. With the plan the agent keeps.
enum SampleSubagents {
    static let prompt = ChatMessage(role: .user, text: "Find out why the reconnect test is flaky, and fix it.")
    static let thought = ChatMessage(role: .thought, text: """
        **Splitting the work**

        The failure is either in the server's restart or in the client's backoff. I'll send one agent \
        through each and compare what they find before changing anything.
        """)
    static let server = ChatMessage(role: .tool, text: """
        Read the server's restart path · completed

        Input:
        {
          "description": "Read the server's restart path",
          "subagent_type": "Explore"
        }
        """, tool: ToolSummary(callID: "server", kind: "think", status: "completed", toolName: "Agent", runsSubagent: true))
    static let client = ChatMessage(role: .tool, text: "Read the client's reconnect backoff · in_progress",
                                    tool: ToolSummary(callID: "client", kind: "think", status: "in_progress", toolName: "Agent",
                                                      runsSubagent: true))
    static let serverRead = ChatMessage(role: .tool, text: "Read Sources/LatchAgentServer/RemoteServer.swift · completed",
                                        tool: ToolSummary(callID: "s1", kind: "read", status: "completed", toolName: "Read"),
                                        parentID: server.id)
    static let clientSearch = ChatMessage(role: .tool, text: "grep -n backoff Sources/LatchRemoteClient · completed",
                                          tool: ToolSummary(callID: "c1", kind: "search", status: "completed", toolName: "Grep"),
                                          parentID: client.id)
    static let serverThought = ChatMessage(role: .thought, text: """
        The restart closes the listener and binds again without SO_REUSEADDR, so on Linux the old port \
        sits in TIME_WAIT.
        """, parentID: server.id)
    static let serverRun = ChatMessage(role: .tool, text: """
        `swift test --filter RemoteServerTests` · completed

        Output:
        Test Suite 'RemoteServerTests' passed.
        """, tool: ToolSummary(callID: "s2", kind: "execute", status: "completed", toolName: "Bash"), parentID: server.id)
    static let clientRead = ChatMessage(role: .tool, text: "Read Sources/LatchRemoteClient/Backoff.swift · in_progress",
                                        tool: ToolSummary(callID: "c2", kind: "read", status: "in_progress", toolName: "Read"),
                                        parentID: client.id)
    static let serverWords = ChatMessage(role: .assistant, text: """
        The listener is bound again on a **new** port after a restart, because the old one is still in \
        `TIME_WAIT`. Setting `SO_REUSEADDR` before `bind` keeps it.
        """, parentID: server.id)

    /// In the order they arrived.
    static let messages = [prompt, thought, server, client, serverRead, clientSearch, serverThought, serverRun,
                           clientRead, serverWords]

    static let plan: [(String, String)] = [
        ("Read the server's restart path", "completed"),
        ("Read the client's reconnect backoff", "in_progress"),
        ("Keep the port across a restart", "pending"),
        ("Run the reconnect test fifty times", "pending"),
    ]
}
#endif
