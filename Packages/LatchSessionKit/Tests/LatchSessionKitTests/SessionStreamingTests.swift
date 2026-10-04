import Foundation
import LatchACP
import LatchServiceProtocol
import XCTest
@testable import LatchSessionKit

final class SessionStreamingTests: XCTestCase {
    @MainActor private func connected(_ client: StreamingClient) async -> SessionModel {
        let model = SessionModel(makeClient: { client })
        await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
        XCTAssertEqual(model.phase, .ready)
        return model
    }

    // A wrong-session permission is acknowledged only after all preceding stream events
    // have been received. It never enters PermissionQueue, even during a prompt.
    @MainActor private func drain(_ client: StreamingClient, runtime: AgentRuntimeID) async {
        let drained = expectation(description: "Event stream drained")
        await client.barrier(runtime: runtime, received: drained)
        await fulfillment(of: [drained], timeout: 3)
    }

    @MainActor func testStreamingTextAndToolsNotifyTranscriptOnlyWithCurrentHistory() async throws {
        let started = expectation(description: "Prompt command reached service")
        let client = StreamingClient(promptStarted: started)
        let model = await connected(client)
        let runtimeValue = await client.runtime
        let runtime = try XCTUnwrap(runtimeValue)
        var states: [SessionModel.Phase] = []
        var snapshots: [[ChatMessage]] = []
        model.onChange = { states.append(model.phase) }
        model.onTranscriptChange = { snapshots.append(model.messages) }
        defer { model.onChange = nil; model.onTranscriptChange = nil }

        let prompt = Task { await model.send("Question") }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(states, [.prompting], "Send must publish state before waiting for the agent")
        XCTAssertEqual(snapshots.map { $0.map(\.text) }, [["Question"]])
        states.removeAll()
        snapshots.removeAll()

        await client.text(runtime, "Hello")
        await client.text(runtime, " world")
        await client.tool(runtime, completed: false)
        await client.tool(runtime, completed: true)
        await drain(client, runtime: runtime)
        XCTAssertTrue(states.isEmpty, "Streaming must not invalidate session state")
        XCTAssertEqual(snapshots.count, 4, "Every history mutation invalidates immediately; only UI rendering coalesces")
        XCTAssertEqual(snapshots.map { $0.last?.text }, ["Hello", "Hello world", "Read file · pending", "Read file · completed"])
        XCTAssertEqual(snapshots.first?.last?.id, snapshots.dropFirst().first?.last?.id)
        XCTAssertEqual(snapshots.last, model.messages)
        XCTAssertEqual(model.transcript, "You\nQuestion\n\nAgent\nHello world\n\nTool\nRead file · completed")

        let finalHistory = model.messages
        var completionHistory: [ChatMessage]?
        model.onChange = {
            states.append(model.phase)
            if model.phase == .ready { completionHistory = model.messages }
        }
        await client.completePrompt()
        await prompt.value
        // Permission cleanup also publishes state, even when its queue is empty.
        XCTAssertFalse(states.isEmpty, "Completion must publish state before send returns")
        XCTAssertTrue(states.allSatisfy { $0 == .ready })
        XCTAssertEqual(completionHistory, finalHistory)
        XCTAssertEqual(snapshots.count, 4)
        await model.disconnect()
        XCTAssertEqual(model.messages, finalHistory)
    }

    /// A local turn's reply can overtake its last updates on their way through the service. The
    /// turn goes on until the update the reply names is in, and ends with it.
    @MainActor func testALocalTurnEndsOnceTheUpdateItsReplyNamesIsIn() async throws {
        let started = expectation(description: "Prompt started")
        let client = StreamingClient(promptStarted: started)
        let model = await connected(client)
        let runtimeValue = await client.runtime
        let runtime = try XCTUnwrap(runtimeValue)
        var atReady: [String]?
        model.onChange = { if atReady == nil, model.phase == .ready { atReady = model.messages.map(\.text) } }
        defer { model.onChange = nil }

        let prompt = Task { await model.send("Question") }
        await fulfillment(of: [started], timeout: 3)
        await client.text(runtime, "Hello", sequence: 12)
        await drain(client, runtime: runtime)
        await client.completePrompt(updatesThrough: 13)
        try await eventually("the reply held") { model.turnEndIsWaiting }
        XCTAssertEqual(model.phase, .prompting)

        await client.text(runtime, " world", sequence: 13)
        await prompt.value
        XCTAssertEqual(atReady, ["Question", "Hello world"])
        XCTAssertEqual(model.status, "Ready · end_turn")
        await model.disconnect()
    }

    /// Thinking shows as its own rows, a subagent's call, words and thinking go under the call
    /// that runs it, and the plan is the session's, replaced by each update and cleared by an empty one.
    @MainActor func testThinkingSubagentsAndThePlanReachTheSession() async throws {
        let started = expectation(description: "Prompt started")
        let client = StreamingClient(promptStarted: started)
        let model = await connected(client)
        let runtimeValue = await client.runtime
        let runtime = try XCTUnwrap(runtimeValue)
        let prompt = Task { await model.send("Question") }
        await fulfillment(of: [started], timeout: 3)

        func chunk(_ kind: String, _ text: String, parent: String? = nil) -> ACPJSONValue {
            var update: [String: ACPJSONValue] = ["sessionUpdate": .string(kind), "content": .object(["type": .string("text"), "text": .string(text)])]
            if let parent { update["_meta"] = .object(["claudeCode": .object(["parentToolUseId": .string(parent)])]) }
            return .object(update)
        }
        let plan: ACPJSONValue = .object(["sessionUpdate": .string("plan"), "entries": .array([
            .object(["content": .string("Look"), "status": .string("in_progress")]),
            .object(["content": .string("Fix"), "status": .string("pending")]),
        ])])
        await client.update(runtime, value: plan, sequence: 12)
        await client.update(runtime, value: chunk("agent_thought_chunk", "Where to look?"), sequence: 13)
        await client.update(runtime, value: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("agent-1"), "title": .string("Explore"), "kind": .string("think"),
            "_meta": .object(["claudeCode": .object(["toolName": .string("Agent"), "subagent": .bool(true)])]),
        ]), sequence: 14)
        await client.update(runtime, value: chunk("agent_thought_chunk", "Sources first.", parent: "agent-1"), sequence: 15)
        await client.update(runtime, value: chunk("agent_message_chunk", "It is in Sources.", parent: "agent-1"), sequence: 16)
        await client.update(runtime, value: chunk("agent_message_chunk", "Found it."), sequence: 17)
        await drain(client, runtime: runtime)

        XCTAssertEqual(model.plan, [ACPPlanEntry(content: "Look", status: .inProgress), ACPPlanEntry(content: "Fix", status: .pending)])
        let messages = model.messages
        XCTAssertEqual(messages.map(\.role), [.user, .thought, .tool, .thought, .assistant, .assistant])
        XCTAssertEqual(messages.map(\.text), ["Question", "Where to look?", "Explore · updated", "Sources first.", "It is in Sources.", "Found it."])
        let agentRow = messages[2].id
        XCTAssertEqual(messages.map(\.parentID), [nil, nil, nil, agentRow, agentRow, nil])
        XCTAssertEqual(messages[2].tool?.runsSubagent, true)

        await client.update(runtime, value: .object(["sessionUpdate": .string("plan"), "entries": .array([])]), sequence: 18)
        await drain(client, runtime: runtime)
        XCTAssertEqual(model.plan, [])
        await client.completePrompt(updatesThrough: 18)
        await prompt.value
        await model.disconnect()
    }

    /// How full the agent's context is and what the conversation has cost, its own title for the
    /// conversation, and a turn cut short at a limit, which says so where its reply stops.
    @MainActor func testUsageTitleAndATurnCutShortReachTheSession() async throws {
        let started = expectation(description: "Prompt started")
        let client = StreamingClient(promptStarted: started)
        let model = await connected(client)
        let runtimeValue = await client.runtime
        let runtime = try XCTUnwrap(runtimeValue)
        let prompt = Task { await model.send("Question") }
        await fulfillment(of: [started], timeout: 3)
        await client.update(runtime, value: .object([
            "sessionUpdate": .string("usage_update"), "used": .integer(50_000), "size": .integer(200_000),
            "cost": .object(["amount": .double(0.12), "currency": .string("USD")]),
        ]), sequence: 12)
        await client.update(runtime, value: .object(["sessionUpdate": .string("session_info_update"), "title": .string(" Fix the flaky test ")]), sequence: 13)
        await client.update(runtime, value: .object(["sessionUpdate": .string("usage_update"), "used": .integer(1), "size": .integer(0)]), sequence: 14)
        // Past what an Int holds: dropped, not trapped on, here and on every attach that replays it.
        await client.update(runtime, value: .object(["sessionUpdate": .string("usage_update"), "used": .double(1e20), "size": .integer(200_000)]), sequence: 14)
        await drain(client, runtime: runtime)
        XCTAssertEqual(model.usage, ContextUsage(used: 50_000, size: 200_000, cost: 0.12, currency: "USD"), "A malformed update leaves the last one")
        XCTAssertEqual(model.usage?.fraction, 0.25)
        XCTAssertEqual(model.agentTitle, "Fix the flaky test")
        await client.completePrompt(reason: "max_tokens", updatesThrough: 14)
        await prompt.value
        XCTAssertEqual(model.messages.last?.text, "_The reply stopped at the agent’s length limit._")
        await model.disconnect()
        XCTAssertNil(model.usage)
    }

    /// A message written while the agent works waits its turn and goes out when it ends; Stop
    /// gives what is still waiting back to the composer rather than sending it.
    @MainActor func testMessagesWrittenWhileTheAgentWorksWaitTheirTurn() async throws {
        let client = StreamingClient()
        let model = await connected(client)
        var returned: [String] = []
        model.onQueueReturned = { returned += $0.map(\.text) }
        let first = Task { await model.send("First") }
        try await eventually("the first prompt") { await client.hasPendingPrompt }
        await model.send("Second")
        await model.send("Third")
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["Second", "Third"])
        let third = try XCTUnwrap(model.queuedPrompts.last?.id)
        XCTAssertEqual(model.unqueue(third)?.text, "Third")
        await client.completePrompt()
        await first.value
        try await eventually("the queued prompt") { await client.prompts == ["First", "Second"] }
        XCTAssertTrue(model.queuedPrompts.isEmpty)
        try await eventually("the second turn") { await client.hasPendingPrompt }

        await model.send("Never sent")
        await model.cancel()
        XCTAssertEqual(returned, ["Never sent"])
        XCTAssertTrue(model.queuedPrompts.isEmpty)
        await client.completePrompt(reason: "cancelled")
        try await eventually("the turn's end") { model.phase == .ready }
        let prompts = await client.prompts
        XCTAssertEqual(prompts, ["First", "Second"])
        await model.disconnect()
    }

    /// With an agent that steers, a message written while it works goes into the turn and shows
    /// once the agent has it; one that finds the turn over goes as a prompt of its own.
    @MainActor func testAMessageWrittenWhileTheAgentWorksSteersALocalTurn() async throws {
        let client = StreamingClient(steers: true)
        let model = await connected(client)
        XCTAssertTrue(model.steersPrompts)
        let first = Task { await model.send("First") }
        try await eventually("the first prompt") { await client.hasPendingPrompt }
        await model.send("Also this")
        let steered = await client.steered
        XCTAssertEqual(steered, ["Also this"])
        XCTAssertEqual(model.messages.map(\.text), ["First", "Also this"])
        XCTAssertTrue(model.queuedPrompts.isEmpty)
        await client.completePrompt()
        await first.value
        let prompts = await client.prompts
        XCTAssertEqual(prompts, ["First"], "Nothing more was sent as a prompt")

        // Into a turn being stopped, nothing is steered: what is written then waits for its end.
        let second = Task { await model.send("Second") }
        try await eventually("the second prompt") { await client.hasPendingPrompt }
        await model.cancel()
        await model.send("After Stop")
        let steeredAfterStop = await client.steered
        XCTAssertEqual(steeredAfterStop, ["Also this"])
        XCTAssertEqual(model.queuedPrompts.map(\.text), ["After Stop"])
        await client.completePrompt(reason: "cancelled")
        await second.value
        try await eventually("the message written after Stop") { await client.prompts == ["First", "Second", "After Stop"] }
        await model.disconnect()
    }

    /// A server older than Latch cannot list or fork the agent's conversations; the session
    /// stops offering to.
    @MainActor func testAnOlderServerTurnsListingOff() async throws {
        let client = StreamingClient(refusesSessions: true)
        let model = await connected(client)
        XCTAssertTrue(model.listsAgentSessions && model.forksAgentSessions)
        do {
            _ = try await model.agentSessions()
            XCTFail("An older server refuses")
        } catch {
            XCTAssertTrue(error is RemoteCommandUnsupported)
        }
        XCTAssertFalse(model.listsAgentSessions)
        do {
            _ = try await model.forkAgentSession()
            XCTFail("An older server refuses")
        } catch {
            XCTAssertTrue(error is RemoteCommandUnsupported)
        }
        XCTAssertFalse(model.forksAgentSessions)
        await model.disconnect()
    }

    /// A new session takes up one of the agent's own conversations and shows its history, which
    /// only the agent had; it can also fork its conversation.
    @MainActor func testANewSessionTakesUpAnAgentsConversationWithItsHistory() async throws {
        let client = StreamingClient()
        let model = await connected(client)
        XCTAssertTrue(model.listsAgentSessions && model.forksAgentSessions)
        let sessions = try await model.agentSessions()
        XCTAssertEqual(sessions.map(\.sessionId), ["older"], "Not the conversation the session holds")
        let forked = try await model.forkAgentSession()
        XCTAssertEqual(forked, StreamingClient.session + "-fork")

        await model.switchToAgentSession("older")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.savedAgentSessionID, "older")
        let runtimeValue = await client.runtime
        let runtime = try XCTUnwrap(runtimeValue)
        await client.update(runtime, session: "older", value: .object(["sessionUpdate": .string("user_message_chunk"),
                                                                       "content": .object(["type": .string("text"), "text": .string("Earlier question")])]),
                            sequence: 8)
        await client.text(runtime, "Earlier answer", session: "older", sequence: 9)
        await drain(client, runtime: runtime)
        XCTAssertEqual(model.messages.map(\.text), ["Earlier question", "Earlier answer"])
        await model.disconnect()
    }

    /// Disconnecting while a local turn's reply waits for its last update lets go of it.
    @MainActor func testDisconnectingLetsGoOfALocalReplyWaitingForItsLastUpdate() async throws {
        let started = expectation(description: "Prompt started")
        let client = StreamingClient(promptStarted: started)
        let model = await connected(client)
        let prompt = Task { await model.send("Question") }
        await fulfillment(of: [started], timeout: 3)
        await client.completePrompt(updatesThrough: 13)
        try await eventually("the reply held") { model.turnEndIsWaiting }
        await model.disconnect()
        await prompt.value
        XCTAssertFalse(model.turnEndIsWaiting)
        XCTAssertEqual(model.phase, .disconnected)
    }

    @MainActor func testConfigurationPermissionAndCancelAreStateNotificationsWithoutTranscriptDelay() async throws {
        let started = expectation(description: "Prompt started")
        let client = StreamingClient(promptStarted: started)
        let model = await connected(client)
        let runtimeValue = await client.runtime
        let runtime = try XCTUnwrap(runtimeValue)
        let prompt = Task { await model.send("Question") }
        await fulfillment(of: [started], timeout: 3)
        var transcriptChanges = 0
        var configuredValues: [String?] = []
        model.onTranscriptChange = { transcriptChanges += 1 }
        model.onChange = { configuredValues.append(model.configuration.model?.currentValue) }
        defer { model.onChange = nil; model.onTranscriptChange = nil }
        await client.configuration(runtime)
        await drain(client, runtime: runtime)
        XCTAssertEqual(configuredValues, ["fast"])
        XCTAssertEqual(transcriptChanges, 0)

        let permission = expectation(description: "Permission is immediately visible to state observer")
        model.onChange = {
            if model.permissions.current != nil { permission.fulfill() }
        }
        await client.permission(runtime)
        await fulfillment(of: [permission], timeout: 3)
        XCTAssertNotNil(model.permissions.current)
        var sawCancellation = false
        model.onChange = {
            if model.cancellationRequested, model.status == "Cancelling…" {
                sawCancellation = true
                XCTAssertNil(model.permissions.current)
            }
        }
        await model.cancel()
        XCTAssertTrue(sawCancellation)
        XCTAssertEqual(model.phase, .prompting, "Cancellation acknowledgement does not complete the held prompt")
        XCTAssertEqual(transcriptChanges, 0)
        await client.completePrompt(reason: "cancelled")
        await prompt.value
        XCTAssertEqual(model.status, "Cancelled")
        XCTAssertEqual(model.phase, .ready)
        await model.disconnect()
    }

    @MainActor func testConfigurationSelectionPublishesBusyStateBeforeServiceReply() async throws {
        let started = expectation(description: "Configuration command reached service")
        let client = StreamingClient(selectionStarted: started)
        let model = await connected(client)
        let runtimeValue = await client.runtime
        let runtime = try XCTUnwrap(runtimeValue)
        await client.configuration(runtime)
        await drain(client, runtime: runtime)
        var busyStates: [Bool] = []
        var transcriptChanges = 0
        model.onChange = { busyStates.append(model.isChangingConfiguration) }
        model.onTranscriptChange = { transcriptChanges += 1 }
        defer { model.onChange = nil; model.onTranscriptChange = nil }
        let selection = Task { await model.select(.model, value: "deep") }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(busyStates, [true])
        XCTAssertEqual(model.configuration.model?.currentValue, "fast", "Selection is not optimistic")
        await client.completeSelection()
        await selection.value
        XCTAssertEqual(busyStates, [true, false])
        XCTAssertEqual(transcriptChanges, 0)
        await model.disconnect()
    }

    @MainActor func testLossImmediatelyPublishesStateAndKeepsFinalHistory() async throws {
        for serviceLoss in [false, true] {
            let started = expectation(description: "Prompt started")
            let client = StreamingClient(promptStarted: started)
            let replacement = StreamingClient()
            var clientsCreated = 0
            let model = SessionModel(makeClient: {
                clientsCreated += 1
                return clientsCreated == 1 ? client : replacement
            })
            await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
            let runtimeValue = await client.runtime
            let runtime = try XCTUnwrap(runtimeValue)
            let prompt = Task { await model.send("Question") }
            await fulfillment(of: [started], timeout: 3)
            await client.text(runtime, "Final partial answer")
            await drain(client, runtime: runtime)
            let history = model.messages
            var transcriptChanges = 0
            let lost = expectation(description: "Loss published with final history")
            model.onTranscriptChange = { transcriptChanges += 1 }
            model.onChange = {
                if model.phase == .disconnected {
                    XCTAssertEqual(model.messages, history)
                    XCTAssertNotNil(model.errorMessage)
                    lost.fulfill()
                }
            }
            if serviceLoss { client.close() }
            else { await client.terminate(runtime) }
            await fulfillment(of: [lost], timeout: 3)
            XCTAssertEqual(transcriptChanges, 0)
            XCTAssertEqual(model.status, serviceLoss ? "Agent service disconnected" : "Agent exited (23)")
            model.onChange = nil
            model.onTranscriptChange = nil
            // An old command completion cannot resurrect the lost runtime.
            await client.completePrompt()
            await prompt.value
            XCTAssertEqual(model.phase, .disconnected)
            XCTAssertEqual(model.messages, history)
            await model.disconnect()
        }
    }

    @MainActor func testStaleRuntimeSessionAndLoadedReplayDoNotInvalidateHistory() async throws {
        let client = StreamingClient()
        let model = SessionModel(makeClient: { client })
        let cached = [ChatMessage(role: .assistant, text: "Saved answer")]
        model.restore(messages: cached, agentSessionID: StreamingClient.session)
        await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
        let runtimeValue = await client.runtime
        let runtime = try XCTUnwrap(runtimeValue)
        var states = 0
        var transcripts = 0
        model.onChange = { states += 1 }
        model.onTranscriptChange = { transcripts += 1 }
        defer { model.onChange = nil; model.onTranscriptChange = nil }
        await client.text(AgentRuntimeID("stale-runtime"), "Wrong runtime")
        await client.text(runtime, "Wrong session", session: "wrong-session")
        await client.text(runtime, "Replayed answer", sequence: 10)
        await client.tool(runtime, completed: true, sequence: 9)
        await drain(client, runtime: runtime)
        XCTAssertEqual(states, 0)
        XCTAssertEqual(transcripts, 0)
        XCTAssertEqual(model.messages, cached)
        await client.text(runtime, "New answer", sequence: 11)
        await drain(client, runtime: runtime)
        XCTAssertEqual(states, 0)
        XCTAssertEqual(transcripts, 1)
        XCTAssertTrue(model.transcript.contains("New answer"))
        XCTAssertEqual(model.messages.first?.id, cached.first?.id)
        await model.disconnect()
    }
}

private actor StreamingClient: AgentServiceClient {
    static let session = "streaming-session"
    nonisolated let transportDescription = "deterministic streaming mock"
    /// What every prompt said, in order, and every message steered into a turn.
    private(set) var prompts: [String] = []
    private(set) var steered: [String] = []
    private let steers: Bool
    private let refusesSessions: Bool
    var hasPendingPrompt: Bool { pendingPrompt != nil }
    nonisolated let events: AsyncStream<LatchAgentEvent>
    private nonisolated let continuation: AsyncStream<LatchAgentEvent>.Continuation
    private let promptStarted: XCTestExpectation?
    private let selectionStarted: XCTestExpectation?
    private var pendingSelection: CheckedContinuation<LatchAgentResponse, Never>?
    private var pendingPrompt: CheckedContinuation<LatchAgentResponse, Never>?
    private var barriers: [UUID: XCTestExpectation] = [:]
    private(set) var runtime: AgentRuntimeID?

    init(promptStarted: XCTestExpectation? = nil, selectionStarted: XCTestExpectation? = nil, steers: Bool = false,
         refusesSessions: Bool = false) {
        self.steers = steers
        self.refusesSessions = refusesSessions
        self.promptStarted = promptStarted
        self.selectionStarted = selectionStarted
        let pair = AsyncStream<LatchAgentEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    nonisolated func close() { continuation.finish() }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .startRuntime(id, _):
            runtime = id
            return .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(
                protocolVersion: 1, agentCapabilities: .init(loadSession: true, sessionCapabilities: .object([
                    "list": .object([:]), "fork": .object([:]),
                ])), meta: steers ? .object(["steering": .object(["supported": .bool(true)])]) : nil))
        case let .steerPrompt(id, blocks):
            steered += blocks.compactMap { if case let .text(text) = $0 { text } else { nil } }
            return .promptSteered(runtimeID: id, injected: pendingPrompt != nil)
        case .listSessions where refusesSessions, .forkSession where refusesSessions:
            throw RemoteCommandUnsupported()
        case let .listSessions(id, cwd):
            return .sessionsListed(runtimeID: id, sessions: [
                ACPSessionSummary(sessionId: "older", cwd: cwd, title: "An older conversation"),
                ACPSessionSummary(sessionId: Self.session, cwd: cwd),
            ])
        case let .forkSession(id, sessionID, _):
            return .sessionForked(runtimeID: id, sessionID: sessionID + "-fork")
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: Self.session))
        case let .loadSession(id, _, _):
            return .sessionLoaded(runtimeID: id, response: ACPLoadSessionResponse(localSequence: 10))
        case let .prompt(_, blocks):
            prompts += blocks.compactMap { if case let .text(text) = $0 { text } else { nil } }
            return await withCheckedContinuation {
                pendingPrompt = $0
                promptStarted?.fulfill()
            }
        case .setSessionConfigOption:
            return await withCheckedContinuation {
                pendingSelection = $0
                selectionStarted?.fulfill()
            }
        case let .cancelPrompt(id):
            return .promptCancellationRequested(runtimeID: id)
        case let .stopRuntime(id):
            return .runtimeStopped(runtimeID: id)
        case let .resolvePermission(id, request, _):
            barriers.removeValue(forKey: request)?.fulfill()
            return .permissionResolved(runtimeID: id, requestID: request)
        default:
            XCTFail("Unexpected mock command: \(command)")
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected mock command")
        }
    }

    func completeSelection() {
        guard let runtime else { return }
        let pending = pendingSelection
        pendingSelection = nil
        pending?.resume(returning: .sessionConfigOptionSet(runtimeID: runtime,
            response: ACPSetSessionConfigOptionResponse(configOptions: [], localSequence: 12)))
    }

    func completePrompt(reason: String = "end_turn", updatesThrough: UInt64? = nil) {
        guard let runtime else { return }
        let pending = pendingPrompt
        pendingPrompt = nil
        pending?.resume(returning: .promptCompleted(
            runtimeID: runtime, response: ACPPromptResponse(stopReason: reason, updatesThrough: updatesThrough)
        ))
    }

    func barrier(runtime: AgentRuntimeID, received: XCTestExpectation) {
        let id = UUID()
        barriers[id] = received
        permission(runtime, session: "barrier-wrong-session", id: id)
    }

    func permission(_ runtime: AgentRuntimeID, session: String = session, id: UUID = UUID()) {
        continuation.yield(.permissionRequested(runtimeID: runtime, requestID: id, request: ACPPermissionRequest(
            sessionId: session, toolCall: .object(["title": .string("Read file")]),
            options: [.init(optionId: "allow", name: "Allow", kind: "allow_once")]
        )))
    }

    func terminate(_ runtime: AgentRuntimeID) {
        continuation.yield(.processTerminated(runtimeID: runtime, status: 23))
    }

    func text(_ runtime: AgentRuntimeID, _ text: String, session: String = session, sequence: UInt64 = 11) {
        update(runtime, session: session, value: .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ]), sequence: sequence)
    }

    func tool(_ runtime: AgentRuntimeID, completed: Bool, sequence: UInt64 = 11) {
        var value: [String: ACPJSONValue] = [
            "sessionUpdate": .string(completed ? "tool_call_update" : "tool_call"),
            "toolCallId": .string("read-1"), "status": .string(completed ? "completed" : "pending"),
        ]
        if !completed { value["title"] = .string("Read file") }
        update(runtime, value: .object(value), sequence: sequence)
    }

    func configuration(_ runtime: AgentRuntimeID) {
        update(runtime, value: .object([
            "sessionUpdate": .string("config_option_update"),
            "configOptions": .array([.object([
                "id": .string("model"), "name": .string("Model"), "type": .string("select"),
                "currentValue": .string("fast"),
                "options": .array(["fast", "deep"].map {
                    .object(["value": .string($0), "name": .string($0)])
                }),
            ])]),
        ]), sequence: 11)
    }

    func update(_ runtime: AgentRuntimeID, session: String = session, value: ACPJSONValue, sequence: UInt64) {
        continuation.yield(.sessionUpdate(runtimeID: runtime, notification: ACPSessionNotification(
            sessionId: session, update: value, localSequence: sequence)))
    }
}
