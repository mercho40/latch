import Foundation
import LatchRemoteProtocol
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Limits and timings for a `RemoteServer`; tests shorten the timings.
public struct RemoteServerConfiguration: Sendable {
    public var serverInfo: LatchRemoteServerInfo
    public var heartbeatSeconds = LatchRemoteProtocol.heartbeatSeconds
    /// An authenticated connection that receives nothing for this long is closed.
    public var silenceTimeout: Duration = .seconds(3 * LatchRemoteProtocol.heartbeatSeconds)
    /// From accept to a hello that checked out, whatever arrives in between.
    public var handshakeTimeout: Duration = .seconds(10)
    /// Connections beyond this many that have not authenticated are closed at once.
    public var maxUnauthenticatedConnections = 8
    /// Requests of one connection the hub is working on; more are answered `busy`.
    public var maxOutstandingRequests = 32
    /// How often the token file is checked for a rotation, besides every hello and SIGHUP.
    public var tokenCheckInterval: Duration = .seconds(LatchRemoteProtocol.heartbeatSeconds)
    /// Event bytes a writer pulls per round before it looks at its replies again.
    public var eventByteBudget = 256 * 1024
    /// Tests widen the writer's window between writing replies and pulling events.
    var writerPauseForTesting: Duration = .zero

    public init(serverInfo: LatchRemoteServerInfo) {
        self.serverInfo = serverInfo
    }

    /// This machine as the welcome describes it.
    public static func localServerInfo(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> LatchRemoteServerInfo {
        var name = [CChar](repeating: 0, count: 256)
        let hostname = gethostname(&name, name.count - 1) == 0 ? String(nulTerminated: name) : "unknown"
        var system = utsname()
        let machine: String = uname(&system) == 0
            ? withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            : "unknown"
        #if os(macOS)
        let os = "macOS"
        #else
        let os = "Linux"
        #endif
        return LatchRemoteServerInfo(
            version: LatchServerVersion.current, hostname: hostname, os: os, arch: machine, home: homeDirectory
        )
    }
}

/// A listening socket for `RemoteServer.start(_:)`.
public struct ServerListener: Sendable {
    public let descriptor: Int32
    /// With the port the kernel chose when the requested one was 0.
    public let address: ServerSocketAddress

    /// Binds and listens; `IPV6_V6ONLY` and `SO_REUSEADDR` are set.
    public static func bind(_ address: ServerSocketAddress) throws(ServerSocketError) -> ServerListener {
        let (descriptor, bound) = try ServerSocket.listen(on: address)
        return ServerListener(descriptor: descriptor, address: bound)
    }
}

/// `latch-server`'s network layer (spec §4.3) over a `RemoteRuntimeHub`. Blocking POSIX I/O
/// on threads of its own, never inside a Task: one accept thread per listener, and per
/// connection a reader thread and, once authenticated, a writer thread.
public final class RemoteServer: Sendable {
    let hub: RemoteRuntimeHub
    let tokens: ServerTokenFile
    let configuration: RemoteServerConfiguration
    let log: ServerLog
    private let state = Mutex(State())
    /// Every thread this server started; each leaves once its descriptors are closed.
    private let threads = DispatchGroup()
    private let stopPipe: (read: Int32, write: Int32)
    private let stopTicking = DispatchSemaphore(value: 0)
    /// Lines about connections that have not authenticated, which anyone who can reach the
    /// port can cause: refusals, acceptances, failures and closes.
    private let unauthenticatedNotices = Mutex(LogRateLimiter(limit: 30, window: .seconds(60)))

    private struct State {
        var started = false
        var stopping = false
        var listeners: [ServerListener] = []
        var nextSerial: UInt64 = 0
        var connections: [UInt64: RemoteServerConnection] = [:]
        /// Serials of connections that have not authenticated yet.
        var unauthenticated: Set<UInt64> = []
    }

    public init(hub: RemoteRuntimeHub, tokens: ServerTokenFile, configuration: RemoteServerConfiguration, log: ServerLog) {
        self.hub = hub
        self.tokens = tokens
        self.configuration = configuration
        self.log = log
        guard let stopPipe = ServerSocket.makePipe() else { fatalError("pipe: \(String(cString: strerror(errno)))") }
        self.stopPipe = stopPipe
    }

    deinit {
        ServerSocket.close(stopPipe.read)
        ServerSocket.close(stopPipe.write)
    }

    /// Starts accepting on `listeners`, which the server now owns, and checking the token file.
    public func start(_ listeners: [ServerListener]) {
        let begin = state.withLock { state in
            guard !state.started, !state.stopping else { return false }
            state.started = true
            state.listeners = listeners
            return true
        }
        guard begin else {
            listeners.forEach { ServerSocket.close($0.descriptor) }
            return
        }
        for listener in listeners {
            spawn("latch.server.accept") { self.acceptLoop(listener) }
        }
        spawn("latch.server.token-check") {
            while self.stopTicking.wait(timeout: .now() + self.configuration.tokenCheckInterval.dispatchInterval) == .timedOut {
                _ = self.checkToken()
            }
        }
    }

    /// Stops accepting, then shuts the hub down, which stops every runtime, while clients are
    /// still connected: each hears that its agent was stopped rather than only that the
    /// connection went. Then closes every connection once those events are written, or after
    /// `drainLimit` for a client that is not reading, and waits for their threads.
    public func shutdown() async {
        let first = state.withLock { state in
            let first = !state.stopping
            state.stopping = true
            return first
        }
        if first {
            var byte: UInt8 = 0
            _ = write(stopPipe.write, &byte, 1)
            stopTicking.signal()
        }
        await hub.shutdown()
        let connections = state.withLock { Array($0.connections.values) }
        for connection in connections {
            connection.closeAfterWriting("the server is shutting down", within: Self.drainLimit)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            threads.notify(queue: .global()) { continuation.resume() }
        }
        let listeners = state.withLock { state in
            defer { state.listeners = [] }
            return state.listeners
        }
        listeners.forEach { ServerSocket.close($0.descriptor) }
    }

    /// How long a shutdown waits for a client to take the events it has waiting.
    static let drainLimit: Duration = .seconds(2)

    /// Reads the token file now and closes every connection that authenticated with another
    /// token, or all of them when the file is gone or unusable. A failure to read it that says
    /// nothing about the file, such as running out of descriptors, fails the hello that asked
    /// but leaves authenticated connections alone. SIGHUP calls this.
    @discardableResult
    public func checkToken() -> LatchRemoteToken? {
        let current: LatchRemoteToken?
        do {
            current = try tokens.read()
        } catch .system {
            return nil
        } catch {
            current = nil
        }
        let connections = state.withLock { Array($0.connections.values) }
        for connection in connections {
            guard let token = connection.authenticatedToken else { continue }
            if current.map({ $0 != token }) ?? true {
                connection.close("the server token changed")
            }
        }
        return current
    }

    var connectionCount: Int {
        state.withLock { $0.connections.count }
    }

    // MARK: Threads

    /// Readers decode JSON nested as deep as the decoder allows before the hello is checked,
    /// which overflows musl's 128 KiB default stack; 1 MiB is several times what it takes.
    static let threadStackSize = 1024 * 1024

    func spawn(_ name: String, _ body: @escaping @Sendable () -> Void) {
        threads.enter()
        let thread = Thread { [threads] in
            body()
            threads.leave()
        }
        thread.name = name
        thread.stackSize = Self.threadStackSize
        thread.start()
    }

    private func acceptLoop(_ listener: ServerListener) {
        while let (descriptor, peer) = ServerSocket.accept(from: listener.descriptor, stop: stopPipe.read) {
            admit(descriptor, peer: peer?.description ?? "unknown")
        }
    }

    private func admit(_ descriptor: Int32, peer: String) {
        let connection: RemoteServerConnection? = state.withLock { state in
            guard !state.stopping, state.unauthenticated.count < configuration.maxUnauthenticatedConnections else { return nil }
            state.nextSerial += 1
            let connection = RemoteServerConnection(serial: state.nextSerial, descriptor: descriptor, peer: peer, server: self)
            state.connections[connection.serial] = connection
            state.unauthenticated.insert(connection.serial)
            return connection
        }
        guard let connection else {
            ServerSocket.close(descriptor)
            logUnauthenticated("refused a connection from \(peer): too many connections have not authenticated")
            return
        }
        logUnauthenticated("connection \(connection.serial) from \(peer) accepted")
        spawn("latch.server.read") { connection.runReader() }
        DispatchQueue.global().asyncAfter(deadline: .now() + configuration.handshakeTimeout.dispatchInterval) { [weak connection] in
            connection?.handshakeDeadlinePassed()
        }
    }

    // MARK: Called by connections

    /// False when the server is stopping and the connection must not go on.
    func authenticated(_ connection: RemoteServerConnection) -> Bool {
        state.withLock { state in
            state.unauthenticated.remove(connection.serial)
            return !state.stopping
        }
    }

    func ended(_ connection: RemoteServerConnection, reason: String) {
        let authenticated = state.withLock { state in
            state.connections[connection.serial] = nil
            return state.unauthenticated.remove(connection.serial) == nil
        }
        let message = "connection \(connection.serial) from \(connection.peer) closed: \(reason)"
        if authenticated { log.log(message) } else { logUnauthenticated(message) }
    }

    func authenticationFailed(_ connection: RemoteServerConnection, reason: String) {
        logUnauthenticated("connection \(connection.serial) from \(connection.peer) failed to authenticate: \(reason)")
    }

    /// Rate-limited, so a flood of connections cannot flood the journal (spec §4.7).
    private func logUnauthenticated(_ message: String) {
        guard let suppressed = unauthenticatedNotices.withLock({ $0.admit(now: .now) }) else { return }
        let note = suppressed > 0 ? " (\(suppressed) more lines about unauthenticated connections not logged)" : ""
        log.log(message + note)
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(min(seconds, Int64(Int.max / 1_000_000_000 - 1))) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
