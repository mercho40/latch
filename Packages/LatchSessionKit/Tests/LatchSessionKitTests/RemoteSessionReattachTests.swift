#if os(macOS)
import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKitTestSupport
import Synchronization
import XCTest
@testable import LatchSessionKit

/// Re-attaching to a runtime a saved binding points at, without a window: what the binding
/// saves, and how the model takes in the record and the backlog. The Mac app's tests quit and
/// relaunch a real window around the same server.
@MainActor
final class RemoteSessionReattachTests: XCTestCase {
    private let quickBackoff = LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200))

    private func connector(_ server: LoopbackServer, backoff: LatchRemoteBackoff? = nil) -> ChannelRemoteSessionConnector {
        ChannelRemoteSessionConnector(servers: server.store, backoff: backoff ?? quickBackoff)
    }

    /// Another client that has followed the runtime since before the turn, and so saw all of it.
    private func observer(of id: AgentRuntimeID, _ server: LoopbackServer) async throws -> SessionModel {
        let connector = connector(server)
        let model = SessionModel(makeClient: { connector.makeClient(serverID: server.profile.id) })
        model.restore(messages: [], agentSessionID: "session-1",
                      remote: SavedSession.RemoteBinding(runtimeID: id.rawValue, cursor: 0))
        await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
        XCTAssertEqual(model.phase, .ready)
        return model
    }

    private func texts(_ model: SessionModel) -> [String] { model.messages.map(\.text) }

    // MARK: Saving

    func testABindingIsSavedWithItsSessionAndOnlyForOneOnAServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteBinding-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let prompt = ChatMessage(role: .user, text: "tools please")
        let binding = SavedSession.RemoteBinding(runtimeID: UUID().uuidString, cursor: 41,
                                                 boundaryMessageID: prompt.id, boundaryTurnID: UUID())
        var remote = SavedSession(id: UUID(), workspacePath: "/srv/app", title: "Remote", agentID: "codex",
                                  customCommand: "", draft: "", messages: [prompt], agentSessionID: "ctx",
                                  serverID: UUID(), remote: binding)
        try await store.save(SavedSessionLibrary(sessions: [remote], selectedSessionID: nil))
        let restored = try await SessionStore(directory: directory).load()
        XCTAssertEqual(restored.version, 2)
        XCTAssertEqual(restored.sessions.first?.remote, binding)

        remote.serverID = nil
        do {
            try await store.save(SavedSessionLibrary(sessions: [remote], selectedSessionID: nil))
            XCTFail("A session on this Mac cannot have left a runtime on a server")
        } catch {
            XCTAssertEqual(error as? SessionStore.StoreError, .invalidLibrary)
        }

        // Written before bindings existed: no key, no binding.
        let old = Data("""
        {"version":2,"sessions":[{"id":"00000000-0000-0000-0000-000000000001","workspacePath":"/srv/app",
          "title":"Old","agentID":"codex","customCommand":"","draft":"","messages":[],"agentSessionID":"ctx",
          "serverID":"00000000-0000-0000-0000-000000000002"}]}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(SavedSessionLibrary.self, from: old).sessions[0].remote)
    }

    /// A sequence saved from a server can be anything it sent, the largest there is included,
    /// and every launch attaches with it.
    func testASavedCursorAtTheLargestSequenceAttachesWithoutCrashing() async throws {
        try await LoopbackServer.run { server in
            let first = try await observer(of: AgentRuntimeID("unused"), server)
            let id = try await server.onlyRuntime()
            await first.detach()
            let connector = connector(server)
            let model = SessionModel(makeClient: { connector.makeClient(serverID: server.profile.id) })
            model.restore(messages: [], agentSessionID: "session-1",
                          remote: SavedSession.RemoteBinding(runtimeID: id.rawValue, cursor: .max))
            await model.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertEqual(model.remoteBinding?.runtimeID, id.rawValue)
            XCTAssertLessThan(model.appliedSequence, .max, "Clamped to what the server has")
        }
    }

    /// A runtime another device started, taken up with nothing saved for it: all of its journal
    /// replays, its record names the agent to save, and one gone by then starts nothing.
    func testAdoptingARuntimeReplaysItAndLaunchesNothingOnceItIsGone() async throws {
        try await LoopbackServer.run { server in
            let connector = connector(server)
            let owner = SessionModel(makeClient: { connector.makeClient(serverID: server.profile.id) })
            await owner.connect(remote: .custom(server.agentCommand), path: server.workspace.path)
            await owner.send("hello")
            try await eventually("the owner's reply") { self.texts(owner) == ["hello", "onetwothree"] }
            let id = try await server.onlyRuntime()

            let model = SessionModel(makeClient: { connector.makeClient(serverID: server.profile.id) })
            XCTAssertNil(model.remoteAgent)
            await model.adopt(runtimeID: id)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertEqual(model.status, "Connected · mock-agent")
            XCTAssertEqual(model.remoteAgent, .custom(server.agentCommand))
            XCTAssertEqual(model.remoteWorkspace.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() },
                           server.workspace.resolvingSymlinksInPath())
            XCTAssertEqual(model.savedAgentSessionID, owner.savedAgentSessionID)
            try await eventually("the replayed journal") { self.texts(model) == ["hello", "onetwothree"] }
            XCTAssertEqual(model.remoteBinding?.runtimeID, id.rawValue)
            await model.detach()

            let late = SessionModel(makeClient: { connector.makeClient(serverID: server.profile.id) })
            await late.adopt(runtimeID: AgentRuntimeID(UUID().uuidString))
            XCTAssertEqual(late.phase, .disconnected)
            XCTAssertEqual(late.status, "Agent stopped")
            XCTAssertNotNil(late.errorMessage)
            XCTAssertNil(late.errorAdvice, "Nothing here knows what to start again")
            XCTAssertNil(late.remoteBinding)
            XCTAssertNil(late.remoteAgent)
            let only = try await server.onlyRuntime()
            XCTAssertEqual(only, id, "Nothing launched in its place")
        }
    }

    // MARK: The model alone

    /// An attach that was not truncated drops the turn's saved output for the journal to replay;
    /// eviction can still take part of it before it is read. What the Mac had saved stays.
    func testAGapInTheReplayOfSavedOutputPutsTheSavedOutputBack() async throws {
        for (next, lost) in [(UInt64(6), false), (7, true)] {
            let client = ReplayingRemoteClient(after: [
                .agent(.sessionUpdate(runtimeID: ReplayingRemoteClient.runtimeID, notification: Self.chunk("saved", 3)), sequence: 3),
                .outputLost(runtimeID: ReplayingRemoteClient.runtimeID, sequence: nil),
                .agent(.sessionUpdate(runtimeID: ReplayingRemoteClient.runtimeID, notification: Self.chunk("after", next)), sequence: next),
            ], lastSequence: next)
            let model = SessionModel(makeClient: { client })
            let prompt = ChatMessage(role: .user, text: "go")
            model.restore(messages: [prompt, ChatMessage(role: .assistant, text: "saved output")], agentSessionID: "remote-session",
                          remote: SavedSession.RemoteBinding(runtimeID: ReplayingRemoteClient.runtimeID.rawValue, cursor: 2,
                                                             boundaryMessageID: prompt.id, applied: 5))
            await model.connect(remote: .custom("agent"), path: "/srv/app")
            XCTAssertEqual(model.phase, .ready)
            try await eventually("the event after the gap") { model.appliedSequence == next }
            let expected = ["go", "saved output"] + (lost ? ["_Some output could not be shown._"] : []) + ["after"]
            XCTAssertEqual(texts(model), expected, "next \(next)")
        }
    }

    func testARequestDeliveredTwiceIsShownAndAnsweredOnce() async throws {
        let client = DuplicatingRemoteClient()
        let model = SessionModel(makeClient: { client })
        await model.connect(remote: .custom("agent"), path: "/srv/app")
        XCTAssertEqual(model.phase, .ready)
        var sheets: [UUID] = []
        model.onChange = { [weak model] in
            if let id = model?.permissions.current?.id, sheets.last != id { sheets.append(id) }
        }
        let sending = Task { await model.send("permission please") }
        // Both deliveries, and the event after them, have been taken in.
        try await eventually("the events after the request") { model.appliedSequence == 3 }
        let request = try XCTUnwrap(model.permissions.current)
        model.permissions.resolve(id: request.id, optionID: "allow")
        await sending.value
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(client.resolutions.count, 1)
        XCTAssertEqual(model.status, "Ready · end_turn")
    }
}

extension RemoteSessionReattachTests {
    static func chunk(_ text: String, _ sequence: UInt64) -> ACPSessionNotification {
        ACPSessionNotification(sessionId: "remote-session", update: .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ]), localSequence: sequence)
    }
}

/// A runtime a saved binding points at: the attach answers not truncated, and `backlog`
/// follows it, as the journal would deliver it.
private final class ReplayingRemoteClient: AgentServiceClient {
    static let runtimeID = AgentRuntimeID("replaying")
    let events: AsyncStream<LatchAgentEvent>
    let remoteEvents: AsyncStream<RemoteServiceEvent>?
    var isRemote: Bool { true }
    private let lifetime: AsyncStream<LatchAgentEvent>.Continuation
    private let continuation: AsyncStream<RemoteServiceEvent>.Continuation
    private let backlog: [RemoteServiceEvent]
    private let lastSequence: UInt64

    init(after backlog: [RemoteServiceEvent], lastSequence: UInt64) {
        self.backlog = backlog
        self.lastSequence = lastSequence
        (events, lifetime) = AsyncStream.makeStream()
        let (stream, continuation) = AsyncStream<RemoteServiceEvent>.makeStream()
        remoteEvents = stream
        self.continuation = continuation
    }

    func attach(runtimeID id: AgentRuntimeID, after cursor: UInt64) async throws -> LatchRemoteAttachment {
        let record = LatchRemoteRuntimeRecord(
            runtimeID: id, agent: .custom("agent"), agentTitle: "agent", workspace: "/srv/app", lifecycle: .ready,
            initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init()),
            sessionID: "remote-session", session: .new(ACPNewSessionResponse(sessionId: "remote-session")),
            lastSequence: lastSequence)
        let attachment = LatchRemoteAttachment(record: record, backlogFrom: cursor + 1, truncated: false)
        continuation.yield(.attached(runtimeID: id, attachment, server: "fake"))
        backlog.forEach { continuation.yield($0) }
        return attachment
    }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .stopRuntime(id): return .runtimeStopped(runtimeID: id)
        default: throw LatchAgentFailure(code: .commandFailed, message: "Unexpected command")
        }
    }

    func close() {
        continuation.finish()
        lifetime.finish()
    }

    var transportDescription: String { "remote test double" }
}

/// Delivers the one permission request of each prompt twice, as a server can after a
/// re-attach, and answers the prompt once the request is resolved.
private final class DuplicatingRemoteClient: AgentServiceClient {
    let events: AsyncStream<LatchAgentEvent>
    let remoteEvents: AsyncStream<RemoteServiceEvent>?
    var isRemote: Bool { true }
    private let lifetime: AsyncStream<LatchAgentEvent>.Continuation
    private let continuation: AsyncStream<RemoteServiceEvent>.Continuation
    private let state = Mutex<(resolutions: [ACPPermissionOutcome], waiter: CheckedContinuation<Void, Never>?)>(([], nil))

    init() {
        (events, lifetime) = AsyncStream.makeStream()
        let (stream, continuation) = AsyncStream<RemoteServiceEvent>.makeStream()
        remoteEvents = stream
        self.continuation = continuation
    }

    var resolutions: [ACPPermissionOutcome] { state.withLock { $0.resolutions } }

    func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init()))
    }

    func prompt(runtimeID id: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock]) async throws -> LatchAgentResponse {
        let requestID = UUID()
        let request = ACPPermissionRequest(sessionId: "remote-session", toolCall: .object(["toolCallId": .string("edit")]),
                                           options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")])
        await withCheckedContinuation { waiter in
            state.withLock { $0.waiter = waiter }
            for sequence in [UInt64(1), 2] {
                continuation.yield(.agent(.permissionRequested(runtimeID: id, requestID: requestID, request: request),
                                          sequence: sequence))
            }
            continuation.yield(.skipped(runtimeID: id, sequence: 3))
        }
        return .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn"))
    }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: "remote-session"))
        case let .resolvePermission(id, requestID, outcome):
            let waiter = state.withLock { state in
                state.resolutions.append(outcome)
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
            return .permissionResolved(runtimeID: id, requestID: requestID)
        case let .stopRuntime(id):
            return .runtimeStopped(runtimeID: id)
        default:
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected command")
        }
    }

    func close() {
        continuation.finish()
        lifetime.finish()
    }

    var transportDescription: String { "remote test double" }
}
#endif
