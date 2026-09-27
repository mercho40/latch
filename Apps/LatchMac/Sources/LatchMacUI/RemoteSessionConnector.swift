import Foundation
import LatchAgentCore
import LatchServiceProtocol

/// The one place a remote-located session meets the network. A remote session's model gets
/// every channel it uses from `makeClient`, and launches through that channel's
/// `launch(.remote(agent:path:), id:)`, so nothing a remote session does can reach this
/// Mac's service or run a command here.
@MainActor
protocol RemoteSessionConnector: AnyObject {
    /// The service channel for one session on this server. Called when the session's model
    /// is created, and again whenever that model needs a fresh channel.
    func makeClient(serverID: UUID) -> AgentServiceClient
}

/// A failure to reach a server, as opposed to one the agent on it reported. The banner names
/// the server rather than the agent for these.
protocol RemoteConnectionFailure: Error {}

/// Used until a transport is supplied: remote sessions exist, save and restore, but every
/// launch fails at once, so none can fall through to a local one.
@MainActor
final class UnconnectedRemoteSessionConnector: RemoteSessionConnector {
    func makeClient(serverID: UUID) -> AgentServiceClient { UnconnectedAgentServiceClient() }
}

/// A channel that reaches nothing. Its event stream stays open until it is closed, because
/// a finished stream reads to `SessionModel` as a lost service and it would reopen one.
final class UnconnectedAgentServiceClient: AgentServiceClient {
    let events: AsyncStream<LatchAgentEvent>
    private let continuation: AsyncStream<LatchAgentEvent>.Continuation

    init() { (events, continuation) = AsyncStream.makeStream() }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        throw RemoteSessionNotConnected()
    }

    func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        throw RemoteSessionNotConnected()
    }

    func close() { continuation.finish() }

    var transportDescription: String { "remote (not connected)" }
}

struct RemoteSessionNotConnected: RemoteConnectionFailure, LocalizedError {
    var errorDescription: String? { "Not connected." }
}
