#if canImport(Network)
import Foundation
import LatchRemoteProtocol
import LatchServiceProtocol
import Network
import Synchronization

public struct LatchRemoteConnectionOptions: Sendable {
    /// A host name or a numeric address.
    public var host: String
    public var port: UInt16
    public var token: LatchRemoteToken
    /// Send the token to a peer that is neither loopback nor on a tailnet.
    public var allowUnencryptedNetwork: Bool
    public var client: LatchRemoteClientInfo
    /// From `start()` until the welcome, covering name resolution, TCP and the hello.
    public var handshakeTimeout: Duration
    /// Tests only: the address and interface the destination check sees instead of the real ones.
    var peerAddressForTesting: [UInt8]?
    var interfaceNameForTesting: String?

    public init(
        host: String,
        port: UInt16 = LatchRemoteProtocol.defaultPort,
        token: LatchRemoteToken,
        allowUnencryptedNetwork: Bool = false,
        client: LatchRemoteClientInfo,
        handshakeTimeout: Duration = .seconds(10)
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.allowUnencryptedNetwork = allowUnencryptedNetwork
        self.client = client
        self.handshakeTimeout = handshakeTimeout
    }
}

/// One TCP session with a `latch-server`: the destination check, the handshake, requests
/// correlated by id, the runtime events that arrive on it, and the heartbeat. It never
/// reconnects; `LatchRemoteRuntimeChannel` does that with a new connection.
///
/// Handlers, request completions and events are all delivered on `queue`, in the order the
/// frames arrived, and never while a lock is held, so they may call back into the connection.
public final class LatchRemoteConnection: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        /// The destination check passed and the hello is on its way.
        case authenticating
        case ready(LatchRemoteWelcome)
        case closed(LatchRemoteClientError)
    }

    public typealias Completion = @Sendable (Result<LatchRemoteResponse, any Error>) -> Void

    /// What a welcome may ask for; the server's values come nowhere near either bound.
    static let heartbeatRange = 1...3600
    static let maxFrameRange = 1...(1 << 30)

    /// The host to connect to for the one the user named. `localhost` is 127.0.0.1, as it is
    /// to `latch-server --listen`: resolved, it would be tried as ::1 first, where the server
    /// does not listen and any other local user could, and would receive the token.
    static func connectHost(for host: String) -> String {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name == "localhost" ? "127.0.0.1" : host
    }

    public let options: LatchRemoteConnectionOptions
    public let queue: DispatchQueue
    private let stateHandler: @Sendable (State) -> Void
    private let eventHandler: @Sendable (LatchRemoteEventFrame) -> Void
    private let core = Mutex(Core())

    private struct Core {
        var state = State.idle
        var connection: NWConnection?
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: LatchRemoteProtocol.preAuthMaxLineBytes)
        var requests: [UUID: Completion] = [:]
        var pings: [UUID: @Sendable (Result<Void, any Error>) -> Void] = [:]
        var readyWaiters: [UUID: @Sendable (Result<LatchRemoteWelcome, any Error>) -> Void] = [:]
        var heartbeat: (any DispatchSourceTimer)?
        var lastReceived = ContinuousClock.now
        var lastSent = ContinuousClock.now
    }

    /// `queue` must be serial; by default the connection makes its own.
    public init(
        options: LatchRemoteConnectionOptions,
        queue: DispatchQueue? = nil,
        stateHandler: @escaping @Sendable (State) -> Void = { _ in },
        eventHandler: @escaping @Sendable (LatchRemoteEventFrame) -> Void = { _ in }
    ) {
        self.options = options
        self.queue = queue ?? DispatchQueue(label: "dev.latchapp.remote-connection")
        self.stateHandler = stateHandler
        self.eventHandler = eventHandler
    }

    deinit {
        close()
    }

    public var state: State {
        core.withLock { $0.state }
    }

    /// Starts connecting. Only the first call does anything.
    public func start() {
        let connection: NWConnection? = core.withLock { core in
            guard case .idle = core.state else { return nil }
            guard options.port != 0, let port = NWEndpoint.Port(rawValue: options.port) else {
                close(&core, with: .invalidEndpoint)
                return nil
            }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.preferNoProxies = true
            let connection = NWConnection(host: NWEndpoint.Host(Self.connectHost(for: options.host)), port: port, using: parameters)
            core.connection = connection
            transition(&core, to: .connecting)
            return connection
        }
        guard let connection else { return }
        connection.stateUpdateHandler = { [weak self] state in
            self?.connectionStateChanged(state)
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + options.handshakeTimeout.dispatchInterval) { [weak self] in
            self?.handshakeDeadlinePassed()
        }
    }

    /// Returns the welcome once the handshake is done, or throws why it never will be. After
    /// `start()`, the handshake timeout bounds the wait.
    public func waitUntilReady() async throws -> LatchRemoteWelcome {
        let shot = LatchRemoteOneShot<LatchRemoteWelcome>()
        let id = UUID()
        core.withLock { core in
            switch core.state {
            case let .ready(welcome):
                shot.finish(.success(welcome))
            case let .closed(error):
                shot.finish(.failure(error))
            case .idle, .connecting, .authenticating:
                core.readyWaiters[id] = { shot.finish($0) }
            }
        }
        return try await shot.wait { [weak self] in
            _ = self?.core.withLock { $0.readyWaiters.removeValue(forKey: id) }
        }
    }

    /// Sends a request and returns the server's response; a failure the server reported is
    /// thrown as `LatchRemoteError`. A frame larger than the welcome's `maxFrameBytes` is never
    /// written and fails with `payloadTooLarge`.
    public func request(_ command: LatchRemoteCommand, timeout: Duration? = nil) async throws -> LatchRemoteResponse {
        let shot = LatchRemoteOneShot<LatchRemoteResponse>()
        let id = UUID()
        request(command, id: id, timeout: timeout) { shot.finish($0) }
        return try await shot.wait { [weak self] in
            self?.failRequest(id, with: CancellationError())
        }
    }

    /// The same as `request(_:timeout:)`, completing on `queue` in order with the events that
    /// arrive around the reply. The server writes an `attached` reply before the runtime's
    /// events, so its completion runs before them.
    public func request(_ command: LatchRemoteCommand, timeout: Duration? = nil, completion: @escaping Completion) {
        request(command, id: UUID(), timeout: timeout, completion: completion)
    }

    /// Resolves on the next pong, and fails with `timedOut` if none arrives in time.
    public func ping(timeout: Duration) async throws {
        let shot = LatchRemoteOneShot<Void>()
        let id = UUID()
        core.withLock { core in
            guard case .ready = core.state else {
                shot.finish(.failure(failure(in: core)))
                return
            }
            core.pings[id] = { shot.finish($0) }
            write(&core, frame: .ping)
        }
        queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [weak self] in
            let waiter = self?.core.withLock { $0.pings.removeValue(forKey: id) }
            waiter?(.failure(LatchRemoteClientError.timedOut))
        }
        try await shot.wait { [weak self] in
            _ = self?.core.withLock { $0.pings.removeValue(forKey: id) }
        }
    }

    /// Closes the connection and fails everything pending with `closed`. Idempotent.
    public func close() {
        close(with: .closed)
    }

    func close(with error: LatchRemoteClientError) {
        core.withLock { close(&$0, with: error) }
    }

    // MARK: - Requests

    private func request(_ command: LatchRemoteCommand, id: UUID, timeout: Duration?, completion: @escaping Completion) {
        let line: Data
        do {
            line = try LatchRemoteCoding.encodeLine(LatchRemoteClientFrame.request(LatchRemoteRequest(id: id, command: command)))
        } catch {
            queue.async { completion(.failure(error)) }
            return
        }
        core.withLock { core in
            guard case let .ready(welcome) = core.state else {
                let error = failure(in: core)
                queue.async { completion(.failure(error)) }
                return
            }
            // Checked here so an oversized frame is never partly written.
            guard line.count - 1 <= welcome.maxFrameBytes else {
                let error = LatchRemoteError(
                    code: .payloadTooLarge,
                    message: "The request is \(line.count - 1) bytes; the server accepts at most \(welcome.maxFrameBytes)."
                )
                queue.async { completion(.failure(error)) }
                return
            }
            core.requests[id] = completion
            write(&core, line: line)
        }
        if let timeout {
            queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [weak self] in
                self?.failRequest(id, with: LatchRemoteClientError.timedOut)
            }
        }
    }

    private func failRequest(_ id: UUID, with error: any Error) {
        let completion = core.withLock { $0.requests.removeValue(forKey: id) }
        if let completion {
            queue.async { completion(.failure(error)) }
        }
    }

    /// Why a request cannot be written now.
    private func failure(in core: Core) -> LatchRemoteClientError {
        if case let .closed(error) = core.state { return error }
        return .notConnected
    }

    // MARK: - Connection

    private func handshakeDeadlinePassed() {
        core.withLock { core in
            switch core.state {
            case .idle, .connecting, .authenticating:
                close(&core, with: .handshakeTimedOut)
            case .ready, .closed:
                break
            }
        }
    }

    private func connectionStateChanged(_ state: NWConnection.State) {
        switch state {
        case .setup, .preparing:
            break
        case .waiting(let error):
            // Refused or unreachable: report it now and let the caller decide when to retry,
            // rather than waiting here on Network's own schedule.
            close(with: .connectionFailed(Self.describe(error)))
        case .ready:
            connectionReady()
        case .failed(let error):
            close(with: .connectionFailed(Self.describe(error)))
        case .cancelled:
            close(with: .connectionLost)
        @unknown default:
            break
        }
    }

    private func connectionReady() {
        let connection: NWConnection? = core.withLock { core in
            guard case .connecting = core.state, let connection = core.connection else { return nil }
            let path = connection.currentPath
            let address = options.peerAddressForTesting ?? LatchRemoteDestinationPolicy.address(of: path?.remoteEndpoint)
            guard LatchRemoteDestinationPolicy.mayAuthenticate(
                peerAddress: address,
                interfaceName: options.interfaceNameForTesting ?? LatchRemoteDestinationPolicy.interfaceName(of: path),
                allowUnencryptedNetwork: options.allowUnencryptedNetwork
            ) else {
                close(&core, with: .destinationNotAllowed(address: LatchRemoteDestinationPolicy.describe(address)))
                return nil
            }
            transition(&core, to: .authenticating)
            write(&core, frame: .hello(LatchRemoteHello(token: options.token.rawValue, client: options.client)))
            return connection
        }
        if let connection {
            receive(on: connection)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                received(data)
            }
            if case .closed = state { return }
            if let error {
                close(with: .connectionFailed(Self.describe(error)))
            } else if isComplete {
                close(with: .connectionLost)
            } else {
                receive(on: connection)
            }
        }
    }

    private func received(_ data: Data) {
        core.withLock { core in
            core.lastReceived = .now
            core.decoder.append(data)
        }
        while true {
            let line: Data?
            do {
                line = try core.withLock { core -> Data? in
                    if case .closed = core.state { return nil }
                    return try core.decoder.nextLine()
                }
            } catch {
                close(with: .protocolViolation("\(error)"))
                return
            }
            guard let line else { return }
            let frame: LatchRemoteServerFrame
            do {
                frame = try LatchRemoteCoding.decode(LatchRemoteServerFrame.self, fromLine: line)
            } catch {
                close(with: .protocolViolation("A frame did not decode."))
                return
            }
            core.withLock { handle(frame, in: &$0) }
        }
    }

    private func handle(_ frame: LatchRemoteServerFrame, in core: inout Core) {
        switch (core.state, frame) {
        case let (.authenticating, .welcome(welcome)):
            guard (LatchRemoteVersionRange.supported.min...LatchRemoteVersionRange.supported.max).contains(welcome.protocolVersion) else {
                close(&core, with: .protocolMismatch(
                    message: "The server chose protocol version \(welcome.protocolVersion), which this version of Latch does not speak.",
                    supported: nil
                ))
                return
            }
            guard Self.heartbeatRange.contains(welcome.heartbeatSeconds), Self.maxFrameRange.contains(welcome.maxFrameBytes) else {
                close(&core, with: .protocolViolation("The welcome's limits are out of range."))
                return
            }
            // What this client reads is bounded by its own limit, whatever the server offers.
            core.decoder.maximumLineBytes = min(welcome.maxFrameBytes, LatchRemoteProtocol.maxFrameBytes)
            core.lastReceived = .now
            startHeartbeat(&core, seconds: welcome.heartbeatSeconds)
            transition(&core, to: .ready(welcome))
            let waiters = core.readyWaiters.values
            core.readyWaiters = [:]
            queue.async { waiters.forEach { $0(.success(welcome)) } }

        case let (.authenticating, .rejected(rejected)):
            let error: LatchRemoteClientError = switch rejected.reason {
            case .unauthorized: .unauthorized(message: rejected.message)
            case .protocolMismatch: .protocolMismatch(message: rejected.message, supported: rejected.supported)
            default: .rejected(reason: rejected.reason, message: rejected.message)
            }
            close(&core, with: error)

        case let (.ready, .reply(reply)):
            guard let completion = core.requests.removeValue(forKey: reply.id) else { return }
            let result: Result<LatchRemoteResponse, any Error> = switch reply.result {
            case let .success(response): .success(response)
            case let .failure(error): .failure(error)
            }
            queue.async { completion(result) }

        case let (.ready, .invalidReply(id)):
            guard let completion = core.requests.removeValue(forKey: id) else { return }
            queue.async { completion(.failure(LatchRemoteClientError.invalidReply)) }

        case let (.ready, .event(event)):
            let eventHandler = eventHandler
            queue.async { eventHandler(event) }

        case (.ready, .pong):
            let pings = core.pings.values
            core.pings = [:]
            queue.async { pings.forEach { $0(.success(())) } }

        case (_, .unknown):
            // Frame types from a newer server are ignored.
            break

        default:
            close(&core, with: .protocolViolation("An unexpected \(Self.frameName(frame)) frame arrived."))
        }
    }

    private func startHeartbeat(_ core: inout Core, seconds: Int) {
        let heartbeat = Duration.seconds(seconds)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let tick = (heartbeat / 4).dispatchInterval
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            self?.core.withLock { core in
                let now = ContinuousClock.now
                if now - core.lastReceived >= heartbeat * 3 {
                    self?.close(&core, with: .silence)
                } else if now - core.lastSent >= heartbeat {
                    self?.write(&core, frame: .ping)
                }
            }
        }
        timer.resume()
        core.heartbeat = timer
    }

    private func write(_ core: inout Core, frame: LatchRemoteClientFrame) {
        do {
            write(&core, line: try LatchRemoteCoding.encodeLine(frame))
        } catch {
            close(&core, with: .protocolViolation("A frame did not encode."))
        }
    }

    private func write(_ core: inout Core, line: Data) {
        guard let connection = core.connection else { return }
        core.lastSent = .now
        connection.send(content: line, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.close(with: .connectionFailed(Self.describe(error)))
            }
        })
    }

    private func transition(_ core: inout Core, to state: State) {
        core.state = state
        let stateHandler = stateHandler
        queue.async { stateHandler(state) }
    }

    /// The single path to `closed`: cancels the socket and the heartbeat, then reports the
    /// state before failing what was pending, so an owner sees the cause first.
    private func close(_ core: inout Core, with error: LatchRemoteClientError) {
        if case .closed = core.state { return }
        core.connection?.cancel()
        core.connection = nil
        core.heartbeat?.cancel()
        core.heartbeat = nil
        transition(&core, to: .closed(error))
        let requests = core.requests.values
        let pings = core.pings.values
        let readyWaiters = core.readyWaiters.values
        core.requests = [:]
        core.pings = [:]
        core.readyWaiters = [:]
        queue.async {
            requests.forEach { $0(.failure(error)) }
            pings.forEach { $0(.failure(error)) }
            readyWaiters.forEach { $0(.failure(error)) }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case let .posix(code): String(cString: strerror(code.rawValue))
        default: error.localizedDescription
        }
    }

    private static func frameName(_ frame: LatchRemoteServerFrame) -> String {
        switch frame {
        case .welcome: "welcome"
        case .rejected: "rejected"
        case .reply, .invalidReply: "reply"
        case .event: "event"
        case .pong: "pong"
        case let .unknown(type): type
        }
    }
}
#endif
