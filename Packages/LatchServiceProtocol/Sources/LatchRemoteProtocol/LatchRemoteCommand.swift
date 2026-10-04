import Foundation
import LatchACP
import LatchServiceProtocol

/// What to launch. The server resolves both forms against its own environment; profiles and
/// environments never cross the network.
public enum LatchRemoteAgent: Codable, Hashable, Sendable {
    /// An `AgentPreset` raw value, such as `claudeCode`.
    case preset(String)
    /// A command line the server parses with `AgentCommand`.
    case custom(String)
    /// A form from a newer server, seen only in a record. A `launchAgent` carrying one is invalid.
    case unknown

    private enum CodingKeys: String, CodingKey {
        case preset
        case custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (try container.decodeIfPresent(String.self, forKey: .preset),
                try container.decodeIfPresent(String.self, forKey: .custom)) {
        case let (preset?, nil): self = .preset(preset)
        case let (nil, custom?): self = .custom(custom)
        default: self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .preset(preset): try container.encode(preset, forKey: .preset)
        case let .custom(command): try container.encode(command, forKey: .custom)
        case .unknown: break
        }
    }
}

/// A request's command, keyed by `kind`. An unknown kind decodes to `.unknown` so the server
/// can still answer the request's `id` with `unsupportedCommand`.
public enum LatchRemoteCommand: Equatable, Sendable {
    case launchAgent(runtimeID: AgentRuntimeID, agent: LatchRemoteAgent, workspace: String)
    /// The session's working directory is the runtime's workspace.
    case newSession(runtimeID: AgentRuntimeID)
    case loadSession(runtimeID: AgentRuntimeID, sessionID: String)
    case setConfigOption(runtimeID: AgentRuntimeID, configID: String, value: String)
    case setModel(runtimeID: AgentRuntimeID, modelID: String)
    case setMode(runtimeID: AgentRuntimeID, modeID: String)
    /// Accepted at once; the outcome arrives as `turnEnded`. Resending a known `turnID` is
    /// accepted again without running the turn twice.
    case prompt(runtimeID: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock])
    case cancelPrompt(runtimeID: AgentRuntimeID)
    case resolvePermission(runtimeID: AgentRuntimeID, requestID: UUID, outcome: ACPPermissionOutcome)
    /// A message into the running turn, for an agent that steers. `steerID` makes it safe to
    /// send again: the server answers a known one with what became of it.
    case steer(runtimeID: AgentRuntimeID, steerID: UUID, blocks: [ACPPromptBlock])
    /// The agent's saved sessions in the runtime's workspace.
    case listSessions(runtimeID: AgentRuntimeID)
    /// A copy of a session under a new ID. `forkID` makes it safe to send again: the server
    /// answers a known one with the fork it made, rather than making another.
    case forkSession(runtimeID: AgentRuntimeID, sessionID: String, forkID: UUID)
    /// Answers an `elicitationRequested` event; one answered already, or withdrawn, fails.
    case resolveElicitation(runtimeID: AgentRuntimeID, requestID: UUID, response: ACPElicitationResponse)
    /// Streams the runtime's events with a sequence above `after`; 0 is from the start.
    case attach(runtimeID: AgentRuntimeID, after: UInt64)
    case detach(runtimeID: AgentRuntimeID)
    case stopRuntime(runtimeID: AgentRuntimeID)
    case listRuntimes
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .launchAgent: "launchAgent"
        case .newSession: "newSession"
        case .loadSession: "loadSession"
        case .setConfigOption: "setConfigOption"
        case .setModel: "setModel"
        case .setMode: "setMode"
        case .prompt: "prompt"
        case .cancelPrompt: "cancelPrompt"
        case .resolvePermission: "resolvePermission"
        case .resolveElicitation: "resolveElicitation"
        case .steer: "steer"
        case .listSessions: "listSessions"
        case .forkSession: "forkSession"
        case .attach: "attach"
        case .detach: "detach"
        case .stopRuntime: "stopRuntime"
        case .listRuntimes: "listRuntimes"
        case let .unknown(kind): kind
        }
    }
}

extension LatchRemoteCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, runtimeID, agent, workspace, sessionID, configID, value, modelID, modeID
        case turnID, blocks, requestID, outcome, after, response, forkID, steerID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        func runtimeID() throws -> AgentRuntimeID { try container.decodeRuntimeID(forKey: .runtimeID) }
        func string(_ key: CodingKeys) throws -> String { try container.decode(String.self, forKey: key) }

        switch kind {
        case "launchAgent":
            let agent = try container.decode(LatchRemoteAgent.self, forKey: .agent)
            guard agent != .unknown else {
                throw DecodingError.dataCorruptedError(forKey: .agent, in: container, debugDescription: "An agent is exactly one of preset or custom")
            }
            self = .launchAgent(runtimeID: try runtimeID(), agent: agent, workspace: try string(.workspace))
        case "newSession":
            self = .newSession(runtimeID: try runtimeID())
        case "loadSession":
            self = .loadSession(runtimeID: try runtimeID(), sessionID: try string(.sessionID))
        case "setConfigOption":
            self = .setConfigOption(runtimeID: try runtimeID(), configID: try string(.configID), value: try string(.value))
        case "setModel":
            self = .setModel(runtimeID: try runtimeID(), modelID: try string(.modelID))
        case "setMode":
            self = .setMode(runtimeID: try runtimeID(), modeID: try string(.modeID))
        case "prompt":
            self = .prompt(
                runtimeID: try runtimeID(),
                turnID: try container.decode(UUID.self, forKey: .turnID),
                blocks: try container.decode([LatchRemotePromptBlockCoding].self, forKey: .blocks).map(\.block)
            )
        case "cancelPrompt":
            self = .cancelPrompt(runtimeID: try runtimeID())
        case "resolvePermission":
            self = .resolvePermission(
                runtimeID: try runtimeID(),
                requestID: try container.decode(UUID.self, forKey: .requestID),
                outcome: try container.decode(ACPPermissionOutcome.self, forKey: .outcome)
            )
        case "steer":
            self = .steer(runtimeID: try runtimeID(), steerID: try container.decode(UUID.self, forKey: .steerID),
                          blocks: try container.decode([LatchRemotePromptBlockCoding].self, forKey: .blocks).map(\.block))
        case "listSessions":
            self = .listSessions(runtimeID: try runtimeID())
        case "forkSession":
            self = .forkSession(runtimeID: try runtimeID(), sessionID: try string(.sessionID),
                                forkID: try container.decode(UUID.self, forKey: .forkID))
        case "resolveElicitation":
            self = .resolveElicitation(
                runtimeID: try runtimeID(),
                requestID: try container.decode(UUID.self, forKey: .requestID),
                response: try container.decode(ACPElicitationResponse.self, forKey: .response)
            )
        case "attach":
            self = .attach(runtimeID: try runtimeID(), after: try container.decode(UInt64.self, forKey: .after))
        case "detach":
            self = .detach(runtimeID: try runtimeID())
        case "stopRuntime":
            self = .stopRuntime(runtimeID: try runtimeID())
        case "listRuntimes":
            self = .listRuntimes
        default:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch self {
        case let .launchAgent(runtimeID, agent, workspace):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(agent, forKey: .agent)
            try container.encode(workspace, forKey: .workspace)
        case let .newSession(runtimeID), let .cancelPrompt(runtimeID), let .detach(runtimeID), let .stopRuntime(runtimeID):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
        case let .loadSession(runtimeID, sessionID):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(sessionID, forKey: .sessionID)
        case let .setConfigOption(runtimeID, configID, value):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(configID, forKey: .configID)
            try container.encode(value, forKey: .value)
        case let .setModel(runtimeID, modelID):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(modelID, forKey: .modelID)
        case let .setMode(runtimeID, modeID):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(modeID, forKey: .modeID)
        case let .prompt(runtimeID, turnID, blocks):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(turnID, forKey: .turnID)
            try container.encode(blocks.map(LatchRemotePromptBlockCoding.init), forKey: .blocks)
        case let .resolvePermission(runtimeID, requestID, outcome):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(outcome, forKey: .outcome)
        case let .steer(runtimeID, steerID, blocks):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(steerID, forKey: .steerID)
            try container.encode(blocks.map(LatchRemotePromptBlockCoding.init), forKey: .blocks)
        case let .listSessions(runtimeID):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
        case let .forkSession(runtimeID, sessionID, forkID):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(forkID, forKey: .forkID)
        case let .resolveElicitation(runtimeID, requestID, response):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(response, forKey: .response)
        case let .attach(runtimeID, after):
            try container.encodeRuntimeID(runtimeID, forKey: .runtimeID)
            try container.encode(after, forKey: .after)
        case .listRuntimes, .unknown:
            break
        }
    }
}

/// A prompt block in ACP's own content shape, such as `{"type":"text","text":…}`, rather than
/// `ACPPromptBlock`'s synthesized coding, so the network format does not move with LatchACP.
struct LatchRemotePromptBlockCoding: Codable {
    var block: ACPPromptBlock

    init(_ block: ACPPromptBlock) {
        self.block = block
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, uri, name
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            block = .text(try container.decode(String.self, forKey: .text))
        case "image":
            guard let data = Data(base64Encoded: try container.decode(String.self, forKey: .data)) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "Image data is not base64")
            }
            block = .image(data: data, mimeType: try container.decode(String.self, forKey: .mimeType))
        case "resource_link":
            block = .resourceLink(
                uri: try container.decode(String.self, forKey: .uri),
                name: try container.decode(String.self, forKey: .name),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
            )
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown prompt block \(type)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        try block.content.encode(to: encoder)
    }
}

/// A successful reply's result, keyed by `kind`. An unknown kind decodes to `.unknown`.
public enum LatchRemoteResponse: Equatable, Sendable {
    case launched(initialization: ACPInitializeResponse)
    case sessionCreated(response: ACPNewSessionResponse)
    case sessionLoaded(response: ACPLoadSessionResponse)
    case configOptionSet(response: ACPSetSessionConfigOptionResponse)
    case modelSet(sequence: UInt64)
    case modeSet(sequence: UInt64)
    case promptAccepted(turnID: UUID)
    case cancelRequested
    case permissionResolved
    case elicitationResolved
    /// False when no turn was running to take it: send it as a prompt.
    case steered(injected: Bool)
    case sessions([ACPSessionSummary])
    case sessionForked(sessionID: String)
    /// Events with a sequence from `backlogFrom` follow this reply. `truncated` means some
    /// after the requested cursor were already evicted.
    case attached(record: LatchRemoteRuntimeRecord, backlogFrom: UInt64, truncated: Bool)
    case detached
    case stopped
    case runtimes([LatchRemoteRuntimeSummary])
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .launched: "launched"
        case .sessionCreated: "sessionCreated"
        case .sessionLoaded: "sessionLoaded"
        case .configOptionSet: "configOptionSet"
        case .modelSet: "modelSet"
        case .modeSet: "modeSet"
        case .promptAccepted: "promptAccepted"
        case .cancelRequested: "cancelRequested"
        case .permissionResolved: "permissionResolved"
        case .elicitationResolved: "elicitationResolved"
        case .steered: "steered"
        case .sessions: "sessions"
        case .sessionForked: "sessionForked"
        case .attached: "attached"
        case .detached: "detached"
        case .stopped: "stopped"
        case .runtimes: "runtimes"
        case let .unknown(kind): kind
        }
    }
}

extension LatchRemoteResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, initialization, response, sequence, turnID, record, backlogFrom, truncated, runtimes, sessions, sessionID, injected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case "launched":
            self = .launched(initialization: try container.decode(ACPInitializeResponse.self, forKey: .initialization))
        case "sessionCreated":
            self = .sessionCreated(response: try container.decode(ACPNewSessionResponse.self, forKey: .response))
        case "sessionLoaded":
            self = .sessionLoaded(response: try container.decode(ACPLoadSessionResponse.self, forKey: .response))
        case "configOptionSet":
            self = .configOptionSet(response: try container.decode(ACPSetSessionConfigOptionResponse.self, forKey: .response))
        case "modelSet":
            self = .modelSet(sequence: try container.decode(UInt64.self, forKey: .sequence))
        case "modeSet":
            self = .modeSet(sequence: try container.decode(UInt64.self, forKey: .sequence))
        case "promptAccepted":
            self = .promptAccepted(turnID: try container.decode(UUID.self, forKey: .turnID))
        case "cancelRequested":
            self = .cancelRequested
        case "permissionResolved":
            self = .permissionResolved
        case "elicitationResolved":
            self = .elicitationResolved
        case "steered":
            self = .steered(injected: try container.decode(Bool.self, forKey: .injected))
        case "sessions":
            self = .sessions(try container.decode([ACPSessionSummary].self, forKey: .sessions))
        case "sessionForked":
            self = .sessionForked(sessionID: try container.decode(String.self, forKey: .sessionID))
        case "attached":
            self = .attached(
                record: try container.decode(LatchRemoteRuntimeRecord.self, forKey: .record),
                backlogFrom: try container.decode(UInt64.self, forKey: .backlogFrom),
                truncated: try container.decode(Bool.self, forKey: .truncated)
            )
        case "detached":
            self = .detached
        case "stopped":
            self = .stopped
        case "runtimes":
            self = .runtimes(try container.decode([LatchRemoteRuntimeSummary].self, forKey: .runtimes))
        default:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch self {
        case let .launched(initialization):
            try container.encode(initialization, forKey: .initialization)
        case let .sessionCreated(response):
            try container.encode(response, forKey: .response)
        case let .sessionLoaded(response):
            try container.encode(response, forKey: .response)
        case let .configOptionSet(response):
            try container.encode(response, forKey: .response)
        case let .modelSet(sequence), let .modeSet(sequence):
            try container.encode(sequence, forKey: .sequence)
        case let .promptAccepted(turnID):
            try container.encode(turnID, forKey: .turnID)
        case let .attached(record, backlogFrom, truncated):
            try container.encode(record, forKey: .record)
            try container.encode(backlogFrom, forKey: .backlogFrom)
            try container.encode(truncated, forKey: .truncated)
        case let .runtimes(runtimes):
            try container.encode(runtimes, forKey: .runtimes)
        case let .steered(injected):
            try container.encode(injected, forKey: .injected)
        case let .sessions(sessions):
            try container.encode(sessions, forKey: .sessions)
        case let .sessionForked(sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case .cancelRequested, .permissionResolved, .elicitationResolved, .detached, .stopped, .unknown:
            break
        }
    }
}
