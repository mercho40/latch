import Foundation
import LatchACP
import LatchServiceProtocol

public enum AgentRuntimeRegistryError: Error, Equatable, Sendable {
    case duplicateRuntime(AgentRuntimeID)
    case runtimeNotFound(AgentRuntimeID)
}

/// Owns the set of ACP runtimes supervised by the Latch Agent process.
///
/// IDs are Latch-local and exist independently of the ACP session ID assigned after startup.
public actor AgentRuntimeRegistry {
    public nonisolated let events: AsyncStream<LatchAgentEvent>

    private let eventContinuation: AsyncStream<LatchAgentEvent>.Continuation
    private var runtimes: [AgentRuntimeID: ACPAgentRuntime] = [:]
    private var forwardingTasks: [AgentRuntimeID: [Task<Void, Never>]] = [:]

    public init() {
        let pair = AsyncStream<LatchAgentEvent>.makeStream()
        self.events = pair.stream
        self.eventContinuation = pair.continuation
    }

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
        forwardingTasks[id] = makeForwardingTasks(id: id, runtime: runtime)
        await runtime.setTerminationHandler { [weak self, weak runtime] status in
            guard let runtime else { return }
            await self?.removeTerminatedRuntime(id: id, runtime: runtime, status: status)
        }

        do {
            return try await runtime.start()
        } catch {
            removeRuntimeIfOwned(id: id, runtime: runtime)
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

    public func snapshots() async -> [AgentRuntimeSnapshot] {
        var result: [AgentRuntimeSnapshot] = []
        for id in runtimeIDs() {
            guard let runtime = runtimes[id] else { continue }
            result.append(AgentRuntimeSnapshot(id: id, state: await runtime.state()))
        }
        return result
    }

    @discardableResult
    public func newSession(
        runtimeID: AgentRuntimeID,
        cwd: String,
        mcpServers: [ACPJSONValue] = []
    ) async throws -> ACPNewSessionResponse {
        let runtime = try runtime(for: runtimeID)
        return try await runtime.newSession(cwd: cwd, mcpServers: mcpServers)
    }

    public func setSessionConfigOption(
        runtimeID: AgentRuntimeID,
        configID: String,
        value: String
    ) async throws -> ACPSetSessionConfigOptionResponse {
        let runtime = try runtime(for: runtimeID)
        return try await runtime.setSessionConfigOption(configID: configID, value: value)
    }

    @discardableResult
    public func setSessionModel(runtimeID: AgentRuntimeID, modelID: String) async throws -> UInt64 {
        let runtime = try runtime(for: runtimeID)
        return try await runtime.setSessionModel(modelID: modelID)
    }

    public func prompt(
        runtimeID: AgentRuntimeID,
        text: String
    ) async throws -> ACPPromptResponse {
        let runtime = try runtime(for: runtimeID)
        return try await runtime.prompt(text)
    }

    public func cancelPrompt(runtimeID: AgentRuntimeID) async throws {
        let runtime = try runtime(for: runtimeID)
        try await runtime.cancelPrompt()
    }

    public func stop(id: AgentRuntimeID) async throws {
        guard let runtime = runtimes[id] else {
            throw AgentRuntimeRegistryError.runtimeNotFound(id)
        }
        removeRuntimeIfOwned(id: id, runtime: runtime)
        await runtime.stop()
    }

    public func stopAll() async {
        let ownedRuntimes = Array(runtimes.values)
        runtimes.removeAll()
        cancelAllForwardingTasks()
        await withTaskGroup(of: Void.self) { group in
            for runtime in ownedRuntimes {
                group.addTask {
                    await runtime.stop()
                }
            }
        }
    }

    private func makeForwardingTasks(
        id: AgentRuntimeID,
        runtime: ACPAgentRuntime
    ) -> [Task<Void, Never>] {
        let updateTask = Task { [eventContinuation] in
            for await notification in runtime.sessionUpdates {
                eventContinuation.yield(.sessionUpdate(runtimeID: id, notification: notification))
            }
        }
        let errorTask = Task { [eventContinuation] in
            for await data in runtime.standardError {
                eventContinuation.yield(.standardError(runtimeID: id, data: data))
            }
        }
        return [updateTask, errorTask]
    }

    private func removeTerminatedRuntime(
        id: AgentRuntimeID,
        runtime: ACPAgentRuntime,
        status: Int32
    ) {
        guard runtimes[id] === runtime else { return }
        removeRuntimeIfOwned(id: id, runtime: runtime)
        eventContinuation.yield(.processTerminated(runtimeID: id, status: status))
    }

    private func removeRuntimeIfOwned(id: AgentRuntimeID, runtime: ACPAgentRuntime) {
        guard runtimes[id] === runtime else { return }
        runtimes[id] = nil
        forwardingTasks.removeValue(forKey: id)?.forEach { $0.cancel() }
    }

    private func cancelAllForwardingTasks() {
        let tasks = forwardingTasks.values.flatMap { $0 }
        forwardingTasks.removeAll()
        tasks.forEach { $0.cancel() }
    }
}
