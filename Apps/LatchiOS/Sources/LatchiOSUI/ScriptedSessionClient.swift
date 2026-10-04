#if DEBUG
import Foundation
import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import Synchronization

/// A server as the session screen sees it, scripted by a test or a `--ui-fixture` screen: it
/// launches at once (or when released), holds each prompt until the script ends the turn, and
/// records every prompt and command. It raises permission requests and asks questions when
/// told, and takes their answers. Events reach the model as a remote channel's would.
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
        case let .resolveElicitation(id, requestID, _):
            return .elicitationResolved(runtimeID: id, requestID: requestID)
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

    /// How much of its context the agent has used, and with `cost` what the conversation has
    /// cost so far, as Claude Code's `usage_update` says it.
    func usage(used: Int, size: Int, cost: Double? = nil) {
        var fields: [String: ACPJSONValue] = ["sessionUpdate": .string("usage_update"), "used": .integer(Int64(used)),
                                              "size": .integer(Int64(size))]
        if let cost { fields["cost"] = .object(["amount": .double(cost), "currency": .string("USD")]) }
        update(fields)
    }

    /// The agent's own title for the conversation, as Claude Code gives one after a turn.
    func title(_ title: String) {
        update(["sessionUpdate": .string("session_info_update"), "title": .string(title)])
    }

    func availableCommands(_ commands: [(String, String)]) {
        update(["sessionUpdate": .string("available_commands_update"),
                "availableCommands": .array(commands.map { .object(["name": .string($0.0), "description": .string($0.1)]) })])
    }

    /// A command to approve. With `heading` and `reason`, the agent's own words for what it
    /// asks and why, as Claude Code sends them beside the tool call.
    @discardableResult
    func requestPermission(title: String, options: [ACPPermissionOption] = ScriptedSessionClient.standardOptions,
                           command: String = "rm -rf build", heading: String? = nil, reason: String? = nil) -> UUID {
        var permission: [String: ACPJSONValue] = [:]
        if let heading { permission["title"] = .string(heading) }
        if let reason { permission["description"] = .string(reason) }
        return requestPermission(ACPPermissionRequest(
            sessionId: Self.sessionID,
            toolCall: .object(["toolCallId": .string("call-1"), "title": .string(title), "kind": .string("execute"),
                               "rawInput": .object(["command": .string(command)])]),
            options: options, meta: permission.isEmpty ? nil : .object(["permission": .object(permission)])))
    }

    /// Claude Code's ExitPlanMode: "Ready to code?", the plan as the call's content, and its
    /// own words for each way to go on.
    @discardableResult
    func requestPlanApproval(_ plan: String = SamplePlan.text) -> UUID {
        requestPermission(ACPPermissionRequest(
            sessionId: Self.sessionID,
            toolCall: .object(["toolCallId": .string("plan-1"), "title": .string("Ready to code?"), "kind": .string("switch_mode"),
                               "content": .array([.object(["type": .string("content"),
                                                           "content": .object(["type": .string("text"), "text": .string(plan)])])]),
                               "rawInput": .object(["plan": .string(plan)])]),
            options: SamplePlan.options,
            meta: .object(["permission": .object(["title": .string("Ready to code?")])])))
    }

    @discardableResult
    func requestPermission(_ request: ACPPermissionRequest) -> UUID {
        let requestID = UUID()
        guard let id = runtimeID else { return requestID }
        emit(.agent(.permissionRequested(runtimeID: id, requestID: requestID, request: request), sequence: nil))
        return requestID
    }

    func closePermission(_ request: UUID) {
        guard let id = runtimeID else { return }
        emit(.agent(.permissionClosed(runtimeID: id, requestID: request), sequence: nil))
    }

    /// Worded as Claude Code words them: the agent's words go under Latch's labels.
    static let standardOptions = [
        ACPPermissionOption(optionId: "allow", name: "Yes", kind: "allow_once"),
        ACPPermissionOption(optionId: "always", name: "Yes, and don’t ask again for rm commands in ~/latch", kind: "allow_always"),
        ACPPermissionOption(optionId: "reject", name: "No, and tell Claude what to do differently", kind: "reject_once"),
    ]

    /// Asks a question, as Claude Code's AskUserQuestion does through ACP's elicitation.
    @discardableResult
    func ask(_ request: ACPElicitationRequest = SampleQuestions.request) -> UUID {
        let requestID = UUID()
        guard let id = runtimeID else { return requestID }
        emit(.agent(.elicitationRequested(runtimeID: id, requestID: requestID, request: request), sequence: nil))
        return requestID
    }

    /// The question is withdrawn, as when another device answered it.
    func closeQuestion(_ request: UUID) {
        guard let id = runtimeID else { return }
        emit(.agent(.elicitationClosed(runtimeID: id, requestID: request), sequence: nil))
    }

    /// The answers that reached the server, in order.
    var elicitationResponses: [ACPElicitationResponse] {
        commands.compactMap { if case let .resolveElicitation(_, _, response) = $0 { response } else { nil } }
    }

    func close() {
        local.finish()
        remote.finish()
    }
}

/// Config options an agent advertises: grouped models, an effort, a permission mode, and one
/// of its own, Claude Code's Fast mode.
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
        .object(["id": .string("fast_mode"), "name": .string("Fast mode"), "type": .string("select"),
                 "description": .string("Faster output from the same model"), "currentValue": .string("off"),
                 "options": .array([
                    .object(["value": .string("off"), "name": .string("Off")]),
                    .object(["value": .string("on"), "name": .string("On")]),
                 ])]),
    ]
}

/// A server that could not be reached, as a remote channel reports one.
struct UnreachableServer: RemoteConnectionFailure, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Claude Code's AskUserQuestion with two questions, as claude-agent-acp asks it: one of several
/// options, each with its words and a preview, then any number of others; each question with an
/// Other box of its own.
enum SampleQuestions {
    static func other(for question: String) -> ACPJSONValue {
        .object(["type": .string("string"), "title": .string("Other"),
                 "_meta": .object(["_askUserQuestionCustomAnswer": .object(["questionId": .string(question),
                                                                            "isCustomAnswer": .bool(true)])])])
    }

    static func option(_ value: String, _ title: String, _ detail: String, preview: String? = nil) -> ACPJSONValue {
        var fields: [String: ACPJSONValue] = ["const": .string(value), "title": .string(title), "description": .string(detail)]
        if let preview { fields["_meta"] = .object(["_claude/askUserQuestionOption": .object(["preview": .string(preview)])]) }
        return .object(fields)
    }

    static let request = ACPElicitationRequest(
        sessionId: ScriptedSessionClient.sessionID, message: "Please answer the following questions.",
        requestedSchema: .object(["type": .string("object"), "required": .array([.string("question_0")]), "properties": .object([
            "question_0": .object([
                "type": .string("string"), "title": .string("Port"),
                "description": .string("How should the server keep its port across a restart?"),
                "oneOf": .array([
                    option("reuse", "Reuse the port", "Set SO_REUSEADDR before bind, as the Mac does by default.", preview: """
                        let listener = try Socket(.tcp)
                        try listener.setOption(.reuseAddress, true)
                        try listener.bind(port: port)
                        """),
                    option("fresh", "Take a new port", "Bind port 0 and tell the client which port it got.", preview: """
                        try listener.bind(port: 0)
                        client.port = listener.localPort
                        """),
                ]),
            ]),
            "question_0_custom": other(for: "question_0"),
            "question_1": .object([
                "type": .string("array"), "title": .string("Checks"),
                "description": .string("Which checks should run after the change?"),
                "items": .object(["anyOf": .array([
                    option("linux", "Linux runner", "The reconnect test on Ubuntu, where it fails."),
                    option("mac", "macOS runner", "The same test on the Mac, where it passes."),
                    option("fifty", "Fifty runs", "Run it fifty times in a row to be sure."),
                ])]),
            ]),
            "question_1_custom": other(for: "question_1"),
        ])]),
        toolCallId: "ask-1")
}

/// Claude Code's plan when it asks to leave plan mode, and its words for each way to go on.
enum SamplePlan {
    static let text = """
        ## Keep the port across a restart

        1. Set `SO_REUSEADDR` on the listener before `bind`, in `RemoteServer.listen()`.
        2. Keep the bound port in `LoopbackServer.restart()` and listen on it again.
        3. Run `RemoteSessionLiveTests` fifty times on the Linux runner.

        No public API changes.
        """

    static let options = [
        ACPPermissionOption(optionId: "acceptEdits", name: "Yes, and auto-accept edits", kind: "allow_always"),
        ACPPermissionOption(optionId: "default", name: "Yes, and manually approve edits", kind: "allow_once"),
        ACPPermissionOption(optionId: "plan", name: "No, keep planning", kind: "reject_once"),
    ]
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
