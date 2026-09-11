import LatchACP
import LatchServiceProtocol

/// Transport-neutral command boundary for the macOS Latch Agent.
///
/// XPC and Network.framework adapters can encode messages as data and delegate execution here.
public actor LatchAgentService {
    public nonisolated let events: AsyncStream<LatchAgentEvent>

    private let registry: AgentRuntimeRegistry
    private let clientInfo: ACPImplementation

    public init(
        registry: AgentRuntimeRegistry = AgentRuntimeRegistry(),
        clientInfo: ACPImplementation = ACPImplementation(
            name: "latch-agent",
            title: "Latch Agent",
            version: "0.1.0"
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
                result: .failure(publicFailure(for: error))
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

        case let .prompt(runtimeID, text):
            let response = try await registry.prompt(runtimeID: runtimeID, text: text)
            return .promptCompleted(runtimeID: runtimeID, response: response)

        case let .cancelPrompt(runtimeID):
            try await registry.cancelPrompt(runtimeID: runtimeID)
            return .promptCancellationRequested(runtimeID: runtimeID)
        }
    }

    public func shutdown() async {
        await registry.stopAll()
    }

    private func publicFailure(for error: any Error) -> LatchAgentFailure {
        let message: String
        switch error {
        case AgentRuntimeRegistryError.duplicateRuntime:
            message = "A runtime with this ID already exists."
        case AgentRuntimeRegistryError.runtimeNotFound:
            message = "Runtime not found."
        default:
            message = "Agent command failed."
        }
        return LatchAgentFailure(code: .commandFailed, message: message)
    }
}
