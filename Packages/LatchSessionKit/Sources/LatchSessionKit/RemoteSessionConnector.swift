import Foundation
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol

/// The one place a remote-located session meets the network. A remote session's model gets
/// every channel it uses from `makeClient`, and launches through that channel's
/// `launch(.remote(agent:path:), id:)`, so nothing a remote session does can reach this
/// Mac's service or run a command here.
@MainActor
public protocol RemoteSessionConnector: AnyObject {
    /// The service channel for one session on this server. Called when the session's model
    /// is created, and again whenever that model needs a fresh channel.
    func makeClient(serverID: UUID) -> AgentServiceClient
}

/// A failure to reach a server, as opposed to one the agent on it reported. The banner names
/// the server rather than the agent for these.
public protocol RemoteConnectionFailure: Error {}

/// Used until a transport is supplied: remote sessions exist, save and restore, but every
/// launch fails at once, so none can fall through to a local one.
@MainActor
public final class UnconnectedRemoteSessionConnector: RemoteSessionConnector {
    public init() {}

    public func makeClient(serverID: UUID) -> AgentServiceClient { UnconnectedAgentServiceClient() }
}

/// Connects remote sessions through `LatchRemoteRuntimeChannel`, reading each server from
/// the store as its sessions launch or attach. When Settings changes a server, every client on
/// it is told, so its sessions reach their runtimes the new way and name the server anew.
/// Each app calls `probeAll()` when its connections are likely to have gone quietly: the Mac
/// on waking, iOS on becoming active.
@MainActor
public final class ChannelRemoteSessionConnector: NSObject, RemoteSessionConnector {
    public let servers: any ServerStore
    private let backoff: LatchRemoteBackoff
    private let firstConnectionLimit: Duration
    /// Every client handed out that is still alive, to wake them all at once.
    private var clients: [WeakClient] = []
    /// Each server a client was made for, as it was last seen, so its clients hear only of saves
    /// that changed it.
    private var known: [UUID: ServerProfile] = [:]

    private struct WeakClient {
        weak var client: RemoteAgentServiceClient?
    }

    /// Observes nothing about the device: whatever makes this connector calls `probeAll()`
    /// itself, as the Mac's initializer that takes a notification center does on waking.
    public init(servers: any ServerStore, backoff: LatchRemoteBackoff = LatchRemoteBackoff(),
                firstConnectionLimit: Duration = .seconds(15)) {
        self.servers = servers
        self.backoff = backoff
        self.firstConnectionLimit = firstConnectionLimit
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(serversChanged),
                                               name: .serverStoreDidChange, object: servers)
    }

    public func makeClient(serverID: UUID) -> AgentServiceClient {
        guard let server = servers.server(id: serverID) else {
            return UnconnectedAgentServiceClient(failure: RemoteSessionNotConnected.serverRemoved)
        }
        let client = RemoteAgentServiceClient(server: server, backoff: backoff, firstConnectionLimit: firstConnectionLimit) { [weak self] in
            self?.servers.server(id: serverID)
        }
        clients.removeAll { $0.client == nil }
        clients.append(WeakClient(client: client))
        known[serverID] = server
        return client
    }

    /// The clients still in use, for waking and for tests.
    public var liveClients: [RemoteAgentServiceClient] { clients.compactMap(\.client) }

    /// A device that slept, or an app the system suspended, has usually lost its connections
    /// without hearing so. Checking each link now reconnects at once rather than after a
    /// heartbeat or a backoff wait.
    @objc public func probeAll() {
        for client in liveClients {
            Task { await client.probe() }
        }
    }

    /// A saved server's clients are told of its new name, address, port, token or network
    /// setting; each decides what that changes for its session. A removed server's sessions
    /// keep what they have.
    @objc private func serversChanged() {
        var changed: [UUID: ServerProfile] = [:]
        for (id, before) in known {
            guard let now = servers.server(id: id), now != before else { continue }
            known[id] = now
            changed[id] = now
        }
        guard !changed.isEmpty else { return }
        for client in liveClients {
            if let server = changed[client.serverID] { client.serverChanged(to: server) }
        }
    }
}

/// A channel that reaches nothing. Its event stream stays open until it is closed, because
/// a finished stream reads to `SessionModel` as a lost service and it would reopen one.
final class UnconnectedAgentServiceClient: AgentServiceClient {
    let events: AsyncStream<LatchAgentEvent>
    private let continuation: AsyncStream<LatchAgentEvent>.Continuation
    private let failure: RemoteSessionNotConnected

    init(failure: RemoteSessionNotConnected = RemoteSessionNotConnected()) {
        self.failure = failure
        (events, continuation) = AsyncStream.makeStream()
    }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        throw failure
    }

    func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        throw failure
    }

    func attach(runtimeID: AgentRuntimeID, after cursor: UInt64) async throws -> LatchRemoteAttachment {
        throw failure
    }

    func close() { continuation.finish() }

    var transportDescription: String { "remote (not connected)" }
}

public struct RemoteSessionNotConnected: RemoteConnectionFailure, LocalizedError {
    public var message = "Not connected."
    public var errorDescription: String? { message }

    public static let serverRemoved = RemoteSessionNotConnected(message: "This session’s server is no longer in \(serversList).")
}

/// Every way a channel fails is a failure to reach its server.
extension LatchRemoteClientError: RemoteConnectionFailure {}
