import Foundation
import LatchACP
import LatchServiceProtocol
import XCTest
@testable import LatchMacUI

final class SessionAuthenticationTests: XCTestCase {
    @MainActor func testAuthenticationFailureStopsSessionAndAllowsExplicitReconnect() async {
        for failure: any Error in [
            ACPJSONRPCErrorObject(code: -32000, message: "Authentication required"),
            LatchAgentFailure(code: .authenticationRequired, message: "Agent reported: Not logged in"),
        ] {
            let client = AuthenticationClient(failure: failure)
            let model = SessionModel(makeClient: { client })
            await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
            await model.send("hey")
            XCTAssertEqual(model.phase, .disconnected)
            XCTAssertEqual(model.status, "Sign-in required")
            XCTAssertTrue(model.errorMessage?.contains("then try again") == true)
            XCTAssertEqual(model.messages.map(\.text), ["hey"])
            XCTAssertEqual(model.configuration, SessionConfiguration())
            XCTAssertFalse(model.isChangingConfiguration)
            XCTAssertFalse(model.cancellationRequested)
            let stops = await client.stops
            XCTAssertEqual(stops, 1)
            await model.send("Must not reconnect")
            let launchesBefore = await client.launches
            XCTAssertEqual(launchesBefore, 1)
            XCTAssertEqual(model.messages.map(\.text), ["hey"])
            await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertNil(model.errorMessage)
            await model.send("retry")
            XCTAssertEqual(model.phase, .ready)
            let launchesAfter = await client.launches
            XCTAssertEqual(launchesAfter, 2)
            await model.disconnect()
        }
    }

    @MainActor func testAuthenticationFailureDuringConfigurationAlsoStopsSession() async {
        let client = AuthenticationClient(failure: LatchAgentFailure(code: .authenticationRequired, message: "Authentication required"))
        let model = SessionModel(makeClient: { client })
        await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
        XCTAssertNotNil(model.configuration.model)
        await model.select(.model, value: "slow")
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.status, "Sign-in required")
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertEqual(model.configuration, SessionConfiguration())
        XCTAssertTrue(model.messages.isEmpty)
        let stops = await client.stops
        XCTAssertEqual(stops, 1)
    }

    @MainActor func testDisconnectWaitsForAuthenticationTeardown() async {
        let client = AuthenticationClient(failure: LatchAgentFailure(code: .authenticationRequired, message: "Expired"), holdStop: true)
        let model = SessionModel(makeClient: { client })
        await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
        let prompt = Task { await model.send("hey") }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await client.hasPendingStop), ContinuousClock.now < deadline { await Task.yield() }
        guard await client.hasPendingStop else {
            prompt.cancel()
            return XCTFail("Authentication teardown did not start")
        }
        var finished = false
        let closing = Task { await model.disconnect(); finished = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(finished)
        XCTAssertEqual(model.phase, .stopping)
        await client.releaseStop()
        await closing.value
        await prompt.value
        XCTAssertTrue(finished)
        XCTAssertEqual(model.phase, .disconnected)
        let stops = await client.stops
        XCTAssertEqual(stops, 1)
    }

    @MainActor func testOrdinaryFailureDoesNotDiscardReadySession() async {
        let client = AuthenticationClient(failure: LatchAgentFailure(code: .commandFailed, message: "Model unavailable"))
        let model = SessionModel(makeClient: { client })
        await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
        await model.send("hey")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.errorMessage, "Model unavailable")
        let stops = await client.stops
        XCTAssertEqual(stops, 0)
        await model.disconnect()
    }

    @MainActor func testStaleAuthenticationFailureCannotDisconnectNewSession() async {
        let client = AuthenticationClient(failure: LatchAgentFailure(code: .authenticationRequired, message: "Expired"), holdPrompt: true)
        let model = SessionModel(makeClient: { client })
        await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
        let oldPrompt = Task { await model.send("old") }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await client.hasPendingPrompt), ContinuousClock.now < deadline { await Task.yield() }
        guard await client.hasPendingPrompt else {
            oldPrompt.cancel()
            await model.disconnect()
            return XCTFail("Mock prompt did not start")
        }
        await model.disconnect()
        await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
        await client.releasePrompt()
        await oldPrompt.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.errorMessage)
        let stops = await client.stops
        XCTAssertEqual(stops, 1)
        await model.disconnect()
    }
}

private actor AuthenticationClient: AgentServiceClient {
    nonisolated let events: AsyncStream<LatchAgentEvent>
    nonisolated let transportDescription = "mock authentication client"
    private nonisolated let continuation: AsyncStream<LatchAgentEvent>.Continuation
    let failure: any Error
    let holdPrompt: Bool
    let holdStop: Bool
    private var pendingStop: CheckedContinuation<Void, Never>?
    var hasPendingStop: Bool { pendingStop != nil }
    private var pendingPrompt: CheckedContinuation<Void, Never>?
    var hasPendingPrompt: Bool { pendingPrompt != nil }
    private var rejected = false
    private(set) var launches = 0
    private(set) var stops = 0

    init(failure: any Error, holdPrompt: Bool = false, holdStop: Bool = false) {
        self.failure = failure
        self.holdPrompt = holdPrompt
        self.holdStop = holdStop
        let pair = AsyncStream<LatchAgentEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    nonisolated func close() { continuation.finish() }
    func releasePrompt() { pendingPrompt?.resume(); pendingPrompt = nil }
    func releaseStop() { pendingStop?.resume(); pendingStop = nil }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .startRuntime(id, _):
            launches += 1
            return .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init(loadSession: true)))
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: "session-\(launches)", configOptions: [
                .object(["id": .string("model"), "name": .string("Model"), "type": .string("select"),
                         "currentValue": .string("fast"), "options": .array([
                            .object(["value": .string("fast"), "name": .string("Fast")]),
                            .object(["value": .string("slow"), "name": .string("Slow")]),
                         ])]),
            ]))
        case let .loadSession(id, _, _):
            return .sessionLoaded(runtimeID: id, response: ACPLoadSessionResponse())
        case .setSessionConfigOption:
            throw failure
        case let .prompt(id, _):
            if !rejected {
                rejected = true
                if holdPrompt { await withCheckedContinuation { pendingPrompt = $0 } }
                throw failure
            }
            return .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn"))
        case let .stopRuntime(id):
            stops += 1
            if holdStop { await withCheckedContinuation { pendingStop = $0 } }
            return .runtimeStopped(runtimeID: id)
        default:
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected test command")
        }
    }
}
