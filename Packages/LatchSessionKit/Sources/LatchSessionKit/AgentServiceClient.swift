import Foundation
import LatchACP
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol

/// What a session asks its service to start.
public enum AgentLaunch: Equatable, Sendable {
    /// A command already resolved on this Mac, run in a folder here.
    case local(ACPCommandProfile)
    /// An agent the server resolves and runs, in a folder on the server.
    case remote(agent: LatchRemoteAgent, path: String)
}

/// Whether a remote session's server can be reached right now. Separate from a session's
/// status: a lost link is not a failure until it is permanent, and nothing waits on it.
public enum SessionLinkState: Equatable, Sendable {
    case connected
    /// Lost at `since`; commands and the turn in flight wait for it to come back.
    case reconnecting(server: String, since: Date)
    /// For good, in plain words that name the server. The event stream finishes after it.
    /// `runtimeGone` when the server answered but no longer has the session's agent. Otherwise
    /// the link was turned away, not the agent: it is most likely still running there, so the
    /// session keeps its binding for Retry, or a change in Settings, to attach to again.
    case failed(server: String, reason: String, runtimeGone: Bool = false)
}

/// What a server's journal tells a session, in journal order. `sequence` is the journal's
/// position, which a session records as applied once it has taken the event in.
public enum RemoteServiceEvent: Sendable {
    /// Anything this Mac's service would also report. No sequence for a permission request
    /// raised again from a re-attach's record, or closed because the record no longer has it.
    case agent(LatchAgentEvent, sequence: UInt64?)
    /// History the agent replayed when a client loaded its session on the server. Only a
    /// session whose transcript this runtime's journal has built from its start shows it; the
    /// client that loaded it, and any other that has its transcript, already show it.
    case replayed(runtimeID: AgentRuntimeID, ACPSessionNotification, sequence: UInt64)
    /// A set-* command succeeded, from this client or another.
    case configurationSet(runtimeID: AgentRuntimeID, LatchRemoteConfigurationSet, sequence: UInt64)
    /// A turn began, from this client or another; `text` and `attachments` are its prompt.
    case turnStarted(runtimeID: AgentRuntimeID, turnID: UUID, text: String, attachments: [ChatAttachment], sequence: UInt64)
    /// A message a client sent into the running turn, where it went in.
    case promptSteered(runtimeID: AgentRuntimeID, turnID: UUID, text: String, attachments: [ChatAttachment], sequence: UInt64)
    case turnEnded(runtimeID: AgentRuntimeID, turnID: UUID, sequence: UInt64)
    /// Output that cannot be shown: evicted before this client read it, or too large to send.
    case outputLost(runtimeID: AgentRuntimeID, sequence: UInt64?)
    /// A journal event with nothing to show, such as one already delivered or of an unknown
    /// kind. It still moves the applied sequence.
    case skipped(runtimeID: AgentRuntimeID, sequence: UInt64)
    /// The agent was stopped on `server`, by another client or the server shutting down, rather
    /// than exiting on its own. Never for a stop this client asked for.
    case stopped(runtimeID: AgentRuntimeID, server: String, sequence: UInt64)
    /// A runtime left on `server` earlier, attached again. Comes before anything else from it,
    /// so the session rebuilds its state from the record before the backlog arrives.
    case attached(runtimeID: AgentRuntimeID, LatchRemoteAttachment, server: String)
    case link(SessionLinkState)
    /// Settings changed how the session's server is reached while the client followed no
    /// runtime. A session that kept one when its link failed attaches to it again. One the
    /// client follows is pointed at the server the new way in place, and hears nothing of it.
    case serverChanged
}

/// One session's command and event channel to a Latch Agent service, wherever it runs.
public protocol AgentServiceClient: AnyObject, Sendable {
    /// Single-consumer. Finishing means the view is stale and a new client is required.
    var events: AsyncStream<LatchAgentEvent> { get }
    /// A server's events with their journal sequences, and what only a server reports. When
    /// set, `SessionModel` reads this instead of `events`. Single-consumer, and finishing means
    /// the same. Nil for this Mac's service, which has no journal.
    var remoteEvents: AsyncStream<RemoteServiceEvent>? { get }
    /// The runtime is on a server, where other clients may share it.
    var isRemote: Bool { get }
    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse
    /// Starts the agent under `id` and answers `.runtimeStarted`. The only command that
    /// differs by transport, so `SessionModel` never needs to know which one it holds.
    func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse
    /// Runs a prompt and answers `.promptCompleted` when its turn ends. `turnID` is how a
    /// server tells a prompt sent again after a reconnect from a second one; this Mac's
    /// service has no use for it.
    func prompt(runtimeID: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock]) async throws -> LatchAgentResponse
    /// Follows a runtime left running on a server, such as by the last run of Latch: `.attached`
    /// and then its journal after `cursor` arrive on `remoteEvents`. Throws `RemoteRuntimeGone`
    /// when the server no longer has it.
    func attach(runtimeID: AgentRuntimeID, after cursor: UInt64) async throws -> LatchRemoteAttachment
    /// Waits for a turn that is already running, such as the one an attach's record shows,
    /// and answers as `prompt` does.
    func awaitTurn(runtimeID: AgentRuntimeID, turnID: UUID) async throws -> LatchAgentResponse
    /// Runs `blocks` as `prompt` does, or without them waits for the running turn as
    /// `awaitTurn` does, and says where the turn's events end.
    func endOfTurn(runtimeID: AgentRuntimeID, turnID: UUID, sending blocks: [ACPPromptBlock]?) async -> TurnEnd
    /// Stops following a runtime and leaves it running, for another run of Latch to attach
    /// to. Best effort, and never a stop.
    func detach(runtimeID: AgentRuntimeID) async
    /// Whether Settings now reaches the server differently from the last channel this client
    /// made. Always false on this Mac.
    func serverSettingsChangedSinceLastChannel() async -> Bool
    /// Releases the channel. In-process clients stop their runtimes; XPC clients only drop the connection.
    func close()
    /// Human-readable transport summary for diagnostics and the smoke test.
    var transportDescription: String { get }
}

extension AgentServiceClient {
    public var remoteEvents: AsyncStream<RemoteServiceEvent>? { nil }
    public var isRemote: Bool { false }

    /// This Mac's service runs local commands only; a remote client supplies its own.
    public func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        guard case let .local(profile) = launch else { throw RemoteSessionNotConnected() }
        return try await execute(.startRuntime(id: id, profile: profile))
    }

    public func prompt(runtimeID: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock]) async throws -> LatchAgentResponse {
        try await execute(.prompt(runtimeID: runtimeID, blocks: blocks))
    }

    /// Nothing outlives Latch on this Mac, so there is never a runtime to attach to again.
    public func attach(runtimeID: AgentRuntimeID, after cursor: UInt64) async throws -> LatchRemoteAttachment {
        throw RemoteSessionNotConnected()
    }

    public func awaitTurn(runtimeID: AgentRuntimeID, turnID: UUID) async throws -> LatchAgentResponse {
        throw RemoteSessionNotConnected()
    }

    public func endOfTurn(runtimeID: AgentRuntimeID, turnID: UUID, sending blocks: [ACPPromptBlock]?) async -> TurnEnd {
        do {
            guard let blocks else { return TurnEnd(.success(try await awaitTurn(runtimeID: runtimeID, turnID: turnID))) }
            return TurnEnd(.success(try await prompt(runtimeID: runtimeID, turnID: turnID, blocks: blocks)))
        } catch {
            return TurnEnd(.failure(error))
        }
    }

    public func detach(runtimeID: AgentRuntimeID) async {}

    public func serverSettingsChangedSinceLastChannel() async -> Bool { false }
}

/// How a turn ended, as `SessionModel` takes it in. The outcome travels apart from the turn's
/// events, so the session ends the turn only once it has taken in as many as the end names:
/// on a server `journaledThrough`, and on this Mac the reply's `updatesThrough`.
public struct TurnEnd: Sendable {
    public var result: Result<LatchAgentResponse, any Error>
    /// The journal sequence `remoteEvents` had delivered when the end was known: what the
    /// server journaled of the turn comes at or before it. Nil without a journal, or when the
    /// turn never ended there, as when the server refused the prompt.
    public var journaledThrough: UInt64?

    public init(_ result: Result<LatchAgentResponse, any Error>, journaledThrough: UInt64? = nil) {
        self.result = result
        self.journaledThrough = journaledThrough
    }
}

/// The server no longer has the runtime a session was bound to: it restarted, or reaped or
/// dropped the runtime while Latch was closed.
public struct RemoteRuntimeGone: LocalizedError, Equatable {
    /// The server that answered without it, as Settings named it then.
    public let server: String
    public var errorDescription: String? { RemoteAgentServiceClient.reason(for: .runtimeNotFound(message: ""), server: server) }
}
