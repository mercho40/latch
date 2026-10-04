import Foundation
import LatchACP
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import Synchronization
import XCTest
@testable import LatchiOSUI

/// A server channel that answers in memory: it launches, starts a session, runs a turn until
/// the test ends it, raises a permission request or asks a question, and attaches to a runtime with the record
/// and backlog a test gives it.
final class FakeClient: AgentServiceClient {
    let events: AsyncStream<LatchAgentEvent>
    let remoteEvents: AsyncStream<RemoteServiceEvent>?
    var isRemote: Bool { true }
    private let lifetime: AsyncStream<LatchAgentEvent>.Continuation
    private let continuation: AsyncStream<RemoteServiceEvent>.Continuation
    private let state = Mutex(State())

    struct State {
        var launched: AgentRuntimeID?
        var launches: [AgentLaunch] = []
        var attaches: [(String, UInt64)] = []
        var detaches: [String] = []
        var stops: [String] = []
        var turn: CheckedContinuation<Void, Never>?
        var record: LatchRemoteRuntimeRecord?
        var backlog: [RemoteServiceEvent] = []
        var attachFailure: (any Error & Sendable)?
        var unreachable = false
        var holdsAttaches = false
        var heldAttach: CheckedContinuation<Void, Never>?
    }

    init() {
        (events, lifetime) = AsyncStream.makeStream()
        let (stream, continuation) = AsyncStream<RemoteServiceEvent>.makeStream()
        remoteEvents = stream
        self.continuation = continuation
    }

    var snapshot: State { state.withLock { $0 } }

    /// What `attach` finds on the server.
    func serve(record: LatchRemoteRuntimeRecord, backlog: [RemoteServiceEvent]) {
        state.withLock {
            $0.record = record
            $0.backlog = backlog
        }
    }

    func failAttaches(with error: any Error & Sendable) { state.withLock { $0.attachFailure = error } }

    /// Attaches wait for `releaseAttach()`, then fail as a lost link does.
    func holdAttaches() { state.withLock { $0.holdsAttaches = true } }

    func releaseAttach() {
        let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.heldAttach = nil }
            return state.heldAttach
        }
        held?.resume()
    }

    /// Refuses everything, as a client made for a server not in Servers does.
    func refuseEverything() { state.withLock { $0.unreachable = true } }

    func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        let unreachable = state.withLock {
            $0.launches.append(launch)
            if !$0.unreachable { $0.launched = id }
            return $0.unreachable
        }
        if unreachable { throw RemoteSessionNotConnected.serverRemoved }
        return .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(
            protocolVersion: 1, agentCapabilities: .init(), agentInfo: .init(name: "fake", title: "Fake Agent", version: "1")))
    }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        if snapshot.unreachable { throw RemoteSessionNotConnected.serverRemoved }
        switch command {
        case let .newSession(id, _): return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: "session"))
        case let .stopRuntime(id):
            state.withLock { $0.stops.append(id.rawValue) }
            return .runtimeStopped(runtimeID: id)
        case let .resolvePermission(id, requestID, _): return .permissionResolved(runtimeID: id, requestID: requestID)
        case let .resolveElicitation(id, requestID, _): return .elicitationResolved(runtimeID: id, requestID: requestID)
        case let .cancelPrompt(id): return .promptCancellationRequested(runtimeID: id)
        default: throw LatchAgentFailure(code: .commandFailed, message: "Unexpected command")
        }
    }

    func prompt(runtimeID: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock]) async throws -> LatchAgentResponse {
        await withCheckedContinuation { continuation in state.withLock { $0.turn = continuation } }
        return .promptCompleted(runtimeID: runtimeID, response: ACPPromptResponse(stopReason: "end_turn"))
    }

    /// Ends the running turn.
    func finishTurn() {
        let turn = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.turn = nil }
            return state.turn
        }
        turn?.resume()
    }

    var isRunningTurn: Bool { state.withLock { $0.turn != nil } }

    func requestPermission() {
        guard let id = snapshot.launched else { return }
        let request = ACPPermissionRequest(sessionId: "session", toolCall: .object(["title": .string("Run tests")]),
                                           options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")])
        continuation.yield(.agent(.permissionRequested(runtimeID: id, requestID: UUID(), request: request), sequence: nil))
    }

    func ask(_ message: String = "Which database?") {
        guard let id = snapshot.launched else { return }
        let request = ACPElicitationRequest(sessionId: "session", message: message, requestedSchema: .object([
            "type": .string("object"),
            "properties": .object(["question_0": .object(["type": .string("string"), "enum": .array([.string("Postgres"), .string("SQLite")])])]),
        ]))
        continuation.yield(.agent(.elicitationRequested(runtimeID: id, requestID: UUID(), request: request), sequence: nil))
    }

    func attach(runtimeID id: AgentRuntimeID, after cursor: UInt64) async throws -> LatchRemoteAttachment {
        let (record, backlog, failure, unreachable, holds) = state.withLock { state in
            state.attaches.append((id.rawValue, cursor))
            return (state.record, state.backlog, state.attachFailure, state.unreachable, state.holdsAttaches)
        }
        if holds {
            await withCheckedContinuation { continuation in state.withLock { $0.heldAttach = continuation } }
            throw LatchRemoteClientError.connectionLost
        }
        if unreachable { throw RemoteSessionNotConnected.serverRemoved }
        if let failure { throw failure }
        guard var record else { throw RemoteSessionNotConnected.serverRemoved }
        record.runtimeID = id
        let attachment = LatchRemoteAttachment(record: record, backlogFrom: cursor + 1, truncated: false)
        continuation.yield(.attached(runtimeID: id, attachment, server: "fake"))
        backlog.forEach { continuation.yield($0) }
        return attachment
    }

    func detach(runtimeID: AgentRuntimeID) async {
        state.withLock { $0.detaches.append(runtimeID.rawValue) }
    }

    func close() {
        finishTurn()
        releaseAttach()
        continuation.finish()
        lifetime.finish()
    }

    var transportDescription: String { "fake" }

    static func record(agent: LatchRemoteAgent, workspace: String, lastSequence: UInt64 = 1) -> LatchRemoteRuntimeRecord {
        LatchRemoteRuntimeRecord(
            runtimeID: AgentRuntimeID("unused"), agent: agent, agentTitle: "Claude Code", workspace: workspace,
            lifecycle: .ready, initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init()),
            sessionID: "remote-session", session: .new(ACPNewSessionResponse(sessionId: "remote-session")),
            lastSequence: lastSequence)
    }
}

/// Hands every session on any server its own fake client, and keeps them for the test.
@MainActor
final class FakeConnector: RemoteSessionConnector {
    private(set) var clients: [FakeClient] = []
    var prepare: ((FakeClient) -> Void)?
    /// When set, a client for a server not in it refuses everything, as the channel
    /// connector's does.
    var servers: (any ServerStore)?

    func makeClient(serverID: UUID) -> AgentServiceClient {
        let client = FakeClient()
        prepare?(client)
        if let servers, servers.server(id: serverID) == nil { client.refuseEverything() }
        clients.append(client)
        return client
    }
}

enum Fake {
    static let token = LatchRemoteToken.generate()

    static func server(_ name: String, host: String? = nil, port: UInt16 = 7800, command: String = "") -> ServerProfile {
        ServerProfile(name: name, host: host ?? "\(name).example", port: port, token: .generate(), customCommand: command)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func summary(_ id: String = UUID().uuidString, agent: String = "Claude Code", workspace: String,
                        lifecycle: LatchRemoteLifecycle = .ready, working: Bool = false,
                        approvals: Int = 0) -> LatchRemoteRuntimeSummary {
        LatchRemoteRuntimeSummary(runtimeID: AgentRuntimeID(id), agentTitle: agent, workspace: workspace,
                                  lifecycle: lifecycle, activeTurnID: working ? UUID() : nil,
                                  pendingPermissionCount: approvals)
    }
}

extension XCTestCase {
    /// Polls the main actor until `condition` holds, for work that finishes on its own tasks.
    @MainActor
    func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(what)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

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
