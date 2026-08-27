import Foundation

public enum ACPAgentRuntimeState: Equatable, Sendable {
    case idle
    case starting
    case ready
    case stopping
    case stopped
}

public enum ACPAgentRuntimeError: Error, Equatable, Sendable {
    case invalidState(expected: ACPAgentRuntimeState, actual: ACPAgentRuntimeState)
}

public enum ACPAgentRuntimeEvent: Equatable, Sendable {
    case processTerminated(status: Int32)
}

/// Owns one ACP subprocess, JSON-RPC connection, and typed client lifecycle.
///
/// A background service can retain one runtime per active workspace session while forwarding
/// `sessionUpdates`, `standardError`, and `events` to local or remote control surfaces.
public actor ACPAgentRuntime {
    public nonisolated let sessionUpdates: AsyncStream<ACPSessionNotification>
    public nonisolated let standardError: AsyncStream<Data>
    public nonisolated let events: AsyncStream<ACPAgentRuntimeEvent>

    private let configuration: ACPProcessConfiguration
    private let clientInfo: ACPImplementation
    private let clientCapabilities: ACPClientCapabilities
    private let updateContinuation: AsyncStream<ACPSessionNotification>.Continuation
    private let errorContinuation: AsyncStream<Data>.Continuation
    private let eventContinuation: AsyncStream<ACPAgentRuntimeEvent>.Continuation

    private var currentState = ACPAgentRuntimeState.idle
    private var transport: ACPProcessTransport?
    private var client: ACPClient?
    private var connectionTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    public init(
        configuration: ACPProcessConfiguration,
        clientInfo: ACPImplementation,
        clientCapabilities: ACPClientCapabilities = ACPClientCapabilities()
    ) {
        let updatePair = AsyncStream<ACPSessionNotification>.makeStream()
        let errorPair = AsyncStream<Data>.makeStream()
        let eventPair = AsyncStream<ACPAgentRuntimeEvent>.makeStream()
        self.configuration = configuration
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.sessionUpdates = updatePair.stream
        self.standardError = errorPair.stream
        self.events = eventPair.stream
        self.updateContinuation = updatePair.continuation
        self.errorContinuation = errorPair.continuation
        self.eventContinuation = eventPair.continuation
    }

    public func state() -> ACPAgentRuntimeState {
        currentState
    }

    @discardableResult
    public func start() async throws -> ACPInitializeResponse {
        guard currentState == .idle else {
            throw ACPAgentRuntimeError.invalidState(expected: .idle, actual: currentState)
        }
        currentState = .starting

        do {
            let transport = try ACPProcessTransport(configuration: configuration)
            let connection = ACPJSONRPCConnection(incoming: transport.incoming) { data in
                try await transport.send(data)
            }
            let client = ACPClient(connection: connection)
            self.transport = transport
            self.client = client
            connectionTask = Task {
                _ = try? await connection.run()
            }
            updateTask = Task { [updateContinuation] in
                defer { updateContinuation.finish() }
                for await update in client.sessionUpdates {
                    updateContinuation.yield(update)
                }
            }
            errorTask = Task { [errorContinuation] in
                defer { errorContinuation.finish() }
                for await data in transport.standardError {
                    errorContinuation.yield(data)
                }
            }
            terminationTask = Task { [weak self, eventContinuation] in
                defer { eventContinuation.finish() }
                for await status in transport.termination {
                    await self?.processTerminated(status: status)
                }
            }

            let response = try await client.initialize(
                clientInfo: clientInfo,
                capabilities: clientCapabilities
            )
            guard currentState == .starting else {
                throw ACPAgentRuntimeError.invalidState(expected: .starting, actual: currentState)
            }
            currentState = .ready
            return response
        } catch {
            await stopAfterFailedStart()
            throw error
        }
    }

    public func setPermissionHandler(
        _ handler: (@Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome)?
    ) async throws {
        try requireReady()
        await client?.setPermissionHandler(handler)
    }

    @discardableResult
    public func newSession(
        cwd: String,
        mcpServers: [ACPJSONValue] = []
    ) async throws -> ACPNewSessionResponse {
        try requireReady()
        guard let client else {
            throw ACPAgentRuntimeError.invalidState(expected: .ready, actual: currentState)
        }
        return try await client.newSession(cwd: cwd, mcpServers: mcpServers)
    }

    public func prompt(_ text: String) async throws -> ACPPromptResponse {
        try requireReady()
        guard let client else {
            throw ACPAgentRuntimeError.invalidState(expected: .ready, actual: currentState)
        }
        return try await client.prompt(text)
    }

    public func cancelPrompt() async throws {
        try requireReady()
        guard let client else {
            throw ACPAgentRuntimeError.invalidState(expected: .ready, actual: currentState)
        }
        try await client.cancelPrompt()
    }

    public func stop() async {
        guard currentState == .starting || currentState == .ready else { return }
        currentState = .stopping
        await transport?.stop()
        cancelForwardingTasks()
        transport = nil
        client = nil
        currentState = .stopped
    }

    private func stopAfterFailedStart() async {
        await transport?.stop()
        cancelForwardingTasks()
        transport = nil
        client = nil
        currentState = .stopped
    }

    private func processTerminated(status: Int32) {
        eventContinuation.yield(.processTerminated(status: status))
        guard currentState != .stopped else { return }
        connectionTask?.cancel()
        updateTask?.cancel()
        errorTask?.cancel()
        connectionTask = nil
        updateTask = nil
        errorTask = nil
        transport = nil
        client = nil
        currentState = .stopped
    }

    private func cancelForwardingTasks() {
        connectionTask?.cancel()
        updateTask?.cancel()
        errorTask?.cancel()
        connectionTask = nil
        updateTask = nil
        errorTask = nil
    }

    private func requireReady() throws {
        guard currentState == .ready else {
            throw ACPAgentRuntimeError.invalidState(expected: .ready, actual: currentState)
        }
    }
}
