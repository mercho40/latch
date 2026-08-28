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
}
