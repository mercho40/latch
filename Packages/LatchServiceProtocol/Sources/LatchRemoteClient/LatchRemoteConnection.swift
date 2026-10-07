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
    public var transport: LatchRemoteTransport
    public var token: LatchRemoteToken
    /// Over TCP, send the token to a peer that is neither loopback nor on a tailnet. A
    /// WebSocket is always over TLS, so this does not apply to it.
    public var allowUnencryptedNetwork: Bool
    public var client: LatchRemoteClientInfo
    /// From `start()` until the welcome, covering name resolution, TCP and the hello.
    public var handshakeTimeout: Duration
    /// Tests only: the addresses and interface the destination check sees instead of the real ones.
    var peerAddressForTesting: [UInt8]?
    var localAddressForTesting: [UInt8]?
    var interfaceNameForTesting: String?
    /// Tests only: a WebSocket without TLS, which the destination check then applies to.
    var webSocketWithoutTLSForTesting = false

    /// Tests only: the WebSocket transport, to a server that speaks it without TLS.
    mutating func useWebSocketWithoutTLSForTesting() {
        transport = .webSocket
        webSocketWithoutTLSForTesting = true
    }

    public init(
        host: String,
        port: UInt16 = LatchRemoteProtocol.defaultPort,
        transport: LatchRemoteTransport = .tcp,
        token: LatchRemoteToken,
        allowUnencryptedNetwork: Bool = false,
        client: LatchRemoteClientInfo,
        handshakeTimeout: Duration = .seconds(10)
    ) {
        self.host = host
        self.port = port
        self.transport = transport
        self.token = token
        self.allowUnencryptedNetwork = allowUnencryptedNetwork
        self.client = client
        self.handshakeTimeout = handshakeTimeout
    }
}

/// One session with a `latch-server`, over TCP or a WebSocket: the destination check, the
/// handshake, requests correlated by id, the runtime events that arrive on it, and the
/// heartbeat. It never reconnects; `LatchRemoteRuntimeChannel` does that with a new connection.
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
    /// The most stream bytes in one WebSocket message, so a proxy never holds much of one.
    static let maxWebSocketMessageBytes = 64 * 1024

    /// The host to connect to for the one the user named. `localhost` is 127.0.0.1, as it is
    /// to `latch-server --listen`: resolved, it would be tried as ::1 first, where the server
    /// does not listen and any other local user could, and would receive the token.
    static func connectHost(for host: String) -> String {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name == "localhost" ? "127.0.0.1" : host
    }

    /// `Latch/0.3.0 (iOS)`, in the characters a header token allows.
    static func userAgent(_ client: LatchRemoteClientInfo) -> String {
        func token(_ text: String) -> String {
            let kept = text.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || ".-_".unicodeScalars.contains($0)) }
            return kept.isEmpty ? "unknown" : String(String.UnicodeScalarView(kept))
        }
        return "\(token(client.name))/\(token(client.version)) (\(token(client.platform)))"
    }

    /// `wss://host:port/`, with an IPv6 host in brackets.
    static func webSocketURL(host: String, port: UInt16, tls: Bool = true) -> URL? {
        let authority = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(tls ? "wss" : "ws")://\(authority):\(port)/")
    }

    /// Whether the transport encrypts on its own, so the token may go wherever it connected.
    private var encrypts: Bool {
        options.transport == .webSocket && !options.webSocketWithoutTLSForTesting
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
        /// From a welcome that chose compression: what arrives after it goes through this.
        var inflater: LatchRemoteInflater?
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
            let connection: NWConnection
            switch options.transport {
            case .tcp:
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.preferNoProxies = true
                connection = NWConnection(host: NWEndpoint.Host(Self.connectHost(for: options.host)), port: port, using: parameters)
            case .webSocket:
                // The system checks the certificate against the host name, as for HTTPS.
                let parameters = NWParameters(tls: options.webSocketWithoutTLSForTesting ? nil : NWProtocolTLS.Options(), tcp: tcp)
                parameters.preferNoProxies = true
                let webSocket = NWProtocolWebSocket.Options()
                webSocket.autoReplyPing = true
                // Proxies such as Cloudflare's challenge a request with no User-Agent.
                webSocket.setAdditionalHeaders([("User-Agent", Self.userAgent(options.client))])
                // Messages are pieces of the stream; the line decoder bounds a frame.
                webSocket.maximumMessageSize = Self.maxWebSocketMessageBytes * 16
                parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
                guard let url = Self.webSocketURL(host: Self.connectHost(for: options.host), port: options.port,
                                                  tls: !options.webSocketWithoutTLSForTesting) else {
                    close(&core, with: .invalidEndpoint)
                    return nil
                }
                connection = NWConnection(to: .url(url), using: parameters)
            }
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
            close(with: .connectionFailed(describeFailure(error)))
        case .ready:
            connectionReady()
        case .failed(let error):
            close(with: .connectionFailed(describeFailure(error)))
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
            guard encrypts || LatchRemoteDestinationPolicy.mayAuthenticate(
                peerAddress: address,
                localAddress: options.localAddressForTesting ?? LatchRemoteDestinationPolicy.address(of: path?.localEndpoint),
                interfaceName: options.interfaceNameForTesting ?? LatchRemoteDestinationPolicy.interfaceName(of: path),
                allowUnencryptedNetwork: options.allowUnencryptedNetwork
            ) else {
                close(&core, with: .destinationNotAllowed(address: LatchRemoteDestinationPolicy.describe(address)))
                return nil
            }
            transition(&core, to: .authenticating)
            // Whoever keeps the connection's token keeps a device token a pairing code is
            // exchanged for; one that does not leaves the code to work on, until its device
            // connects with the token, as the server allows for that.
            write(&core, frame: .hello(LatchRemoteHello(token: options.token.rawValue, client: options.client, exchangesPairingCode: true,
                                                        compression: [.deflate])))
            return connection
        }
        if let connection {
            receive(on: connection)
        }
    }

    private func receive(on connection: NWConnection) {
        if options.transport == .webSocket {
            receiveMessage(on: connection)
            return
        }
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

    /// A WebSocket's data messages, each a piece of the stream, until the server closes it.
    /// Network delivers control frames here too, payload and all; theirs is not the stream's.
    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            if let data, !data.isEmpty, opcode.map(Self.carriesStream) ?? true {
                received(data)
            }
            if case .closed = state { return }
            if let error {
                close(with: .connectionFailed(Self.describe(error)))
            } else if opcode == .close || (data == nil && context?.isFinal == true) {
                close(with: .connectionLost)
            } else {
                receiveMessage(on: connection)
            }
        }
    }

    static func carriesStream(_ opcode: NWProtocolWebSocket.Opcode) -> Bool {
        switch opcode {
        case .binary, .text, .cont: true
        case .ping, .pong, .close: false
        @unknown default: false
        }
    }

    private func received(_ data: Data) {
        let corrupt: Bool = core.withLock { core in
            core.lastReceived = .now
            guard let inflater = core.inflater else {
                core.decoder.append(data)
                return false
            }
            guard let plain = try? inflater.decompress(data) else { return true }
            core.decoder.append(plain)
            return false
        }
        if corrupt {
            close(with: .protocolViolation("The server's compressed stream did not decompress."))
            return
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
            if welcome.compression == .deflate {
                // What came in after the welcome with it is compressed already.
                let inflater = LatchRemoteInflater()
                guard let plain = try? inflater.decompress(core.decoder.takeRemainder()) else {
                    close(&core, with: .protocolViolation("The server's compressed stream did not decompress."))
                    return
                }
                core.decoder.append(plain)
                core.inflater = inflater
            }
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
        let completion = NWConnection.SendCompletion.contentProcessed { [weak self] error in
            if let error {
                self?.close(with: .connectionFailed(Self.describe(error)))
            }
        }
        guard options.transport == .webSocket else {
            connection.send(content: line, completion: completion)
            return
        }
        var start = line.startIndex
        while start < line.endIndex {
            let end = line.index(start, offsetBy: min(Self.maxWebSocketMessageBytes, line.endIndex - start))
            let context = NWConnection.ContentContext(identifier: "latch", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
            connection.send(content: line[start..<end], contentContext: context, isComplete: true, completion: completion)
            start = end
        }
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

    /// Network reports an HTTP answer other than the upgrade, which a proxy gives when it
    /// cannot reach the server, as an aborted connection.
    private func describeFailure(_ error: NWError) -> String {
        if options.transport == .webSocket, case .posix(.ECONNABORTED) = error, case .connecting = state {
            return "\(options.host) answered, but not with a WebSocket. Check that the tunnel is running and forwards to latch-server."
        }
        return Self.describe(error)
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
