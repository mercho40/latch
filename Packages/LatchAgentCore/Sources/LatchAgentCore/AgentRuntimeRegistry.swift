import Foundation
import LatchACP

public struct AgentRuntimeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum AgentRuntimeRegistryError: Error, Equatable, Sendable {
    case duplicateRuntime(AgentRuntimeID)
    case runtimeNotFound(AgentRuntimeID)
}

/// Owns the set of ACP runtimes supervised by the Latch Agent process.
///
/// IDs are Latch-local and exist independently of the ACP session ID assigned after startup.
public actor AgentRuntimeRegistry {
    private var runtimes: [AgentRuntimeID: ACPAgentRuntime] = [:]

    public init() {}

    @discardableResult
    public func start(
        id: AgentRuntimeID,
        configuration: ACPProcessConfiguration,
        clientInfo: ACPImplementation,
        clientCapabilities: ACPClientCapabilities = ACPClientCapabilities()
    ) async throws -> ACPInitializeResponse {
        guard runtimes[id] == nil else {
            throw AgentRuntimeRegistryError.duplicateRuntime(id)
        }

        let runtime = ACPAgentRuntime(
            configuration: configuration,
            clientInfo: clientInfo,
            clientCapabilities: clientCapabilities
        )
        // Reserve the ID before suspension so concurrent starts cannot launch duplicates.
        runtimes[id] = runtime

        do {
            return try await runtime.start()
        } catch {
            if runtimes[id] === runtime {
                runtimes[id] = nil
            }
            throw error
        }
    }

    public func runtime(for id: AgentRuntimeID) throws -> ACPAgentRuntime {
        guard let runtime = runtimes[id] else {
            throw AgentRuntimeRegistryError.runtimeNotFound(id)
        }
        return runtime
    }

    public func runtimeIDs() -> [AgentRuntimeID] {
        runtimes.keys.sorted { $0.rawValue < $1.rawValue }
    }

    public func stop(id: AgentRuntimeID) async throws {
        guard let runtime = runtimes.removeValue(forKey: id) else {
            throw AgentRuntimeRegistryError.runtimeNotFound(id)
        }
        await runtime.stop()
    }

    public func stopAll() async {
        let ownedRuntimes = Array(runtimes.values)
        runtimes.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for runtime in ownedRuntimes {
                group.addTask {
                    await runtime.stop()
                }
            }
        }
    }
}
