import Foundation
import LatchACP
import LatchServiceProtocol

#if os(macOS) || os(Linux)
/// Transport-neutral command boundary for the macOS Latch Agent.
///
/// XPC and Network.framework adapters can encode messages as data and delegate execution here.
public actor LatchAgentService {
    public nonisolated let events: AsyncStream<LatchAgentEvent>

    private let registry: AgentRuntimeRegistry
    private let clientInfo: ACPImplementation

    public init(
        registry: AgentRuntimeRegistry = AgentRuntimeRegistry(),
        // The version of the bundle this runs in, the Mac's XPC service, which carries the
        // app's; latch-server passes its own.
        clientInfo: ACPImplementation = ACPImplementation(
            name: "latch-agent",
            title: "Latch Agent",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
    ) {
        self.registry = registry
        self.clientInfo = clientInfo
        self.events = registry.events
    }

    public func handle(_ request: LatchAgentRequest) async -> LatchAgentReply {
        guard request.protocolVersion == LatchServiceProtocolVersion.current else {
            return LatchAgentReply(
                requestID: request.requestID,
                result: .failure(LatchAgentFailure(
                    code: .unsupportedProtocolVersion,
                    message: "Unsupported service protocol version."
                ))
            )
        }

        do {
            return LatchAgentReply(
                requestID: request.requestID,
                result: .success(try await execute(request.command))
            )
        } catch {
            return LatchAgentReply(
                requestID: request.requestID,
                result: .failure(Self.publicFailure(for: error))
            )
        }
    }

    public func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case .listRuntimes:
            return .runtimeList(await registry.snapshots())

        case let .startRuntime(id, profile):
            let initialization = try await registry.start(
                id: id,
                configuration: profile.processConfiguration,
                clientInfo: clientInfo
            )
            return .runtimeStarted(runtimeID: id, initialization: initialization)

        case let .stopRuntime(id):
            try await registry.stop(id: id)
            return .runtimeStopped(runtimeID: id)

        case let .newSession(runtimeID, cwd):
            let session = try await registry.newSession(runtimeID: runtimeID, cwd: cwd)
            return .sessionCreated(runtimeID: runtimeID, session: session)

        case let .loadSession(runtimeID, sessionID, cwd):
            let response = try await registry.loadSession(runtimeID: runtimeID, sessionID: sessionID, cwd: cwd)
            return .sessionLoaded(runtimeID: runtimeID, response: response)

        case let .setSessionConfigOption(runtimeID, configID, value):
            let response = try await registry.setSessionConfigOption(
                runtimeID: runtimeID,
                configID: configID,
                value: value
            )
            return .sessionConfigOptionSet(runtimeID: runtimeID, response: response)

        case let .setSessionModel(runtimeID, modelID):
            let sequence = try await registry.setSessionModel(runtimeID: runtimeID, modelID: modelID)
            return .sessionModelSet(runtimeID: runtimeID, sequence: sequence)

        case let .setSessionMode(runtimeID, modeID):
            let sequence = try await registry.setSessionMode(runtimeID: runtimeID, modeID: modeID)
            return .sessionModeSet(runtimeID: runtimeID, sequence: sequence)

        case let .prompt(runtimeID, blocks):
            let response = try await registry.prompt(runtimeID: runtimeID, blocks: blocks)
            return .promptCompleted(runtimeID: runtimeID, response: response)

        case let .cancelPrompt(runtimeID):
            try await registry.cancelPrompt(runtimeID: runtimeID)
            return .promptCancellationRequested(runtimeID: runtimeID)

        case let .resolvePermission(runtimeID, requestID, outcome):
            try await registry.resolvePermission(runtimeID: runtimeID, requestID: requestID, outcome: outcome)
            return .permissionResolved(runtimeID: runtimeID, requestID: requestID)

        case let .steerPrompt(runtimeID, blocks):
            let outcome = try await registry.runtime(for: runtimeID).steer(blocks)
            return .promptSteered(runtimeID: runtimeID, injected: outcome != .promptRequired)

        case let .listSessions(runtimeID, cwd):
            return .sessionsListed(runtimeID: runtimeID, sessions: try await registry.runtime(for: runtimeID).listSessions(cwd: cwd))

        case let .forkSession(runtimeID, sessionID, cwd):
            return .sessionForked(runtimeID: runtimeID,
                                  sessionID: try await registry.runtime(for: runtimeID).forkSession(sessionID: sessionID, cwd: cwd))

        case let .resolveElicitation(runtimeID, requestID, response):
            try await registry.resolveElicitation(runtimeID: runtimeID, requestID: requestID, response: response)
            return .elicitationResolved(runtimeID: runtimeID, requestID: requestID)
        }
    }

    public func shutdown() async {
        await registry.stopAll()
    }

    /// What a client may see of a failed command: agent RPC display text after redaction, or
    /// a fixed message. Never native errors, paths, or stderr.
    public static func publicFailure(for error: any Error) -> LatchAgentFailure {
        let message: String
        switch error {
        case let error as ACPJSONRPCErrorObject:
            // ACP RequestError.authRequired; never infer authentication state from agent prose.
            return LatchAgentFailure(
                code: error.code == -32000 ? .authenticationRequired : .commandFailed,
                message: AgentRPCFailureMessage.message(for: error)
            )
        case AgentRuntimeRegistryError.duplicateRuntime:
            message = "A runtime with this ID already exists."
        case AgentRuntimeRegistryError.runtimeNotFound:
            message = "Runtime not found."
        case AgentRuntimeRegistryError.permissionRequestNotFound:
            message = "Permission request not found."
        case AgentRuntimeRegistryError.invalidPermissionOption:
            message = "The selected option was not offered by this permission request."
        case AgentRuntimeRegistryError.elicitationRequestNotFound:
            message = "Question not found."
        default:
            message = "Agent command failed."
        }
        return LatchAgentFailure(code: .commandFailed, message: message)
    }
}
#endif
