import Foundation
import Synchronization

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

/// Thrown by the Linux spawner; on macOS, `Foundation.Process` reports most of its own errors.
public enum ACPProcessTransportError: Error, Equatable, Sendable {
    case executableNotFound(String)
    case workingDirectoryNotFound(String)
    case spawnFailed(errno: Int32)
}

#if os(macOS) || os(Linux)
/// Owns one ACP server subprocess and exposes its stdio as asynchronous byte streams.
///
/// The agent leads its own process group, and `stop` signals the whole group so tool
/// children the agent started do not outlive it.
public final class ACPProcessTransport: Sendable {
    public let incoming: AsyncStream<Data>
    public let standardError: AsyncStream<Data>
    public let termination: AsyncStream<Int32>

    #if os(Linux)
    private let child: LinuxChildProcess
    #else
    private let process: Process
    #endif
    private let writer: StandardInputWriter
    private let forceKilled = Mutex(false)

    public init(configuration: ACPProcessConfiguration) throws {
        #if os(Linux)
        // Foundation.Process on Linux notices exit only once every descendant closes its
        // inherited socket, and it passes the spawning thread's blocked signals to the agent.
        child = try LinuxChildProcess(configuration: configuration)
        writer = child.standardInput
        incoming = child.standardOutput
        standardError = child.standardError
        termination = child.termination
        #else
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
        // The writer owns stdin outright; Foundation only needs the agent's end.
        let input = fcntl(standardInput.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard input >= 0 else { throw ACPProcessTransportError.spawnFailed(errno: errno) }
        try? standardInput.fileHandleForWriting.close()

        let readers = [standardOutput.fileHandleForReading, standardError.fileHandleForReading]
        Self.forward(readers[0], to: incomingPair.continuation)
        Self.forward(readers[1], to: errorPair.continuation)
        process.terminationHandler = { process in
            terminationPair.continuation.yield(process.terminationStatus)
            terminationPair.continuation.finish()
            // Output ends at EOF, unless a leftover child holds the pipes open.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                readers.forEach { $0.readabilityHandler = nil }
                incomingPair.continuation.finish()
                errorPair.continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            readers.forEach { $0.readabilityHandler = nil }
            incomingPair.continuation.finish()
            errorPair.continuation.finish()
            terminationPair.continuation.finish()
            _ = close(input)
            throw error
        }

        self.process = process
        self.writer = StandardInputWriter(descriptor: input)
        self.incoming = incomingPair.stream
        self.standardError = errorPair.stream
        self.termination = terminationPair.stream
        #endif
    }

    public func send(_ data: Data) async throws {
        try await writer.send(data)
    }

    /// Default time an agent gets to exit after SIGTERM before it is force-killed.
    public static let defaultTerminationGracePeriod: Duration = .seconds(5)

    /// Closes stdin and terminates the agent's process group if needed.
    ///
    /// The group first receives SIGTERM. If the agent is still running after `gracePeriod`,
    /// the group receives SIGKILL; so does a tool child still in the group then, even if the
    /// agent itself exited. This method returns only once the agent has exited, so a hung
    /// agent cannot leave an orphaned subprocess behind.
    public func stop(gracePeriod: Duration = ACPProcessTransport.defaultTerminationGracePeriod) async {
        writer.finish()
        guard isRunning else { return }
        let deadline = ContinuousClock.now + gracePeriod
        signalGroup(SIGTERM)
        if await wait(until: deadline, while: { isRunning }) {
            // Tool children that ignore SIGTERM get what is left of the grace period.
            if !(await wait(until: deadline, while: { groupHasMembers })) {
                signalGroup(SIGKILL)
            }
            return
        }
        forceKill()
        _ = await wait(until: .now + .seconds(5), while: { isRunning })
    }

    /// Whether the transport escalated to SIGKILL during `stop`.
    public var wasForceKilled: Bool {
        forceKilled.withLock { $0 }
    }

    private func forceKill() {
        guard isRunning else { return }
        forceKilled.withLock { $0 = true }
        signalGroup(SIGKILL)
    }

    /// Polls; the public `termination` stream is single-consumer and owned by the caller.
    private func wait(until deadline: ContinuousClock.Instant, while condition: () -> Bool) async -> Bool {
        while condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    #if os(Linux)
    private var isRunning: Bool { !child.hasExited }

    private var groupHasMembers: Bool { child.signalGroup(0) }

    private func signalGroup(_ signal: Int32) {
        child.signalGroup(signal)
    }
    #else
    private var isRunning: Bool { process.isRunning }

    private var groupHasMembers: Bool { kill(-process.processIdentifier, 0) == 0 }

    /// Foundation spawns the agent as the leader of its own process group.
    private func signalGroup(_ signal: Int32) {
        let pid = process.processIdentifier
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
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
    #endif
}

/// Writes the agent's stdin on a serial queue, so a full pipe never blocks a Swift concurrency thread.
///
/// The descriptor is non-blocking: a write the agent never reads waits in poll(2), rechecking
/// whether `finish` was called, so stopping the agent is never stuck behind it.
final class StandardInputWriter: Sendable {
    /// Nil once closing was requested; the close itself runs on `queue`.
    private let descriptor: Mutex<Int32?>
    private let queue = DispatchQueue(label: "dev.latchapp.acp.stdin")

    /// Takes ownership of `descriptor`.
    init(descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        #if os(macOS)
        // A write to an agent that already exited must throw, not raise SIGPIPE in this process.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        #endif
        self.descriptor = Mutex(descriptor)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result { try self.writeAll(data) })
            }
        }
    }

    /// Queued behind any write in flight, so the descriptor cannot be reused under it.
    func finish() {
        guard let input = descriptor.withLock({ $0.take() }) else { return }
        queue.async { _ = close(input) }
    }

    private func writeAll(_ data: Data) throws {
        guard let input = descriptor.withLock({ $0 }) else {
            throw ACPJSONRPCConnectionError.closed
        }
        #if os(Linux)
        // SIGPIPE is directed at the writing thread; block it there and read EPIPE instead.
        var pipeSignal = sigset_t()
        sigemptyset(&pipeSignal)
        sigaddset(&pipeSignal, SIGPIPE)
        var previousMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &pipeSignal, &previousMask)
        defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }
        #endif

        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(input, buffer.baseAddress! + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                    continue
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    guard descriptor.withLock({ $0 != nil }) else {
                        throw ACPJSONRPCConnectionError.closed
                    }
                    var event = pollfd(fd: input, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&event, 1, 100)
                default:
                    #if os(Linux)
                    if errno == EPIPE {
                        var noWait = timespec()
                        _ = sigtimedwait(&pipeSignal, nil, &noWait)
                    }
                    #endif
                    throw ACPJSONRPCConnectionError.closed
                }
            }
        }
    }
}
#endif
