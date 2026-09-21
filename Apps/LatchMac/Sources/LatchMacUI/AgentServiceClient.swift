import Foundation
import LatchAgentCore
import LatchAgentXPC
import LatchServiceProtocol

/// One session's command and event channel to a Latch Agent service, wherever it runs.
protocol AgentServiceClient: AnyObject, Sendable {
    /// Single-consumer. Finishing means the view is stale and a new client is required.
    var events: AsyncStream<LatchAgentEvent> { get }
    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse
    /// Releases the channel. In-process clients stop their runtimes; XPC clients only drop the connection.
    func close()
    /// Human-readable transport summary for diagnostics and the smoke test.
    var transportDescription: String { get }
}

/// Hosts the service inside the current process. Used by the SwiftPM preview and unit tests.
final class InProcessAgentServiceClient: AgentServiceClient {
    private let service = LatchAgentService()
    var events: AsyncStream<LatchAgentEvent> { service.events }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        try await service.execute(command)
    }

    func close() {
        let service = service
        Task { await service.shutdown() }
    }

    var transportDescription: String { "in-process" }
}

/// Talks to the XPC service embedded in the application bundle.
final class XPCAgentServiceClient: AgentServiceClient {
    static let serviceName = "dev.latchapp.mac.agent"
    static let bundleName = "LatchAgentXPCService.xpc"

    private let client: LatchAgentXPCClient
    var events: AsyncStream<LatchAgentEvent> { client.events }

    init() { client = LatchAgentXPCClient(serviceName: Self.serviceName) }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        try await client.request(command)
    }

    func close() { client.close() }

    /// The service PID is known only after the first message has been exchanged.
    var transportDescription: String { "xpc pid \(client.remoteProcessIdentifier)" }
}

enum AgentServiceClients {
    /// Prefer the bundled XPC service; fall back to in-process hosting when there is no bundle
    /// (SwiftPM preview, tests) or when `LATCH_IN_PROCESS_AGENT=1` asks for it.
    static func makeDefault() -> AgentServiceClient {
        if ProcessInfo.processInfo.environment["LATCH_IN_PROCESS_AGENT"] != "1", bundledServiceAvailable {
            return XPCAgentServiceClient()
        }
        return InProcessAgentServiceClient()
    }

    static var bundledServiceAvailable: Bool {
        guard let services = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent()
            .appendingPathComponent("XPCServices", isDirectory: true) else { return false }
        return FileManager.default.fileExists(atPath: services.appendingPathComponent(XPCAgentServiceClient.bundleName).path)
    }
}
