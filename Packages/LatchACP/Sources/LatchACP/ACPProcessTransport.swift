import Foundation

public struct ACPProcessConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL
    public let environment: [String: String]?

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
    }
}

/// Owns one ACP server subprocess and exposes its stdio as asynchronous byte streams.
public final class ACPProcessTransport: @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    public let standardError: AsyncStream<Data>
    public let termination: AsyncStream<Int32>

    private let process: Process
    private let writer: StandardInputWriter

    public init(configuration: ACPProcessConfiguration) throws {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let incomingPair = AsyncStream<Data>.makeStream()
        let errorPair = AsyncStream<Data>.makeStream()
        let terminationPair = AsyncStream<Int32>.makeStream()

        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectoryURL
        if let environment = configuration.environment {
            process.environment = environment
        }
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        Self.forward(
            standardOutput.fileHandleForReading,
            to: incomingPair.continuation
        )
        Self.forward(
            standardError.fileHandleForReading,
            to: errorPair.continuation
        )
        process.terminationHandler = { process in
            incomingPair.continuation.finish()
            errorPair.continuation.finish()
            terminationPair.continuation.yield(process.terminationStatus)
            terminationPair.continuation.finish()
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            incomingPair.continuation.finish()
            errorPair.continuation.finish()
            terminationPair.continuation.finish()
            throw error
        }

        self.process = process
        self.writer = StandardInputWriter(handle: standardInput.fileHandleForWriting)
        self.incoming = incomingPair.stream
        self.standardError = errorPair.stream
        self.termination = terminationPair.stream
    }

    public func send(_ data: Data) async throws {
        try await writer.write(data)
    }

    /// Default time an agent gets to exit after SIGTERM before it is force-killed.
    public static let defaultTerminationGracePeriod: Duration = .seconds(5)

    /// Closes stdin and terminates only the subprocess owned by this transport if needed.
    ///
    /// The process first receives SIGTERM. If it is still running after `gracePeriod`,
    /// it receives SIGKILL. This method returns only once the process has exited, so a
    /// hung agent cannot leave an orphaned subprocess behind.
    public func stop(gracePeriod: Duration = ACPProcessTransport.defaultTerminationGracePeriod) async {
        await writer.close()
        guard process.isRunning else { return }
        process.terminate()
        if await waitForExit(within: gracePeriod) { return }
        forceKill()
        _ = await waitForExit(within: .seconds(5))
    }

    /// Whether the transport escalated to SIGKILL during `stop`.
    public private(set) var wasForceKilled = false

    private func forceKill() {
        guard process.isRunning else { return }
        wasForceKilled = true
        kill(process.processIdentifier, SIGKILL)
    }

    /// Polls `isRunning`; the public `termination` stream is single-consumer and owned by the caller.
    private func waitForExit(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while process.isRunning {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private static func forward(
        _ handle: FileHandle,
        to continuation: AsyncStream<Data>.Continuation
    ) {
        handle.readabilityHandler = { readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty else {
                readableHandle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(data)
        }
    }
}

private actor StandardInputWriter {
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard let handle else {
            throw ACPJSONRPCConnectionError.closed
        }
        try handle.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
