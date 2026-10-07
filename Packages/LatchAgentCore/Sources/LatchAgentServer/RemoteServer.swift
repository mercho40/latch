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
    /// Connections that have not authenticated yet, across all peers. A new one past this
    /// closes the oldest instead of being refused, so idle sockets cannot keep clients out.
    public var maxUnauthenticatedConnections = 64
    /// The same, per peer address. A peer past it loses its own oldest, never another's.
    public var maxUnauthenticatedConnectionsPerPeer = 8
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
    /// In `devices` and `watch-devices` beside `tokens`.
    let devices: [ServerDeviceTokens]
    /// When each token last authenticated, for `latch-server devices`.
    let tokenUse: ServerTokenUse
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
        /// Connections that have not authenticated yet, by serial, with their peer's address.
        /// Serials only grow, so the smallest is the oldest.
        var unauthenticated: [UInt64: [UInt8]] = [:]
        /// Closed to make room for a newer connection and not yet ended.
        var evicted: Set<UInt64> = []
    }

    /// Of the connections that have not authenticated, by serial with their peer's address,
    /// the one to close so one more from `peer` fits, if any must go: that peer's oldest when
    /// it is at `perPeer`, so a peer only ever pushes out its own, or else the oldest of all
    /// at `total`.
    static func evictionVictim(among unauthenticated: [UInt64: [UInt8]], for peer: [UInt8], perPeer: Int, total: Int) -> UInt64? {
        let fromPeer = unauthenticated.filter { $0.value == peer }.keys
        if fromPeer.count >= perPeer { return fromPeer.min() }
        if unauthenticated.count >= total { return unauthenticated.keys.min() }
        return nil
    }

    /// What a peer is counted under: an IPv4 address, or an IPv6 address's /64, which one
    /// host or site holds whole, so it cannot take every slot with addresses of its own.
    static func peerKey(_ address: [UInt8]) -> [UInt8] {
        guard let bytes = LatchRemoteAddressPolicy.unmapped(address) else { return address }
        return bytes.count == 16 ? Array(bytes.prefix(8)) : bytes
    }

    public init(hub: RemoteRuntimeHub, tokens: ServerTokenFile, configuration: RemoteServerConfiguration, log: ServerLog) {
        self.hub = hub
        self.tokens = tokens
        devices = [DeviceAccess.full, .watch].map { ServerDeviceTokens(configDirectory: tokens.directory, access: $0, owner: tokens.owner) }
        tokenUse = ServerTokenUse(configDirectory: tokens.directory)
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

    /// Reads the token files now and closes every connection whose token is no longer among
    /// them: the server token was rotated, a device was revoked, or a file is gone or
    /// unusable. A failure to read that says nothing about the files, such as running out of
    /// descriptors, leaves authenticated connections alone; a hello is checked against
    /// whatever could be read. SIGHUP calls this.
    @discardableResult
    public func checkToken() -> AcceptedTokens {
        let accepted = acceptedTokens()
        guard accepted.settled else { return accepted }
        tokenUse.forget(allBut: Set(accepted.entries.compactMap(\.device)))
        let connections = state.withLock { Array($0.connections.values) }
        for connection in connections {
            guard let credential = connection.authenticatedCredential, !accepted.contains(credential.token) else { continue }
            connection.close(credential.device.map { "device \($0)'s token is no longer valid" } ?? "the server token changed")
        }
        return accepted
    }

    /// The tokens a hello may carry now, read without closing anything.
    func acceptedTokens() -> AcceptedTokens {
        var accepted = AcceptedTokens()
        do {
            accepted.entries.append(Credential(device: nil, token: try tokens.read(), access: .full))
        } catch .system {
            accepted.settled = false
        } catch {}
        for kind in devices {
            do {
                for device in try kind.read() {
                    switch device.token {
                    case let .success(token): accepted.entries.append(Credential(device: device.name, token: token, access: kind.access))
                    case .failure(.system): accepted.settled = false
                    case .failure: break
                    }
                }
            } catch .system {
                accepted.settled = false
            } catch {}
        }
        return accepted
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
            admit(descriptor, peer: peer)
        }
    }

    /// Past either limit on connections that have not authenticated, the oldest such
    /// connection goes rather than the new one: a client sends its hello as soon as it
    /// connects, so the connections that have waited longest are the likeliest to be idle,
    /// and an idle socket held open cannot keep anyone out for longer than it takes a new
    /// connection to arrive.
    private func admit(_ descriptor: Int32, peer address: ServerSocketAddress?) {
        let peer = address?.description ?? "unknown"
        let key = address.map { Self.peerKey($0.bytes) } ?? []
        let perPeer = max(1, configuration.maxUnauthenticatedConnectionsPerPeer)
        let total = max(1, configuration.maxUnauthenticatedConnections)
        let admitted: (connection: RemoteServerConnection, evicted: RemoteServerConnection?)? = state.withLock { state in
            guard !state.stopping else { return nil }
            var evicted: RemoteServerConnection?
            if let victim = Self.evictionVictim(among: state.unauthenticated, for: key, perPeer: perPeer, total: total) {
                state.unauthenticated[victim] = nil
                state.evicted.insert(victim)
                evicted = state.connections[victim]
            }
            state.nextSerial += 1
            let connection = RemoteServerConnection(serial: state.nextSerial, descriptor: descriptor, peer: address, server: self)
            state.connections[connection.serial] = connection
            state.unauthenticated[connection.serial] = key
            return (connection, evicted)
        }
        guard let (connection, evicted) = admitted else {
            ServerSocket.close(descriptor)
            return
        }
        if let evicted {
            evicted.close("closed to make room: too many connections have not authenticated")
        }
        logUnauthenticated("connection \(connection.serial) from \(peer) accepted")
        spawn("latch.server.read") { connection.runReader() }
        DispatchQueue.global().asyncAfter(deadline: .now() + configuration.handshakeTimeout.dispatchInterval) { [weak connection] in
            connection?.handshakeDeadlinePassed()
        }
    }

    // MARK: Called by connections

    /// False when the connection must not go on: the server is stopping, or the connection
    /// was closed to make room for a newer one while its hello was being checked.
    func authenticated(_ connection: RemoteServerConnection) -> Bool {
        state.withLock { state in
            let waiting = state.unauthenticated.removeValue(forKey: connection.serial) != nil
            return waiting && !state.stopping
        }
    }

    /// A proxy on this machine forwarded `connection`, which has not authenticated, for the
    /// client at `client`: from now on it counts against that client's limit rather than the
    /// proxy's, and makes room there as a new connection would.
    func forwarded(_ connection: RemoteServerConnection, for address: [UInt8]) {
        let client = Self.peerKey(address)
        let perPeer = max(1, configuration.maxUnauthenticatedConnectionsPerPeer)
        let evicted: RemoteServerConnection? = state.withLock { state in
            guard state.unauthenticated.removeValue(forKey: connection.serial) != nil else { return nil }
            var evicted: RemoteServerConnection?
            // Moving a connection leaves the total as it was.
            if let victim = Self.evictionVictim(among: state.unauthenticated, for: client, perPeer: perPeer, total: .max) {
                state.unauthenticated[victim] = nil
                state.evicted.insert(victim)
                evicted = state.connections[victim]
            }
            state.unauthenticated[connection.serial] = client
            return evicted
        }
        evicted?.close("closed to make room: too many connections have not authenticated")
    }

    func ended(_ connection: RemoteServerConnection, reason: String) {
        let authenticated = state.withLock { state in
            state.connections[connection.serial] = nil
            let waiting = state.unauthenticated.removeValue(forKey: connection.serial) != nil
            let evicted = state.evicted.remove(connection.serial) != nil
            return !waiting && !evicted
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

/// A token a hello may carry, with the device it belongs to, nil for the server token, and
/// what it lets that device do.
struct Credential: Sendable {
    var device: String?
    var token: LatchRemoteToken
    var access: DeviceAccess
}

/// The tokens hellos may carry, as the files held them at one check: the server's, and each
/// device's under its name.
public struct AcceptedTokens: Sendable {
    var entries: [Credential] = []
    /// False when a file could not be read for a reason that says nothing about it, so a token
    /// missing from `entries` may still be valid.
    var settled = true

    /// The entry whose token the hello carried, compared in constant time.
    func entry(matching presented: String) -> Credential? {
        entries.first { $0.token.matches(presented) }
    }

    func contains(_ token: LatchRemoteToken) -> Bool {
        entries.contains { $0.token == token }
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(min(seconds, Int64(Int.max / 1_000_000_000 - 1))) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
