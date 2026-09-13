import Foundation
import LatchACP
import LatchServiceProtocol
import XCTest
@testable import LatchMacUI

final class SessionResumeTests: XCTestCase {
    private let savedID = "saved-agent-context"
    private let cached = [
        ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, role: .user, text: "Original question"),
        ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, role: .assistant, text: "Cached answer"),
        ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, role: .tool, text: "Read file · completed"),
    ]
    private var workspace: URL { FileManager.default.temporaryDirectory }

    @MainActor private func connect(_ model: SessionModel, new: Bool = false) async {
        await model.connect(command: "/bin/sh", workspace: workspace, startNewSession: new)
    }

    @MainActor private func restored(_ client: ResumeClient) -> SessionModel {
        let model = SessionModel(makeClient: { client })
        model.restore(messages: cached, agentSessionID: savedID)
        return model
    }

    @MainActor private func runtimeID(_ client: ResumeClient) async throws -> AgentRuntimeID {
        let id = await client.latestRuntime()
        return try XCTUnwrap(id)
    }

    // The permission acknowledgement is an event-stream barrier: receive has handled every
    // preceding event before it can issue resolvePermission. No sleeps or scheduler guesses.
    @MainActor private func drain(_ client: ResumeClient, runtime: AgentRuntimeID, session: String) async {
        let received = expectation(description: "Event stream drained")
        await client.barrier(runtime: runtime, session: session, received: received)
        await fulfillment(of: [received], timeout: 3)
    }

    @MainActor func testResumePreservesIdentityAndCachedMessagesThenAppendsOnlyNewPrompt() async throws {
        let client = ResumeClient()
        let model = restored(client)
        let transcript = model.transcript
        await connect(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.savedAgentSessionID, savedID)
        XCTAssertEqual(model.messages, cached)
        XCTAssertEqual(model.transcript, transcript)
        var commands = await client.commands
        let runtime = try await runtimeID(client)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last, .loadSession(runtimeID: runtime, sessionID: savedID, cwd: workspace.path))

        await model.send("A new question")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(Array(model.messages.prefix(cached.count)), cached)
        XCTAssertEqual(model.messages.last?.role, .user)
        XCTAssertEqual(model.messages.last?.text, "A new question")
        await client.message(runtime, session: savedID, text: "A new answer", sequence: 11)
        await drain(client, runtime: runtime, session: savedID)
        XCTAssertEqual(model.messages.map(\.text), cached.map(\.text) + ["A new question", "A new answer"])
        commands = await client.commands
        XCTAssertEqual(commands.filter { if case .prompt = $0 { true } else { false } }, [.prompt(runtimeID: runtime, text: "A new question")])
        XCTAssertFalse(commands.contains { if case .newSession = $0 { true } else { false } })
        await model.disconnect()
    }

    @MainActor func testLiveSessionSavesAgentIDAndDisconnectReconnectLoadsIt() async throws {
        let client = ResumeClient()
        let model = SessionModel(makeClient: { client })
        await connect(model)
        XCTAssertEqual(model.savedAgentSessionID, ResumeClient.newID)
        await model.send("Keep this")
        let messages = model.messages
        let first = try await runtimeID(client)
        await model.disconnect()
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.savedAgentSessionID, ResumeClient.newID)
        XCTAssertEqual(model.messages, messages)
        await connect(model)
        let second = try await runtimeID(client)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.messages, messages)
        let commands = await client.commands
        XCTAssertTrue(commands.contains(.loadSession(runtimeID: second, sessionID: ResumeClient.newID, cwd: workspace.path)))
        XCTAssertEqual(commands.filter { if case .newSession = $0 { true } else { false } }.count, 1)
        await model.disconnect()
        XCTAssertEqual(model.savedAgentSessionID, ResumeClient.newID)
    }

    @MainActor func testLoadReadFailureRetainsHistoryAndRetryLoadsSameIDWithoutNewOrReplay() async {
        let client = ResumeClient(failFirstLoad: true)
        let model = restored(client)
        await connect(model)
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.messages, cached)
        XCTAssertEqual(model.savedAgentSessionID, savedID)
        XCTAssertTrue(model.errorMessage?.contains("Cannot read saved context") == true)
        await model.send("Must not run")
        await connect(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.messages, cached)
        XCTAssertEqual(model.savedAgentSessionID, savedID)
        let commands = await client.commands
        XCTAssertEqual(commands.compactMap { command -> String? in
            if case let .loadSession(_, id, _) = command { return id }; return nil
        }, [savedID, savedID])
        XCTAssertEqual(commands.filter { if case .stopRuntime = $0 { true } else { false } }.count, 1)
        XCTAssertFalse(commands.contains { if case .newSession = $0 { true } else { false } })
        XCTAssertFalse(commands.contains { if case .prompt = $0 { true } else { false } })
        await model.disconnect()
    }

    @MainActor func testUnsupportedResumeNeverLoadsCreatesOrReplaysEvenOnRetry() async {
        let client = ResumeClient(supportsLoad: false)
        let model = restored(client)
        for _ in 0..<2 {
            await connect(model)
            XCTAssertEqual(model.phase, .disconnected)
            XCTAssertEqual(model.messages, cached)
            XCTAssertEqual(model.savedAgentSessionID, savedID)
            XCTAssertTrue(model.errorMessage?.contains("does not support resuming") == true)
            await model.send("Do not replay")
        }
        let commands = await client.commands
        XCTAssertEqual(commands.count, 4)
        XCTAssertTrue(commands.allSatisfy {
            switch $0 { case .startRuntime, .stopRuntime: true; default: false }
        })
    }

    @MainActor func testHistoryWithoutContextIsReadOnlyWithoutStartingProcess() async {
        let client = ResumeClient()
        let model = SessionModel(makeClient: { client })
        model.restore(messages: cached, agentSessionID: nil)
        await connect(model)
        await model.send("Not allowed")
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.status, "Saved · Read only")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.messages, cached)
        XCTAssertNil(model.savedAgentSessionID)
        let commands = await client.commands
        XCTAssertTrue(commands.isEmpty)
    }

    @MainActor func testMissingWorkspaceNeverStartsProcessOrDiscardsSavedContext() async {
        let client = ResumeClient()
        let model = restored(client)
        for url in [nil, workspace.appendingPathComponent(UUID().uuidString), URL(fileURLWithPath: "/bin/sh")] as [URL?] {
            await model.connect(command: "/bin/sh", workspace: url)
            XCTAssertEqual(model.phase, .disconnected)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.messages, cached)
            XCTAssertEqual(model.savedAgentSessionID, savedID)
        }
        let commands = await client.commands
        XCTAssertTrue(commands.isEmpty)
    }

    @MainActor func testConnectingAndLateReplayAreExcludedAndPermissionsAreNotRestored() async throws {
        let loading = expectation(description: "Load held")
        let client = ResumeClient(holdLoad: loading)
        let model = restored(client)
        let connection = Task { await connect(model) }
        await fulfillment(of: [loading], timeout: 3)
        let runtime = try await runtimeID(client)
        XCTAssertEqual(model.phase, .connecting)
        // Even absent or future sequence values cannot turn connecting replay into new text.
        for sequence: UInt64? in [nil, 1, 10, 99] {
            await client.message(runtime, session: savedID, text: "Replay", sequence: sequence)
            await client.tool(runtime, session: savedID, sequence: sequence)
        }
        await drain(client, runtime: runtime, session: savedID)
        XCTAssertEqual(model.messages, cached)
        XCTAssertNil(model.permissions.current)
        await client.releaseLoad()
        await connection.value
        XCTAssertEqual(model.phase, .ready)
        for sequence: UInt64 in [1, 9, 10] {
            await client.message(runtime, session: savedID, text: "Late replay", sequence: sequence)
            await client.tool(runtime, session: savedID, sequence: sequence)
        }
        await drain(client, runtime: runtime, session: savedID)
        XCTAssertEqual(model.messages, cached)
        XCTAssertNil(model.permissions.current)
        let outcomes = await client.permissionOutcomes
        XCTAssertEqual(outcomes, [.cancelled, .cancelled])
        await client.message(runtime, session: savedID, text: "Fresh", sequence: 11)
        await drain(client, runtime: runtime, session: savedID)
        XCTAssertEqual(model.messages.map(\.text), cached.map(\.text) + ["Fresh"])
        XCTAssertEqual(Array(model.messages.prefix(cached.count)), cached)
        await model.disconnect()
    }

    @MainActor func testShutdownDuringHeldLoadPreservesSavedIDAndHistory() async throws {
        let loading = expectation(description: "Load held during shutdown")
        let client = ResumeClient(holdLoad: loading)
        let model = restored(client)
        let connection = Task { await connect(model) }
        await fulfillment(of: [loading], timeout: 3)
        let runtime = try await runtimeID(client)
        await model.disconnect()
        let status = model.status
        await client.releaseLoad()
        await connection.value
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.status, status)
        XCTAssertEqual(model.savedAgentSessionID, savedID)
        XCTAssertEqual(model.messages, cached)
        XCTAssertEqual(model.configuration, SessionConfiguration())
        XCTAssertNil(model.permissions.current)
        XCTAssertNil(model.errorMessage)
        let commands = await client.commands
        XCTAssertTrue(commands.contains(.stopRuntime(id: runtime)))
        XCTAssertFalse(commands.contains { if case .newSession = $0 { true } else { false } })
        XCTAssertFalse(commands.contains { if case .prompt = $0 { true } else { false } })
    }

    @MainActor func testLoadConfigurationReplyWinsOverOlderBufferedUpdate() async throws {
        let loading = expectation(description: "Load held for older configuration")
        let client = ResumeClient(holdLoad: loading)
        let model = restored(client)
        let connection = Task { await connect(model) }
        await fulfillment(of: [loading], timeout: 3)
        let runtime = try await runtimeID(client)
        await client.configuration(runtime, session: savedID, value: "old", sequence: 9)
        await client.configuration(runtime, session: savedID, value: "old", sequence: 10)
        await drain(client, runtime: runtime, session: savedID)
        await client.releaseLoad()
        await connection.value
        XCTAssertEqual(model.configuration.model?.currentValue, "reply")
        XCTAssertEqual(model.messages, cached)
        await model.disconnect()
    }

    @MainActor func testStaleLoadSuccessAndFailureCannotMutateNewerSession() async throws {
        for fail in [false, true] {
            let loading = expectation(description: "Old load held")
            let client = ResumeClient(holdLoad: loading)
            let model = restored(client)
            let oldConnection = Task { await connect(model) }
            await fulfillment(of: [loading], timeout: 3)
            let oldRuntime = try await runtimeID(client)
            await model.disconnect()
            await connect(model, new: true)
            await model.send("New session state")
            let newRuntime = try await runtimeID(client)
            let messages = model.messages
            let configuration = model.configuration
            let status = model.status
            await client.releaseLoad(fail: fail)
            await oldConnection.value
            await client.message(oldRuntime, session: savedID, text: "Stale event", sequence: 100)
            await drain(client, runtime: newRuntime, session: ResumeClient.newID)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertEqual(model.savedAgentSessionID, ResumeClient.newID)
            XCTAssertEqual(model.messages, messages)
            XCTAssertEqual(model.configuration, configuration)
            XCTAssertEqual(model.status, status)
            XCTAssertNil(model.errorMessage)
            let commands = await client.commands
            XCTAssertFalse(commands.contains(.stopRuntime(id: newRuntime)))
            await model.disconnect()
        }
    }

    @MainActor func testLoadConfigurationReplyAndUpdatesFollowIngressSequence() async throws {
        let loading = expectation(description: "Load held for configuration")
        let client = ResumeClient(holdLoad: loading)
        let model = restored(client)
        let connection = Task { await connect(model) }
        await fulfillment(of: [loading], timeout: 3)
        let runtime = try await runtimeID(client)
        await client.configuration(runtime, session: savedID, value: "old", sequence: 9)
        await client.configuration(runtime, session: savedID, value: "newer", sequence: 12)
        await client.configuration(runtime, session: "different-session", value: "wrong", sequence: 100)
        await drain(client, runtime: runtime, session: savedID)
        await client.releaseLoad()
        await connection.value
        XCTAssertEqual(model.configuration.model?.currentValue, "newer")
        await client.configuration(runtime, session: savedID, value: "old", sequence: 10)
        await client.configuration(runtime, session: savedID, value: "old", sequence: 11)
        await drain(client, runtime: runtime, session: savedID)
        XCTAssertEqual(model.configuration.model?.currentValue, "newer")
        await client.configuration(runtime, session: savedID, value: "latest", sequence: 13)
        await drain(client, runtime: runtime, session: savedID)
        XCTAssertEqual(model.configuration.model?.currentValue, "latest")
        XCTAssertEqual(model.messages, cached)
        await model.disconnect()
    }
}

private actor ResumeClient: AgentServiceClient {
    static let newID = "new-agent-context"
    nonisolated let transportDescription = "deterministic resume mock"
    nonisolated let events: AsyncStream<LatchAgentEvent>
    private nonisolated let continuation: AsyncStream<LatchAgentEvent>.Continuation
    private let supportsLoad: Bool
    private var failFirstLoad: Bool
    private var holdLoad: XCTestExpectation?
    private var pendingLoad: CheckedContinuation<Void, any Error>?
    private var barriers: [UUID: XCTestExpectation] = [:]
    private(set) var commands: [LatchAgentCommand] = []
    private(set) var permissionOutcomes: [ACPPermissionOutcome] = []

    init(supportsLoad: Bool = true, failFirstLoad: Bool = false, holdLoad: XCTestExpectation? = nil) {
        self.supportsLoad = supportsLoad
        self.failFirstLoad = failFirstLoad
        self.holdLoad = holdLoad
        let pair = AsyncStream<LatchAgentEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    nonisolated func close() { continuation.finish() }

    func latestRuntime() -> AgentRuntimeID? {
        commands.reversed().compactMap { if case let .startRuntime(id, _) = $0 { id } else { nil } }.first
    }

    func releaseLoad(fail: Bool = false) {
        let pending = pendingLoad
        pendingLoad = nil
        if fail { pending?.resume(throwing: Self.readFailure) } else { pending?.resume() }
    }

    private static var readFailure: LatchAgentFailure {
        LatchAgentFailure(code: .commandFailed, message: "Cannot read saved context")
    }

    private static func options(_ value: String) -> [ACPJSONValue] {
        [.object(["id": .string("model"), "name": .string("Model"), "type": .string("select"),
                  "currentValue": .string(value), "options": .array(["old", "reply", "newer", "latest", "wrong"].map {
                      .object(["value": .string($0), "name": .string($0)])
                  })])]
    }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        commands.append(command)
        switch command {
        case let .startRuntime(id, _):
            return .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init(loadSession: supportsLoad)))
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: Self.newID))
        case let .loadSession(id, _, _):
            if let held = holdLoad {
                holdLoad = nil
                try await withCheckedThrowingContinuation { pendingLoad = $0; held.fulfill() }
            }
            if failFirstLoad { failFirstLoad = false; throw Self.readFailure }
            return .sessionLoaded(runtimeID: id, response: ACPLoadSessionResponse(configOptions: Self.options("reply"), localSequence: 10))
        case let .prompt(id, _):
            return .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn"))
        case let .stopRuntime(id):
            return .runtimeStopped(runtimeID: id)
        case let .resolvePermission(id, request, outcome):
            permissionOutcomes.append(outcome)
            barriers.removeValue(forKey: request)?.fulfill()
            return .permissionResolved(runtimeID: id, requestID: request)
        default:
            XCTFail("Unexpected mock command: \(command)")
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected mock command")
        }
    }

    func barrier(runtime: AgentRuntimeID, session: String, received: XCTestExpectation) {
        let request = UUID()
        barriers[request] = received
        continuation.yield(.permissionRequested(runtimeID: runtime, requestID: request, request: ACPPermissionRequest(
            sessionId: session, toolCall: .object(["title": .string("Archived permission")]),
            options: [.init(optionId: "allow", name: "Allow", kind: "allow_once")]
        )))
    }

    func message(_ runtime: AgentRuntimeID, session: String, text: String, sequence: UInt64?) {
        update(runtime, session: session, value: .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ]), sequence: sequence)
    }

    func tool(_ runtime: AgentRuntimeID, session: String, sequence: UInt64?) {
        update(runtime, session: session, value: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("old-tool"),
            "title": .string("Replayed tool"), "status": .string("completed"),
        ]), sequence: sequence)
    }

    func configuration(_ runtime: AgentRuntimeID, session: String, value: String, sequence: UInt64) {
        update(runtime, session: session, value: .object([
            "sessionUpdate": .string("config_option_update"), "configOptions": .array(Self.options(value)),
        ]), sequence: sequence)
    }

    private func update(_ runtime: AgentRuntimeID, session: String, value: ACPJSONValue, sequence: UInt64?) {
        continuation.yield(.sessionUpdate(runtimeID: runtime, notification: ACPSessionNotification(
            sessionId: session, update: value, localSequence: sequence
        )))
    }
}
