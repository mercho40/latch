import Foundation
import LatchACP
import LatchServiceProtocol
import XCTest
@testable import LatchMacUI

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
    nonisolated let events: AsyncStream<LatchAgentEvent>
    private nonisolated let continuation: AsyncStream<LatchAgentEvent>.Continuation
    private let promptStarted: XCTestExpectation?
    private let selectionStarted: XCTestExpectation?
    private var pendingSelection: CheckedContinuation<LatchAgentResponse, Never>?
    private var pendingPrompt: CheckedContinuation<LatchAgentResponse, Never>?
    private var barriers: [UUID: XCTestExpectation] = [:]
    private(set) var runtime: AgentRuntimeID?

    init(promptStarted: XCTestExpectation? = nil, selectionStarted: XCTestExpectation? = nil) {
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
                protocolVersion: 1, agentCapabilities: .init(loadSession: true)))
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: Self.session))
        case let .loadSession(id, _, _):
            return .sessionLoaded(runtimeID: id, response: ACPLoadSessionResponse(localSequence: 10))
        case .prompt:
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

    func completePrompt(reason: String = "end_turn") {
        guard let runtime else { return }
        let pending = pendingPrompt
        pendingPrompt = nil
        pending?.resume(returning: .promptCompleted(runtimeID: runtime, response: ACPPromptResponse(stopReason: reason)))
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

    private func update(_ runtime: AgentRuntimeID, session: String = session, value: ACPJSONValue, sequence: UInt64) {
        continuation.yield(.sessionUpdate(runtimeID: runtime, notification: ACPSessionNotification(
            sessionId: session, update: value, localSequence: sequence)))
    }
}
