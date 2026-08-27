import Foundation

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
    public let meta: ACPJSONValue?

    public init(
        fs: ACPFileSystemCapabilities = ACPFileSystemCapabilities(),
        terminal: Bool = false,
        meta: ACPJSONValue? = nil
    ) {
        self.fs = fs
        self.terminal = terminal
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case fs
        case terminal
        case meta = "_meta"
    }
}

public struct ACPAgentCapabilities: Codable, Equatable, Sendable {
    public let loadSession: Bool
    public let promptCapabilities: ACPJSONValue?
    public let mcpCapabilities: ACPJSONValue?
    public let sessionCapabilities: ACPJSONValue?
    public let meta: ACPJSONValue?

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

    public init(
        protocolVersion: Int,
        agentCapabilities: ACPAgentCapabilities,
        agentInfo: ACPImplementation? = nil,
        authMethods: [ACPAuthenticationMethod]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.agentInfo = agentInfo
        self.authMethods = authMethods
    }
}

public struct ACPNewSessionResponse: Codable, Equatable, Sendable {
    public let sessionId: String
    public let modes: ACPJSONValue?
    public let models: ACPJSONValue?
    public let configOptions: [ACPJSONValue]?
    public let meta: ACPJSONValue?

    public init(
        sessionId: String,
        modes: ACPJSONValue? = nil,
        models: ACPJSONValue? = nil,
        configOptions: [ACPJSONValue]? = nil,
        meta: ACPJSONValue? = nil
    ) {
        self.sessionId = sessionId
        self.modes = modes
        self.models = models
        self.configOptions = configOptions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case modes
        case models
        case configOptions
        case meta = "_meta"
    }
}

public enum ACPClientError: Error, Equatable, Sendable {
    case initializeRequired
    case initializationAlreadyAttempted
    case noActiveSession
    case promptAlreadyActive
    case unsupportedProtocolVersion(expected: Int, received: Int)
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

    private struct NewSessionRequest: Encodable {
        let cwd: String
        let mcpServers: [ACPJSONValue]
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

    private let connection: ACPJSONRPCConnection
    private var state = State.idle
    private var activeSessionID: String?
    private var promptIsActive = false

    public init(connection: ACPJSONRPCConnection) {
        self.connection = connection
        let pair = AsyncStream<ACPSessionNotification>.makeStream()
        self.sessionUpdates = pair.stream

        Task {
            for await notification in connection.notifications {
                guard notification.method == "session/update", let params = notification.params else {
                    continue
                }
                if let update = try? params.decode(ACPSessionNotification.self) {
                    pair.continuation.yield(update)
                }
            }
            pair.continuation.finish()
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
        let request = NewSessionRequest(cwd: cwd, mcpServers: mcpServers)
        let response: ACPNewSessionResponse = try await connection.request(
            "session/new",
            params: try ACPJSONValue.encode(request)
        )
        activeSessionID = response.sessionId
        return response
    }

    public func prompt(_ text: String) async throws -> ACPPromptResponse {
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
            prompt: [try ACPJSONValue.encode(ACPTextContent(text: text))]
        )
        return try await connection.request(
            "session/prompt",
            params: try ACPJSONValue.encode(request)
        )
    }

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
        guard let handler else {
            await connection.setRequestHandler(nil)
            return
        }

        await connection.setRequestHandler { request in
            guard request.method == "session/request_permission", let params = request.params else {
                throw ACPJSONRPCErrorObject(code: -32601, message: "Method not found")
            }
            let permissionRequest = try params.decode(ACPPermissionRequest.self)
            let response = PermissionResponse(outcome: await handler(permissionRequest))
            return try ACPJSONValue.encode(response)
        }
    }

    public func negotiatedCapabilities() throws -> ACPAgentCapabilities {
        guard case let .initialized(response) = state else {
            throw ACPClientError.initializeRequired
        }
        return response.agentCapabilities
    }

    private func requireInitialized() throws {
        guard case .initialized = state else {
            throw ACPClientError.initializeRequired
        }
    }
}
