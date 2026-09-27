import Foundation
import LatchACP
import LatchServiceProtocol

public struct LatchRemoteLifecycle: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let starting = LatchRemoteLifecycle(rawValue: "starting")
    public static let ready = LatchRemoteLifecycle(rawValue: "ready")
    public static let exited = LatchRemoteLifecycle(rawValue: "exited")
}

public struct LatchRemoteTurnState: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let running = LatchRemoteTurnState(rawValue: "running")
    public static let ended = LatchRemoteTurnState(rawValue: "ended")
}

public struct LatchRemoteTurnRecord: Codable, Equatable, Sendable {
    public var turnID: UUID
    public var state: LatchRemoteTurnState
    public var stopReason: String?
    public var error: LatchRemoteError?

    public init(turnID: UUID, state: LatchRemoteTurnState, stopReason: String? = nil, error: LatchRemoteError? = nil) {
        self.turnID = turnID
        self.state = state
        self.stopReason = stopReason
        self.error = error
    }
}

public struct LatchRemotePendingPermission: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var request: ACPPermissionRequest

    public init(requestID: UUID, request: ACPPermissionRequest) {
        self.requestID = requestID
        self.request = request
    }
}

/// How the runtime's session was bound, with the agent's reply.
public enum LatchRemoteSessionBinding: Equatable, Sendable {
    case new(ACPNewSessionResponse)
    case load(ACPLoadSessionResponse)
    /// A binding from a newer server.
    case unknown(kind: String)
}

extension LatchRemoteSessionBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case response
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "new":
            self = .new(try container.decode(ACPNewSessionResponse.self, forKey: .response))
        case "load":
            self = .load(try container.decode(ACPLoadSessionResponse.self, forKey: .response))
        case let kind:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .new(response):
            try container.encode("new", forKey: .kind)
            try container.encode(response, forKey: .response)
        case let .load(response):
            try container.encode("load", forKey: .kind)
            try container.encode(response, forKey: .response)
        case let .unknown(kind):
            try container.encode(kind, forKey: .kind)
        }
    }
}

/// Everything a client needs to rebuild a runtime's state on attach, before its backlog.
public struct LatchRemoteRuntimeRecord: Codable, Equatable, Sendable {
    @LatchRemoteRuntimeIDCoding public var runtimeID: AgentRuntimeID
    public var agent: LatchRemoteAgent
    public var agentTitle: String
    public var workspace: String
    public var lifecycle: LatchRemoteLifecycle
    public var exit: LatchRemoteExit?
    public var initialization: ACPInitializeResponse?
    public var sessionID: String?
    public var session: LatchRemoteSessionBinding?
    /// The latest notification of each state kind, such as `current_mode_update`.
    public var state: [ACPSessionNotification]
    /// The latest per route.
    public var configurationSets: [LatchRemoteConfigurationSet]
    public var activeTurnID: UUID?
    /// The most recent turns, oldest first.
    public var turns: [LatchRemoteTurnRecord]
    /// In the order they were raised.
    public var pendingPermissions: [LatchRemotePendingPermission]
    public var lastSequence: UInt64
    /// The ACP `localSequence` of the `loadSession` reply; replayed history at or below it
    /// is not journaled.
    public var loadedThrough: UInt64?

    public init(
        runtimeID: AgentRuntimeID,
        agent: LatchRemoteAgent,
        agentTitle: String,
        workspace: String,
        lifecycle: LatchRemoteLifecycle,
        exit: LatchRemoteExit? = nil,
        initialization: ACPInitializeResponse? = nil,
        sessionID: String? = nil,
        session: LatchRemoteSessionBinding? = nil,
        state: [ACPSessionNotification] = [],
        configurationSets: [LatchRemoteConfigurationSet] = [],
        activeTurnID: UUID? = nil,
        turns: [LatchRemoteTurnRecord] = [],
        pendingPermissions: [LatchRemotePendingPermission] = [],
        lastSequence: UInt64 = 0,
        loadedThrough: UInt64? = nil
    ) {
        self.runtimeID = runtimeID
        self.agent = agent
        self.agentTitle = agentTitle
        self.workspace = workspace
        self.lifecycle = lifecycle
        self.exit = exit
        self.initialization = initialization
        self.sessionID = sessionID
        self.session = session
        self.state = state
        self.configurationSets = configurationSets
        self.activeTurnID = activeTurnID
        self.turns = turns
        self.pendingPermissions = pendingPermissions
        self.lastSequence = lastSequence
        self.loadedThrough = loadedThrough
    }
}

public struct LatchRemoteRuntimeSummary: Codable, Equatable, Sendable {
    @LatchRemoteRuntimeIDCoding public var runtimeID: AgentRuntimeID
    public var agentTitle: String
    public var workspace: String
    public var lifecycle: LatchRemoteLifecycle
    public var activeTurnID: UUID?
    public var pendingPermissionCount: Int
    public var lastSequence: UInt64

    public init(
        runtimeID: AgentRuntimeID,
        agentTitle: String,
        workspace: String,
        lifecycle: LatchRemoteLifecycle,
        activeTurnID: UUID? = nil,
        pendingPermissionCount: Int = 0,
        lastSequence: UInt64 = 0
    ) {
        self.runtimeID = runtimeID
        self.agentTitle = agentTitle
        self.workspace = workspace
        self.lifecycle = lifecycle
        self.activeTurnID = activeTurnID
        self.pendingPermissionCount = pendingPermissionCount
        self.lastSequence = lastSequence
    }
}
