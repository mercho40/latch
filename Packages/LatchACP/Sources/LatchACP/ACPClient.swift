import Foundation
import Synchronization

public struct ACPImplementation: Codable, Equatable, Sendable {
    public let name: String
    public let title: String?
    public let version: String

    public init(name: String, title: String? = nil, version: String) {
        self.name = name
        self.title = title
        self.version = version
    }
}

public struct ACPFileSystemCapabilities: Codable, Equatable, Sendable {
    public let readTextFile: Bool
    public let writeTextFile: Bool

    public init(readTextFile: Bool = false, writeTextFile: Bool = false) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }
}

public struct ACPClientCapabilities: Codable, Equatable, Sendable {
    public let fs: ACPFileSystemCapabilities
    public let terminal: Bool
    /// Which kinds of question the client answers: `{"form": {}}` for forms.
    public let elicitation: ACPJSONValue?
    public let meta: ACPJSONValue?

    public init(
        fs: ACPFileSystemCapabilities = ACPFileSystemCapabilities(),
        terminal: Bool = false,
        elicitation: ACPJSONValue? = nil,
        meta: ACPJSONValue? = nil
    ) {
        self.fs = fs
        self.terminal = terminal
        self.elicitation = elicitation
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case fs
        case terminal
        case elicitation
        case meta = "_meta"
    }
}

public struct ACPAgentCapabilities: Codable, Equatable, Sendable {
    public let loadSession: Bool
    public let promptCapabilities: ACPJSONValue?
    public let mcpCapabilities: ACPJSONValue?
    public let sessionCapabilities: ACPJSONValue?
    public let meta: ACPJSONValue?

    /// Whether the agent lists its saved sessions: `session/list`.
    public var listsSessions: Bool { sessionCapability("list") }
    /// Whether the agent forks a session: `session/fork`.
    public var forksSessions: Bool { sessionCapability("fork") }

    private func sessionCapability(_ name: String) -> Bool {
        guard case let .object(capabilities)? = sessionCapabilities, let value = capabilities[name] else { return false }
        return value != .null && value != .bool(false)
    }

    /// Whether a prompt may carry image blocks. Absent means no, per the protocol.
    public var acceptsImages: Bool {
        guard case let .object(capabilities)? = promptCapabilities else { return false }
        return capabilities["image"] == .bool(true)
    }

    public init(
        loadSession: Bool = false,
        promptCapabilities: ACPJSONValue? = nil,
        mcpCapabilities: ACPJSONValue? = nil,
        sessionCapabilities: ACPJSONValue? = nil,
        meta: ACPJSONValue? = nil
    ) {
        self.loadSession = loadSession
        self.promptCapabilities = promptCapabilities
        self.mcpCapabilities = mcpCapabilities
        self.sessionCapabilities = sessionCapabilities
        self.meta = meta
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loadSession = try container.decodeIfPresent(Bool.self, forKey: .loadSession) ?? false
        promptCapabilities = try container.decodeIfPresent(ACPJSONValue.self, forKey: .promptCapabilities)
        mcpCapabilities = try container.decodeIfPresent(ACPJSONValue.self, forKey: .mcpCapabilities)
        sessionCapabilities = try container.decodeIfPresent(ACPJSONValue.self, forKey: .sessionCapabilities)
        meta = try container.decodeIfPresent(ACPJSONValue.self, forKey: .meta)
    }

    private enum CodingKeys: String, CodingKey {
        case loadSession
        case promptCapabilities
        case mcpCapabilities
        case sessionCapabilities
        case meta = "_meta"
    }
}

public struct ACPAuthenticationMethod: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct ACPInitializeResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let agentCapabilities: ACPAgentCapabilities
    public let agentInfo: ACPImplementation?
    public let authMethods: [ACPAuthenticationMethod]?
    /// Only what Latch reads of the agent's `_meta`: whether it steers.
    public let meta: ACPJSONValue?

    public init(
        protocolVersion: Int,
        agentCapabilities: ACPAgentCapabilities,
        agentInfo: ACPImplementation? = nil,
        authMethods: [ACPAuthenticationMethod]? = nil,
        meta: ACPJSONValue? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.agentInfo = agentInfo
        self.authMethods = authMethods
        self.meta = meta
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        agentCapabilities = try container.decode(ACPAgentCapabilities.self, forKey: .agentCapabilities)
        agentInfo = try container.decodeIfPresent(ACPImplementation.self, forKey: .agentInfo)
        authMethods = try container.decodeIfPresent([ACPAuthenticationMethod].self, forKey: .authMethods)
        // The rest of an agent's `_meta` can be anything, and this is kept in records a server sends.
        let steering = try? container.decodeIfPresent(SteeringMeta.self, forKey: .meta)
        meta = steering?.steering?.supported == true ? .object(["steering": .object(["supported": .bool(true)])]) : nil
    }

    /// Whether a message can go into the turn the agent is working on, at its next step:
    /// `_session/steering`, as Claude Code offers.
    public var supportsSteering: Bool {
        guard case let .object(fields)? = meta, case let .object(steering)? = fields["steering"] else { return false }
        return steering["supported"] == .bool(true)
    }

    private struct SteeringMeta: Decodable {
        struct Steering: Decodable { let supported: Bool? }
        let steering: Steering?
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, agentCapabilities, agentInfo, authMethods
        case meta = "_meta"
    }
}

/// How a message sent into a running turn fared.
public enum ACPSteerOutcome: Equatable, Sendable {
    /// In the running turn; the agent takes it at its next step.
    case injected
    /// No turn was running, and the agent began one with it, as an agent that predates
    /// `idleBehavior` does. Taken all the same: sending it again would say it twice.
    case startedNewTurn
    /// No turn was running: send it as a prompt of its own.
    case promptRequired
}

public struct ACPNewSessionResponse: Codable, Equatable, Sendable {
    public let sessionId: String
    public let modes: ACPJSONValue?
    public let models: ACPJSONValue?
    public let configOptions: [ACPJSONValue]?
    public let meta: ACPJSONValue?
    public let localSequence: UInt64?

    public init(
        sessionId: String,
        modes: ACPJSONValue? = nil,
        models: ACPJSONValue? = nil,
        configOptions: [ACPJSONValue]? = nil,
        meta: ACPJSONValue? = nil,
        localSequence: UInt64? = nil
    ) {
        self.sessionId = sessionId
        self.modes = modes
        self.models = models
        self.configOptions = configOptions
        self.meta = meta
        self.localSequence = localSequence
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case modes
        case models
        case configOptions
        case localSequence
        case meta = "_meta"
    }
}

public struct ACPSetSessionConfigOptionResponse: Codable, Equatable, Sendable {
    public let configOptions: [ACPJSONValue]
    public let localSequence: UInt64?

    public init(configOptions: [ACPJSONValue], localSequence: UInt64? = nil) {
        self.configOptions = configOptions
        self.localSequence = localSequence
    }
}

public enum ACPClientError: Error, Equatable, Sendable {
    case initializeRequired
    case initializationAlreadyAttempted
    case noActiveSession
    case promptAlreadyActive
    case loadSessionUnsupported
    case sessionOperationSuperseded
    case unsupportedProtocolVersion(expected: Int, received: Int)
    /// An answer this client cannot read the outcome of.
    case unexpectedResponse(String)
}

/// Typed ACP operations layered directly on a generic JSON-RPC connection.
public actor ACPClient {
    public static let protocolVersion = 1

    private enum State {
        case idle
        case initializing
        case initialized(ACPInitializeResponse)
        case failed
    }

    private struct InitializeRequest: Encodable {
        let protocolVersion: Int
        let clientCapabilities: ACPClientCapabilities
        let clientInfo: ACPImplementation
    }

    private struct AuthenticateRequest: Encodable {
        let methodId: String
    }

    private struct LoadSessionRequest: Encodable {
        let sessionId: String
        let cwd: String
        let mcpServers: [ACPJSONValue]
    }

    private struct NewSessionRequest: Encodable {
        let cwd: String
        let mcpServers: [ACPJSONValue]
    }

    private struct SetSessionConfigOptionRequest: Encodable {
        let sessionId: String
        let configId: String
        let value: String
    }

    private struct SetSessionModelRequest: Encodable {
        let sessionId: String
        let modelId: String
    }

    private struct SetSessionModeRequest: Encodable {
        let sessionId: String
        let modeId: String
    }

    private struct PromptRequest: Encodable {
        let sessionId: String
        let prompt: [ACPJSONValue]
    }

    private struct CancelRequest: Encodable {
        let sessionId: String
    }

    private struct PermissionResponse: Encodable {
        let outcome: ACPPermissionOutcome
    }

    private struct EmptyResponse: Decodable, Sendable {}

    public nonisolated let sessionUpdates: AsyncStream<ACPSessionNotification>
    private let updateProgress: UpdateProgress

    private let connection: ACPJSONRPCConnection
    private var state = State.idle
    private var activeSessionID: String?
    private var sessionGeneration: UInt64 = 0
    private var promptIsActive = false
    private var permissionHandler: (@Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome)?
    private var elicitationHandler: (@Sendable (ACPElicitationRequest) async -> ACPElicitationResponse)?

    public init(connection: ACPJSONRPCConnection) {
        self.connection = connection
        let pair = AsyncStream<ACPSessionNotification>.makeStream()
        self.sessionUpdates = pair.stream
        let progress = UpdateProgress()
        self.updateProgress = progress

        Task {
            for await notification in connection.notifications {
                var update: ACPSessionNotification?
                if notification.method == "session/update", let params = notification.params {
                    update = try? Self.decodeSessionValue(
                        params, sequence: notification.sequence, as: ACPSessionNotification.self
                    )
                }
                if let update { pair.continuation.yield(update) }
                progress.took(notification.sequence, update: update != nil)
            }
            pair.continuation.finish()
            progress.finish()
        }
    }

    @discardableResult
    public func initialize(
        clientInfo: ACPImplementation,
        capabilities: ACPClientCapabilities = ACPClientCapabilities()
    ) async throws -> ACPInitializeResponse {
        guard case .idle = state else {
            throw ACPClientError.initializationAlreadyAttempted
        }
        state = .initializing

        do {
            let request = InitializeRequest(
                protocolVersion: Self.protocolVersion,
                clientCapabilities: capabilities,
                clientInfo: clientInfo
            )
            let response: ACPInitializeResponse = try await connection.request(
                "initialize",
                params: try ACPJSONValue.encode(request)
            )
            guard response.protocolVersion == Self.protocolVersion else {
                state = .failed
                throw ACPClientError.unsupportedProtocolVersion(
                    expected: Self.protocolVersion,
                    received: response.protocolVersion
                )
            }
            state = .initialized(response)
            return response
        } catch {
            state = .failed
            throw error
        }
    }

    public func authenticate(methodID: String) async throws {
        try requireInitialized()
        let request = AuthenticateRequest(methodId: methodID)
        let _: EmptyResponse = try await connection.request(
            "authenticate",
            params: try ACPJSONValue.encode(request)
        )
    }

    public func newSession(
        cwd: String,
        mcpServers: [ACPJSONValue] = []
    ) async throws -> ACPNewSessionResponse {
        try requireInitialized()
        guard !promptIsActive else { throw ACPClientError.promptAlreadyActive }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        activeSessionID = nil
        let request = NewSessionRequest(cwd: cwd, mcpServers: mcpServers)
        let received = try await connection.requestWithSequence(
            "session/new",
            params: try ACPJSONValue.encode(request),
            as: ACPJSONValue.self
        )
        let response = try Self.decodeSessionValue(
            received.response, sequence: received.sequence, as: ACPNewSessionResponse.self
        )
        guard generation == sessionGeneration else { throw ACPClientError.sessionOperationSuperseded }
        activeSessionID = response.sessionId
        return response
    }

    /// Select the persisted session before suspension so operations during load replay
    /// address it. Notifications remain unfiltered, just as for session/new; consumers
    /// own session/generation filtering and replay presentation.
    public func loadSession(
        sessionID: String,
        cwd: String,
        mcpServers: [ACPJSONValue] = []
    ) async throws -> ACPLoadSessionResponse {
        guard try negotiatedCapabilities().loadSession else {
            throw ACPClientError.loadSessionUnsupported
        }
        guard !promptIsActive else { throw ACPClientError.promptAlreadyActive }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        activeSessionID = sessionID
        do {
            let request = LoadSessionRequest(sessionId: sessionID, cwd: cwd, mcpServers: mcpServers)
            let received = try await connection.requestWithSequence(
                "session/load",
                params: try ACPJSONValue.encode(request),
                as: ACPJSONValue.self
            )
            guard generation == sessionGeneration else { throw ACPClientError.sessionOperationSuperseded }
            return try Self.decodeSessionValue(
                received.response, sequence: received.sequence, as: ACPLoadSessionResponse.self
            )
        } catch {
            // A stale failure must not clear a newer new/load selection.
            if generation == sessionGeneration { activeSessionID = nil }
            throw error
        }
    }

    public func setSessionConfigOption(
        configID: String,
        value: String
    ) async throws -> ACPSetSessionConfigOptionResponse {
        try requireInitialized()
        guard let activeSessionID else {
            throw ACPClientError.noActiveSession
        }
        let request = SetSessionConfigOptionRequest(
            sessionId: activeSessionID,
            configId: configID,
            value: value
        )
        let received = try await connection.requestWithSequence(
            "session/set_config_option",
            params: try ACPJSONValue.encode(request),
            as: ACPJSONValue.self
        )
        return try Self.decodeSessionValue(
            received.response, sequence: received.sequence, as: ACPSetSessionConfigOptionResponse.self
        )
    }

    @discardableResult
    public func setSessionModel(modelID: String) async throws -> UInt64 {
        try requireInitialized()
        guard let activeSessionID else {
            throw ACPClientError.noActiveSession
        }
        let request = SetSessionModelRequest(sessionId: activeSessionID, modelId: modelID)
        let received = try await connection.requestWithSequence(
            "session/set_model",
            params: try ACPJSONValue.encode(request),
            as: EmptyResponse.self
        )
        return received.sequence
    }

    @discardableResult
    public func setSessionMode(modeID: String) async throws -> UInt64 {
        try requireInitialized()
        guard let activeSessionID else {
            throw ACPClientError.noActiveSession
        }
        let request = SetSessionModeRequest(sessionId: activeSessionID, modeId: modeID)
        let received = try await connection.requestWithSequence(
            "session/set_mode",
            params: try ACPJSONValue.encode(request),
            as: EmptyResponse.self
        )
        return received.sequence
    }

    public func prompt(_ text: String) async throws -> ACPPromptResponse {
        try await prompt([.text(text)])
    }

    public func prompt(_ blocks: [ACPPromptBlock]) async throws -> ACPPromptResponse {
        try requireInitialized()
        guard let activeSessionID else {
            throw ACPClientError.noActiveSession
        }
        guard !promptIsActive else {
            throw ACPClientError.promptAlreadyActive
        }

        promptIsActive = true
        defer { promptIsActive = false }
        let request = PromptRequest(
            sessionId: activeSessionID,
            prompt: blocks.map(\.content)
        )
        let received = try await connection.requestWithSequence(
            "session/prompt",
            params: try ACPJSONValue.encode(request),
            as: ACPJSONValue.self
        )
        // The turn's last updates may still be on their way to `sessionUpdates`; the reply says
        // where they end once they are all there.
        let updatesThrough = await updateProgress.lastUpdate(through: received.notifiedThrough)
        return try Self.decodeSessionValue(
            received.response, sequence: updatesThrough, key: "updatesThrough", as: ACPPromptResponse.self
        )
    }

    /// The agent's saved sessions, in `cwd` when given; Claude Code's include those started
    /// from its own command line.
    public func listSessions(cwd: String?) async throws -> [ACPSessionSummary] {
        try requireInitialized()
        var params: [String: ACPJSONValue] = [:]
        if let cwd { params["cwd"] = .string(cwd) }
        let response: SessionList = try await connection.request("session/list", params: .object(params))
        return response.sessions
    }

    /// A copy of the session `sessionID` under a new ID, which is not live: load it to go on with it.
    public func forkSession(sessionID: String, cwd: String) async throws -> String {
        try requireInitialized()
        let response: ForkedSession = try await connection.request(
            "session/fork", params: .object(["sessionId": .string(sessionID), "cwd": .string(cwd), "mcpServers": .array([])])
        )
        return response.sessionId
    }

    /// A message into the turn the agent is working on, for an agent that steers. One that
    /// finds no turn running is left to the caller to send as a prompt.
    public func steer(_ blocks: [ACPPromptBlock]) async throws -> ACPSteerOutcome {
        try requireInitialized()
        guard let activeSessionID else { throw ACPClientError.noActiveSession }
        let response: SteerResponse = try await connection.request("_session/steering", params: .object([
            "sessionId": .string(activeSessionID),
            "prompt": .array(blocks.map(\.content)),
            "_meta": .object(["steering": .object(["idleBehavior": .string("promptRequired")])]),
        ]))
        switch response.outcome {
        case "injected": return .injected
        case "startedNewTurn": return .startedNewTurn
        case "promptRequired": return .promptRequired
        // Whether the agent took it is unknown, so it is neither sent again nor counted as sent.
        default: throw ACPClientError.unexpectedResponse("_session/steering answered \(response.outcome.prefix(64))")
        }
    }

    private struct SteerResponse: Decodable, Sendable { let outcome: String }
    private struct SessionList: Decodable, Sendable { let sessions: [ACPSessionSummary] }
    private struct ForkedSession: Decodable, Sendable { let sessionId: String }

    public func cancelPrompt() async throws {
        try requireInitialized()
        guard let activeSessionID else {
            throw ACPClientError.noActiveSession
        }
        try await connection.notify(
            "session/cancel",
            params: try ACPJSONValue.encode(CancelRequest(sessionId: activeSessionID))
        )
    }

    public func setPermissionHandler(
        _ handler: (@Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome)?
    ) async {
        permissionHandler = handler
        await installRequestHandler()
    }

    /// Answers the agent's questions: `elicitation/create`.
    public func setElicitationHandler(
        _ handler: (@Sendable (ACPElicitationRequest) async -> ACPElicitationResponse)?
    ) async {
        elicitationHandler = handler
        await installRequestHandler()
    }

    /// The connection takes one handler for every request from the agent; this one passes each
    /// to the handler for its method, and any other method is not found.
    private func installRequestHandler() async {
        let permission = permissionHandler
        let elicitation = elicitationHandler
        guard permission != nil || elicitation != nil else {
            await connection.setRequestHandler(nil)
            return
        }
        await connection.setRequestHandler { request in
            switch request.method {
            case "session/request_permission":
                guard let permission, let params = request.params else { break }
                let permissionRequest = try params.decode(ACPPermissionRequest.self)
                return try ACPJSONValue.encode(PermissionResponse(outcome: await permission(permissionRequest)))
            case "elicitation/create":
                guard let elicitation, let params = request.params else { break }
                let elicitationRequest = try params.decode(ACPElicitationRequest.self)
                // A page to open is a question Latch never said it could take.
                guard elicitationRequest.mode == "form" else { return try ACPJSONValue.encode(ACPElicitationResponse.cancelled) }
                return try ACPJSONValue.encode(await elicitation(elicitationRequest))
            default:
                break
            }
            throw ACPJSONRPCErrorObject(code: -32601, message: "Method not found")
        }
    }

    public func negotiatedCapabilities() throws -> ACPAgentCapabilities {
        guard case let .initialized(response) = state else {
            throw ACPClientError.initializeRequired
        }
        return response.agentCapabilities
    }

    /// Replace untrusted wire metadata before decoding (including ill-typed forged values).
    /// Normal Codable decoding remains lossless for trusted service/XPC round-trips.
    private nonisolated static func decodeSessionValue<Value: Decodable>(
        _ value: ACPJSONValue,
        sequence: UInt64,
        key: String = "localSequence",
        as type: Value.Type
    ) throws -> Value {
        guard case var .object(object) = value else {
            return try value.decode(type)
        }
        object[key] = try ACPJSONValue.encode(sequence)
        return try ACPJSONValue.object(object).decode(type)
    }

    private func requireInitialized() throws {
        guard case .initialized = state else {
            throw ACPClientError.initializeRequired
        }
    }
}

/// How far `ACPClient`'s notification task has got: the last notification it took, and the
/// updates it passed on. A reply waits here until every notification before it has been
/// taken, so the update it names is on `sessionUpdates` already.
final class UpdateProgress: Sendable {
    private struct State {
        var taken: UInt64 = 0
        /// The updates passed on most recently, oldest first, for a reply that asks after the
        /// task has moved on past it.
        var recentUpdates: [UInt64] = []
        /// The newest update no longer in `recentUpdates`, or zero.
        var olderUpdate: UInt64 = 0
        var finished = false
        var waiters: [(through: UInt64, continuation: CheckedContinuation<UInt64, Never>)] = []

        /// The last update at or before `sequence`. Past the recent ones, the newest older
        /// update stands in: one already passed on, if perhaps later than asked.
        func lastUpdate(through sequence: UInt64) -> UInt64 {
            recentUpdates.last { $0 <= sequence } ?? olderUpdate
        }
    }

    static let recentLimit = 64
    private let state = Mutex(State())

    func took(_ sequence: UInt64, update: Bool) {
        let ready = state.withLock { state in
            state.taken = sequence
            if update {
                state.recentUpdates.append(sequence)
                if state.recentUpdates.count > Self.recentLimit { state.olderUpdate = state.recentUpdates.removeFirst() }
            }
            let ready = state.waiters.filter { $0.through <= sequence }
            state.waiters.removeAll { $0.through <= sequence }
            return ready.map { ($0.continuation, state.lastUpdate(through: $0.through)) }
        }
        for (continuation, lastUpdate) in ready { continuation.resume(returning: lastUpdate) }
    }

    /// The connection closed: nothing more will be taken.
    func finish() {
        let waiters = state.withLock { state in
            state.finished = true
            defer { state.waiters = [] }
            return state.waiters.map { ($0.continuation, state.lastUpdate(through: $0.through)) }
        }
        for (continuation, lastUpdate) in waiters { continuation.resume(returning: lastUpdate) }
    }

    /// The last update passed on at or before `sequence`, once the notification there, and so
    /// every one before it, has been taken.
    func lastUpdate(through sequence: UInt64) async -> UInt64 {
        await withCheckedContinuation { continuation in
            let lastUpdate: UInt64? = state.withLock { state in
                guard state.finished || state.taken >= sequence else {
                    state.waiters.append((sequence, continuation))
                    return nil
                }
                return state.lastUpdate(through: sequence)
            }
            if let lastUpdate { continuation.resume(returning: lastUpdate) }
        }
    }
}
