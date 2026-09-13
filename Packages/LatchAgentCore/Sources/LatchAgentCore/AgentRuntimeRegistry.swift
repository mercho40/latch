import Foundation
import LatchACP
import LatchServiceProtocol

public enum AgentRuntimeRegistryError: Error, Equatable, Sendable {
    case duplicateRuntime(AgentRuntimeID)
    case runtimeNotFound(AgentRuntimeID)
    case permissionRequestNotFound(UUID)
}

/// Owns the set of ACP runtimes supervised by the Latch Agent process.
///
/// IDs are Latch-local and exist independently of the ACP session ID assigned after startup.
public actor AgentRuntimeRegistry {
    public nonisolated let events: AsyncStream<LatchAgentEvent>

    private let eventContinuation: AsyncStream<LatchAgentEvent>.Continuation
    private var runtimes: [AgentRuntimeID: ACPAgentRuntime] = [:]
    private var forwardingTasks: [AgentRuntimeID: [Task<Void, Never>]] = [:]
    private var pendingPermissions: [UUID: PendingPermission] = [:]

    /// Requests beyond this per-runtime limit are cancelled immediately instead of queued.
    public static let maximumPendingPermissionsPerRuntime = 16

    private struct PendingPermission {
        let runtimeID: AgentRuntimeID
        let continuation: CheckedContinuation<ACPPermissionOutcome, Never>
    }

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

        let initialization: ACPInitializeResponse
        do {
            initialization = try await runtime.start()
        } catch {
            removeRuntimeIfOwned(id: id, runtime: runtime)
            throw error
        }
        // Permission requests are brokered as events so clients on any transport can answer.
        // If the runtime already left the ready state, it is being torn down and needs no handler.
        try? await runtime.setPermissionHandler { [weak self] request in
            await self?.brokerPermission(runtimeID: id, runtime: runtime, request: request) ?? .cancelled
        }
        return initialization
    }

    /// Answers a pending `permissionRequested` event for `runtimeID`.
    public func resolvePermission(
        runtimeID: AgentRuntimeID,
        requestID: UUID,
        outcome: ACPPermissionOutcome
    ) throws {
        guard let pending = pendingPermissions[requestID], pending.runtimeID == runtimeID else {
            throw AgentRuntimeRegistryError.permissionRequestNotFound(requestID)
        }
        closePermission(requestID: requestID, pending: pending, outcome: outcome)
    }

    public func pendingPermissionRequestIDs(runtimeID: AgentRuntimeID) -> [UUID] {
        pendingPermissions.filter { $0.value.runtimeID == runtimeID }.keys.sorted { $0.uuidString < $1.uuidString }
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

    @discardableResult
    public func loadSession(
        runtimeID: AgentRuntimeID,
        sessionID: String,
        cwd: String,
        mcpServers: [ACPJSONValue] = []
    ) async throws -> ACPLoadSessionResponse {
        let runtime = try runtime(for: runtimeID)
        return try await runtime.loadSession(sessionID: sessionID, cwd: cwd, mcpServers: mcpServers)
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

    @discardableResult
    public func setSessionMode(runtimeID: AgentRuntimeID, modeID: String) async throws -> UInt64 {
        let runtime = try runtime(for: runtimeID)
        return try await runtime.setSessionMode(modeID: modeID)
    }

    public func prompt(
        runtimeID: AgentRuntimeID,
        text: String
    ) async throws -> ACPPromptResponse {
        let runtime = try runtime(for: runtimeID)
        // A decision cannot outlive its prompt; release anything the agent left waiting.
        defer { cancelPendingPermissions(runtimeID: runtimeID) }
        return try await runtime.prompt(text)
    }

    public func cancelPrompt(runtimeID: AgentRuntimeID) async throws {
        let runtime = try runtime(for: runtimeID)
        cancelPendingPermissions(runtimeID: runtimeID)
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
        for id in Set(pendingPermissions.values.map(\.runtimeID)) {
            cancelPendingPermissions(runtimeID: id)
        }
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
        cancelPendingPermissions(runtimeID: id)
    }

    private func brokerPermission(
        runtimeID: AgentRuntimeID,
        runtime: ACPAgentRuntime,
        request: ACPPermissionRequest
    ) async -> ACPPermissionOutcome {
        guard runtimes[runtimeID] === runtime,
              pendingPermissions.values.filter({ $0.runtimeID == runtimeID }).count
                < Self.maximumPendingPermissionsPerRuntime else { return .cancelled }
        let requestID = UUID()
        return await withCheckedContinuation { continuation in
            pendingPermissions[requestID] = PendingPermission(runtimeID: runtimeID, continuation: continuation)
            eventContinuation.yield(.permissionRequested(runtimeID: runtimeID, requestID: requestID, request: request))
        }
    }

    private func cancelPendingPermissions(runtimeID: AgentRuntimeID) {
        for (requestID, pending) in pendingPermissions where pending.runtimeID == runtimeID {
            closePermission(requestID: requestID, pending: pending, outcome: .cancelled)
        }
    }

    private func closePermission(requestID: UUID, pending: PendingPermission, outcome: ACPPermissionOutcome) {
        pendingPermissions[requestID] = nil
        pending.continuation.resume(returning: outcome)
        eventContinuation.yield(.permissionClosed(runtimeID: pending.runtimeID, requestID: requestID))
    }

    private func cancelAllForwardingTasks() {
        let tasks = forwardingTasks.values.flatMap { $0 }
        forwardingTasks.removeAll()
        tasks.forEach { $0.cancel() }
    }
}
