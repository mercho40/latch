#if os(Linux)
import Foundation
import Synchronization

/// Spawns and supervises one agent on Linux in place of `Foundation.Process`.
///
/// The agent leads a new process group with an empty signal mask and default signal
/// dispositions, whatever the spawning thread had, and inherits no descriptor but its stdio.
/// Two threads block in `read(2)` on its stdout and stderr and one in `waitpid`. Nothing here
/// blocks a Swift concurrency thread.
final class LinuxChildProcess: Sendable {
    let standardOutput: AsyncStream<Data>
    let standardError: AsyncStream<Data>
    let termination: AsyncStream<Int32>
    let standardInput: StandardInputWriter

    private struct State {
        var exited = false
        /// Set once the exit cleanup is done, after which the group ID may name someone else.
        var groupReleased = false
    }

    private let pid: pid_t
    private let state = Mutex(State())
    private let readers = DispatchGroup()
    /// Closing the write end wakes readers that must stop waiting for EOF.
    private let abandonRead: Int32
    private let abandonWrite: Int32

    private static let readSize = 64 * 1024
    /// Serializes our spawns so one child never inherits another's pipe ends.
    private static let spawnLock = Mutex(())

    init(configuration: ACPProcessConfiguration) throws {
        let directory = configuration.workingDirectoryURL.path
        guard Self.isDirectory(directory) else {
            throw ACPProcessTransportError.workingDirectoryNotFound(directory)
        }
        let spawned = try Self.spawn(configuration)
        let outputPair = AsyncStream<Data>.makeStream()
        let errorPair = AsyncStream<Data>.makeStream()
        let terminationPair = AsyncStream<Int32>.makeStream()
        pid = spawned.pid
        standardInput = StandardInputWriter(descriptor: spawned.input)
        abandonRead = spawned.abandon.read
        abandonWrite = spawned.abandon.write
        standardOutput = outputPair.stream
        standardError = errorPair.stream
        termination = terminationPair.stream

        readers.enter()
        readers.enter()
        Self.start("latch.acp.stdout") { self.pump(spawned.output, into: outputPair.continuation) }
        Self.start("latch.acp.stderr") { self.pump(spawned.error, into: errorPair.continuation) }
        Self.start("latch.acp.wait") { self.supervise(reporting: terminationPair.continuation) }
    }

    var hasExited: Bool {
        state.withLock { $0.exited }
    }

    /// Returns whether any process in the agent's group received the signal.
    @discardableResult
    func signalGroup(_ signal: Int32) -> Bool {
        state.withLock { state in
            guard !state.groupReleased else { return false }
            return kill(-pid, signal) == 0
        }
    }

    private func pump(_ descriptor: Int32, into continuation: AsyncStream<Data>.Continuation) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.readSize, alignment: 1)
        defer {
            buffer.deallocate()
            _ = close(descriptor)
            continuation.finish()
            readers.leave()
        }
        var descriptors = [
            pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: abandonRead, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            descriptors[0].revents = 0
            descriptors[1].revents = 0
            guard poll(&descriptors, nfds_t(descriptors.count), -1) >= 0 else {
                if errno == EINTR { continue }
                return
            }
            if descriptors[1].revents != 0 { return }
            let count = read(descriptor, buffer, Self.readSize)
            if count > 0 {
                continuation.yield(Data(bytes: buffer, count: count))
            } else if count == 0 || errno != EINTR {
                return
            }
        }
    }

    private func supervise(reporting continuation: AsyncStream<Int32>.Continuation) {
        let status = Self.reap(pid)
        state.withLock { $0.exited = true }
        continuation.yield(status)
        continuation.finish()
        standardInput.finish()

        // Tool children the agent left in its group may still hold its output pipes open.
        let deadline = DispatchTime.now() + 1
        signalGroup(SIGTERM)
        _ = readers.wait(timeout: deadline)
        while signalGroup(0), DispatchTime.now() < deadline {
            usleep(20_000)
        }
        signalGroup(SIGKILL)
        state.withLock { $0.groupReleased = true }
        // A child that left the group can hold the pipes open indefinitely; stop waiting for EOF.
        _ = close(abandonWrite)
        readers.wait()
        _ = close(abandonRead)
    }

    /// Reports what Foundation's `terminationStatus` does: the exit code, or the signal number.
    private static func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return -1 }
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    private static func start(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.start()
    }

    private struct Spawned {
        var pid: pid_t
        var input: Int32
        var output: Int32
        var error: Int32
        var abandon: (read: Int32, write: Int32)
    }

    private static func spawn(_ configuration: ACPProcessConfiguration) throws -> Spawned {
        try spawnLock.withLock { _ throws -> Spawned in
            var pipes: [(read: Int32, write: Int32)] = []
            do {
                for _ in 0..<4 { pipes.append(try makePipe()) }
            } catch {
                pipes.forEach { _ = close($0.read); _ = close($0.write) }
                throw error
            }
            let (input, output, error, abandon) = (pipes[0], pipes[1], pipes[2], pipes[3])
            // The child's ends are only for the child.
            defer {
                _ = close(input.read)
                _ = close(output.write)
                _ = close(error.write)
            }

            var actions = posix_spawn_file_actions_t()
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, input.read, STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, output.write, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, error.write, STDERR_FILENO)
            for descriptor in inheritableDescriptors() {
                posix_spawn_file_actions_addclose(&actions, descriptor)
            }
            posix_spawn_file_actions_addchdir_np(&actions, configuration.workingDirectoryURL.path)

            var attributes = posix_spawnattr_t()
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            var catchableSignals = sigset_t()
            sigfillset(&catchableSignals)
            sigdelset(&catchableSignals, SIGKILL)
            sigdelset(&catchableSignals, SIGSTOP)
            posix_spawnattr_setsigmask(&attributes, &noSignals)
            posix_spawnattr_setsigdefault(&attributes, &catchableSignals)
            posix_spawnattr_setpgroup(&attributes, 0)
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
            )

            let executable = configuration.executableURL.path
            let environment = (configuration.environment ?? ProcessInfo.processInfo.environment)
                .map { "\($0.key)=\($0.value)" }
            let argv = ([executable] + configuration.arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup($0) } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }

            var pid = pid_t()
            let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            guard result == 0 else {
                for descriptor in [input.write, output.read, error.read, abandon.read, abandon.write] {
                    _ = close(descriptor)
                }
                throw spawnError(result, executable: executable, directory: configuration.workingDirectoryURL.path)
            }
            return Spawned(pid: pid, input: input.write, output: output.read, error: error.read, abandon: abandon)
        }
    }

    /// ENOENT also means a working directory removed since the check, or a missing `#!` interpreter.
    private static func spawnError(_ code: Int32, executable: String, directory: String) -> ACPProcessTransportError {
        guard code == ENOENT else { return .spawnFailed(errno: code) }
        guard isDirectory(directory) else { return .workingDirectoryNotFound(directory) }
        return access(executable, F_OK) == 0 ? .spawnFailed(errno: code) : .executableNotFound(executable)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Open descriptors above 2 without close-on-exec, which code elsewhere in the process may leave;
    /// `Foundation.Process` keeps them from the child too.
    private static func inheritableDescriptors() -> [Int32] {
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd"))
            .map { $0.compactMap { Int32($0) } }
            ?? Array(STDERR_FILENO + 1 ..< getdtablesize())
        return candidates.filter { descriptor in
            guard descriptor > STDERR_FILENO else { return false }
            let flags = fcntl(descriptor, F_GETFD)
            return flags >= 0 && flags & FD_CLOEXEC == 0
        }
    }

    /// Both ends close on exec and sit above 0...2, so the child's dup2 calls cannot clobber one another.
    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw ACPProcessTransportError.spawnFailed(errno: errno)
        }
        for index in descriptors.indices {
            let descriptor = descriptors[index]
            if descriptor > STDERR_FILENO {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                continue
            }
            let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            let failure = errno
            _ = close(descriptor)
            descriptors[index] = moved
            guard moved >= 0 else {
                descriptors.filter { $0 >= 0 }.forEach { _ = close($0) }
                throw ACPProcessTransportError.spawnFailed(errno: failure)
            }
        }
        return (descriptors[0], descriptors[1])
    }
}
#endif
