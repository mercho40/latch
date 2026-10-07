import Foundation
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One client socket, speaking the stream directly or inside a WebSocket. The reader thread
/// authenticates it and then decodes its frames; the writer thread, started once it has
/// authenticated, is the only one that writes after the welcome. Whoever closes first shuts
/// the socket down, which wakes both threads; the descriptor itself is closed only after both
/// have exited, so no thread can be blocked on a descriptor number that has been reused.
final class RemoteServerConnection: Sendable {
    let serial: UInt64
    private let descriptor: Int32
    /// A proxy on this machine is believed about the client it forwards for.
    private let peerIsLoopback: Bool
    private let server: RemoteServer
    private let state: Mutex<State>
    /// The writer sleeps here; `wakeWriter` signals it at most once per sleep.
    private let writerWake = DispatchSemaphore(value: 0)

    private static let readSize = 64 * 1024
    /// Replies and pongs a client that stopped reading may pile up before it is dropped.
    private static let outboxLimit = 4096

    private struct State {
        var peer: String
        /// The client's address alone: the peer's, or the client's a proxy on this machine named.
        var client: String
        /// Set by the reader before the welcome, and never changed after.
        var webSocket = false
        /// What the client reads after the welcome in, set with the welcome.
        var compression: LatchRemoteCompression?
        var hubConnection: RemoteConnectionID?
        var credential: Credential?
        var outbox: [Outgoing] = []
        var outstanding = 0
        var wakePending = false
        var closing = false
        /// Closing, but the writer sends the events already waiting for the client first.
        var draining = false
        var closeReason = ""
        var runningThreads = 1
    }

    private struct Outgoing {
        var line: Data
        /// Set for an `attached` reply: the runtime whose cursor may run once it is written.
        var attached: AgentRuntimeID?
        /// A WebSocket control frame, written as it is.
        var framed = false
    }

    /// What the reader makes of the bytes it receives.
    private enum Framing {
        /// Before the first byte.
        case undecided
        /// The newline-delimited stream, as it arrives.
        case stream
        /// An HTTP request head, until its blank line.
        case request([UInt8])
        case webSocket(ServerWebSocket.FrameDecoder)
    }

    init(serial: UInt64, descriptor: Int32, peer: ServerSocketAddress?, server: RemoteServer) {
        self.serial = serial
        self.descriptor = descriptor
        peerIsLoopback = peer.map { LatchRemoteAddressPolicy.classify($0.bytes) == .loopback } ?? false
        self.server = server
        state = Mutex(State(peer: peer?.description ?? "unknown", client: peer?.host ?? "unknown"))
    }

    /// The peer's address, or the client's and the proxy's once a proxy on this machine
    /// has said whom it forwards for.
    var peer: String {
        state.withLock { $0.peer }
    }

    /// The token this connection authenticated with, and the device it belongs to, nil for
    /// the server token; nil before then.
    var authenticatedCredential: Credential? {
        state.withLock { $0.credential }
    }

    /// Shuts the socket down, which ends both threads; the first reason is the one logged.
    func close(_ reason: String) {
        let first = state.withLock { state in
            guard !state.closing else { return false }
            state.closing = true
            state.closeReason = reason
            return true
        }
        guard first else { return }
        ServerSocket.shutdownBoth(descriptor)
        wakeWriter()
    }

    /// Stops reading at once, then closes once the events already published for the client
    /// have been written, such as the stops of a server shutting down, or after `limit` when
    /// the client is not taking them.
    func closeAfterWriting(_ reason: String, within limit: Duration) {
        let first = state.withLock { state in
            guard !state.closing else { return false }
            state.closing = true
            state.draining = true
            state.closeReason = reason
            return true
        }
        guard first else { return }
        ServerSocket.shutdownRead(descriptor)
        wakeWriter()
        DispatchQueue.global().asyncAfter(deadline: .now() + limit.dispatchInterval) { [self] in
            // The descriptor closes only after the last thread has left, which takes this
            // lock, so it is still this connection's here.
            state.withLock { state in
                if state.runningThreads > 0 { ServerSocket.shutdownBoth(descriptor) }
            }
        }
    }

    func handshakeDeadlinePassed() {
        guard state.withLock({ $0.credential == nil }) else { return }
        close("no valid hello within \(server.configuration.handshakeTimeout)")
    }

    // MARK: Reader

    func runReader() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.readSize, alignment: 1)
        defer {
            buffer.deallocate()
            close("closed")
            threadExited()
        }
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: LatchRemoteProtocol.preAuthMaxLineBytes)
        var authenticated = false
        var framing = Framing.undecided
        while true {
            let count = ServerSocket.receive(descriptor, into: buffer, count: Self.readSize)
            guard count > 0 else {
                if count == 0 {
                    close("closed by the client")
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    close("nothing received for \(server.configuration.silenceTimeout)")
                } else if errno == ECONNRESET {
                    // The client went without closing, as an app does that lets go of a
                    // connection with an answer still unread: its doing, not a failure here.
                    close("reset by the client")
                } else {
                    close("read failed: \(String(cString: strerror(errno)))")
                }
                return
            }
            guard let (stream, closing) = unwrap(Data(bytes: buffer, count: count), &framing, authenticated: authenticated) else { return }
            decoder.append(stream)
            while true {
                let line: Data?
                do {
                    line = try decoder.nextLine()
                } catch {
                    close(authenticated ? "sent a frame over the size limit or an empty line" : "sent an oversized or empty hello")
                    return
                }
                guard let line else { break }
                if authenticated {
                    guard handleFrame(line) else { return }
                } else {
                    guard authenticate(line) else { return }
                    authenticated = true
                    decoder.maximumLineBytes = LatchRemoteProtocol.maxFrameBytes
                }
            }
            if closing {
                close("closed by the client")
                return
            }
        }
    }

    /// The stream bytes in what was just received, and whether the client then closed its
    /// WebSocket; nil when the connection must close.
    private func unwrap(_ received: Data, _ framing: inout Framing, authenticated: Bool) -> (Data, closing: Bool)? {
        switch framing {
        case .undecided:
            framing = received.first.map(ServerWebSocket.beginsRequest) == true ? .request([]) : .stream
            return unwrap(received, &framing, authenticated: authenticated)
        case .stream:
            return (received, false)
        case var .request(head):
            framing = .undecided
            let searched = head.count
            head.append(contentsOf: received)
            guard let length = ServerWebSocket.requestHeadLength(in: head, from: searched) else {
                guard head.count <= ServerWebSocket.maxRequestHeadBytes else {
                    refuse(.headTooLarge)
                    return nil
                }
                framing = .request(head)
                return (Data(), false)
            }
            guard length <= ServerWebSocket.maxRequestHeadBytes else {
                refuse(.headTooLarge)
                return nil
            }
            guard upgrade(Array(head[..<length])) else { return nil }
            framing = .webSocket(ServerWebSocket.FrameDecoder())
            return unwrap(Data(head[length...]), &framing, authenticated: authenticated)
        case var .webSocket(frames):
            let contents: [ServerWebSocket.Received]
            do {
                contents = try frames.decode(received)
            } catch {
                close("sent \(error)")
                return nil
            }
            framing = .webSocket(frames)
            var stream = Data()
            for item in contents {
                switch item {
                case let .data(payload):
                    stream.append(payload)
                case let .ping(payload):
                    guard pong(payload, authenticated: authenticated) else { return nil }
                case .close:
                    // Lines that came before the close still count, as they do before a TCP close.
                    return (stream, true)
                }
            }
            return (stream, false)
        }
    }

    /// Answers a WebSocket upgrade, false when the request was refused instead. A proxy on
    /// this machine that names the client it forwards for moves the connection to that
    /// client's limit on connections that have not authenticated, refused or not.
    private func upgrade(_ bytes: [UInt8]) -> Bool {
        let upgrade: ServerWebSocket.Upgrade
        do {
            let head = try ServerWebSocket.Head(bytes)
            if peerIsLoopback, let client = head.forwardedFor {
                let host = ServerSocketAddress(bytes: client, port: 0).host
                state.withLock { state in
                    state.peer = "\(host) via \(state.peer)"
                    state.client = host
                }
                server.forwarded(self, for: client)
            }
            upgrade = try ServerWebSocket.upgrade(fromHead: head)
        } catch {
            refuse(error)
            return false
        }
        guard ServerSocket.sendAll(descriptor, ServerWebSocket.switchingProtocols(upgrade)) else {
            close("write failed")
            return false
        }
        state.withLock { $0.webSocket = true }
        return true
    }

    /// Sends the HTTP error and closes as `reject` does, so the client can read it.
    private func refuse(_ refusal: ServerWebSocket.Refusal) {
        server.authenticationFailed(self, reason: refusal.reason)
        if ServerSocket.sendAll(descriptor, refusal.response) {
            lingerBeforeClosing()
        }
        close("refused: \(refusal.status)")
    }

    /// Answers a ping: straight away before the welcome, when only the reader writes, and
    /// through the writer after it.
    private func pong(_ payload: Data, authenticated: Bool) -> Bool {
        let frame = ServerWebSocket.frame(opcode: ServerWebSocket.opcodePong, payload: payload)
        guard authenticated else {
            guard ServerSocket.sendAll(descriptor, frame) else {
                close("write failed")
                return false
            }
            return true
        }
        return enqueue(Outgoing(line: frame, attached: nil, framed: true))
    }

    /// Writes stream bytes, compressed by `deflater` after a welcome that said so, inside
    /// binary frames on a WebSocket.
    private func send(_ data: Data, compressing deflater: LatchRemoteDeflater? = nil) -> Bool {
        let webSocket = state.withLock { $0.webSocket }
        var bytes = data
        if let deflater {
            guard let compressed = deflater.compress(data) else { return false }
            bytes = compressed
        }
        return ServerSocket.sendAll(descriptor, webSocket ? ServerWebSocket.binaryFrames(bytes) : bytes)
    }

    /// Checks the hello: the token first, so version ranges are never shown to a client
    /// without it. Never logs the hello, which carries the token.
    private func authenticate(_ line: Data) -> Bool {
        guard let hello = try? LatchRemoteHello.decode(line: line) else {
            server.authenticationFailed(self, reason: "the first line was not a hello")
            close("sent no valid hello")
            return false
        }
        var issued: LatchRemoteToken?
        var credential = server.checkToken().entry(matching: hello.token)
        if credential == nil, let redeemed = server.redeem(hello.token, exchanges: hello.exchangesPairingCode) {
            credential = redeemed.credential
            issued = redeemed.issued
        }
        guard let credential else {
            server.authenticationFailed(self, reason: "wrong token")
            reject(LatchRemoteRejected(reason: .unauthorized, message: "The token is not valid for this server."))
            return false
        }
        guard let version = LatchRemoteProtocol.negotiate(clientMin: hello.protocolRange.min, clientMax: hello.protocolRange.max) else {
            server.authenticationFailed(self, reason: "no common protocol version")
            reject(LatchRemoteRejected(
                reason: .protocolMismatch,
                message: "This server speaks Latch protocol \(LatchRemoteVersionRange.supported.min) to \(LatchRemoteVersionRange.supported.max).",
                supported: .supported
            ))
            return false
        }

        let configuration = server.configuration
        let compression: LatchRemoteCompression? = configuration.compression && hello.compression.contains(.deflate) ? .deflate : nil
        let welcome = LatchRemoteServerFrame.welcome(LatchRemoteWelcome(
            protocolVersion: version,
            server: configuration.serverInfo,
            heartbeatSeconds: configuration.heartbeatSeconds,
            maxFrameBytes: LatchRemoteProtocol.maxFrameBytes,
            deviceToken: issued,
            compression: compression
        ))
        // From here the handshake deadline no longer applies.
        let proceed = state.withLock { state in
            guard !state.closing else { return false }
            state.credential = credential
            state.compression = compression
            return true
        }
        guard proceed, server.authenticated(self) else {
            close("closed before the hello was accepted")
            return false
        }
        // A check that ran between reading the token and recording it skipped this
        // connection; read it again so a rotation or revocation and SIGHUP in that window
        // still count.
        guard server.acceptedTokens().contains(credential.token) else {
            close(credential.device.map { "device \($0)'s token is no longer valid" } ?? "the server token changed")
            return false
        }
        // Before the welcome, so a client that has it finds its use noted.
        server.tokenUse.note(device: credential.device, from: state.withLock { $0.client })
        guard let line = try? LatchRemoteCoding.encodeLine(welcome), send(line) else {
            close("write failed")
            return false
        }
        let hubConnection = server.hub.openConnection(wake: { [weak self] in self?.wakeWriter() })
        let started = state.withLock { state in
            guard !state.closing else { return false }
            state.hubConnection = hubConnection
            state.runningThreads += 1
            return true
        }
        guard started else {
            server.hub.closeConnection(hubConnection)
            return false
        }
        ServerSocket.setReceiveTimeout(descriptor, configuration.silenceTimeout)
        server.log.log("connection \(serial) from \(peer) authenticated"
            + (credential.device.map { " as device \($0)" + (credential.access == .watch ? ", watch only" : "") } ?? "")
            + (issued != nil ? ", exchanging a pairing code for its token" : ""))
        if issued == nil, let device = credential.device, credential.token.matches(hello.token) {
            server.deviceConnected(device)
        }
        server.spawn("latch.server.write") { self.runWriter(hubConnection) }
        return true
    }

    /// Sends the rejection, then lets the client read it before the socket goes: closing with
    /// unread input would reset the connection and could discard it.
    private func reject(_ rejected: LatchRemoteRejected) {
        if let line = try? LatchRemoteCoding.encodeLine(LatchRemoteServerFrame.rejected(rejected)), send(line) {
            if state.withLock({ $0.webSocket }) { _ = ServerSocket.sendAll(descriptor, ServerWebSocket.closeFrame(code: 1008)) }
            lingerBeforeClosing()
        }
        close("rejected: \(rejected.reason.rawValue)")
    }

    /// Ends the writing side and reads what the client still sends, for up to a second.
    private func lingerBeforeClosing() {
        ServerSocket.shutdownWrite(descriptor)
        ServerSocket.setReceiveTimeout(descriptor, .seconds(1))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buffer.deallocate() }
        var drained = 0
        while drained < 64 * 1024 {
            let count = ServerSocket.receive(descriptor, into: buffer, count: 4096)
            guard count > 0 else { break }
            drained += count
        }
    }

    /// False when the connection must close.
    private func handleFrame(_ line: Data) -> Bool {
        let frame: LatchRemoteClientFrame
        do {
            frame = try LatchRemoteCoding.decode(LatchRemoteClientFrame.self, fromLine: line)
        } catch {
            close("sent a line that is not a frame")
            return false
        }
        switch frame {
        case .hello:
            close("sent a second hello")
            return false
        case .ping:
            return enqueue(LatchRemoteServerFrame.pong, attached: nil)
        case let .request(request):
            return submit(request)
        case let .invalidRequest(id):
            return reply(id, .failure(LatchRemoteError(code: .invalidRequest, message: "The server could not read that request.")))
        case let .unknown(_, id?):
            return reply(id, .failure(LatchRemoteError(code: .unsupported, message: "This server does not support that frame.")))
        case .unknown(_, nil):
            return true
        }
    }

    /// What a watch-only device may ask: what runs, to follow it, and the agent's saved
    /// sessions, which change nothing.
    static func watchAllows(_ command: LatchRemoteCommand) -> Bool {
        switch command {
        case .listRuntimes, .attach, .detach, .listSessions: true
        default: false
        }
    }

    /// Hands the request to the hub in a Task of its own; closing the connection never
    /// cancels it, and its reply is dropped if the connection has gone by then. Requests read
    /// after the connection was closed, as for a rotated token, are not run at all.
    private func submit(_ request: LatchRemoteRequest) -> Bool {
        if state.withLock({ $0.credential?.access }) == .watch, !Self.watchAllows(request.command) {
            return reply(request.id, .failure(LatchRemoteError(
                code: .forbidden,
                message: "This device can only watch. To prompt, answer or stop agents from it, pair it again without --watch-only."
            )))
        }
        enum Admission {
            case closing
            case busy
            case admitted(RemoteConnectionID)
        }
        let admission: Admission = state.withLock { state in
            guard !state.closing, let hubConnection = state.hubConnection else { return .closing }
            guard state.outstanding < server.configuration.maxOutstandingRequests else { return .busy }
            state.outstanding += 1
            return .admitted(hubConnection)
        }
        let hubConnection: RemoteConnectionID
        switch admission {
        case .closing:
            return false
        case .busy:
            return reply(request.id, .failure(LatchRemoteError(code: .busy, message: "Too many requests are in progress on this connection.")))
        case let .admitted(connection):
            hubConnection = connection
        }
        let hub = server.hub
        Task {
            let result = await hub.handle(request.command, from: hubConnection)
            state.withLock { $0.outstanding -= 1 }
            var attached: AgentRuntimeID?
            if case .success(.attached) = result, case let .attach(runtimeID, _) = request.command { attached = runtimeID }
            _ = reply(request.id, result, attached: attached)
        }
        return true
    }

    @discardableResult
    private func reply(_ id: UUID, _ result: LatchRemoteReplyResult, attached: AgentRuntimeID? = nil) -> Bool {
        var frame = LatchRemoteServerFrame.reply(LatchRemoteReply(id: id, result: result))
        if let line = try? LatchRemoteCoding.encodeLine(frame), line.count - 1 <= LatchRemoteProtocol.maxFrameBytes {
            return enqueue(Outgoing(line: line, attached: attached))
        }
        frame = .reply(LatchRemoteReply(id: id, result: .failure(LatchRemoteError(
            code: .payloadTooLarge, message: "The reply was too large to send."
        ))))
        // An attach whose reply could not be sent still activates its cursor, so the next
        // attach of that runtime on this connection is not left waiting for this one.
        return enqueue(frame, attached: attached)
    }

    private func enqueue(_ frame: LatchRemoteServerFrame, attached: AgentRuntimeID?) -> Bool {
        guard let line = try? LatchRemoteCoding.encodeLine(frame) else { return true }
        return enqueue(Outgoing(line: line, attached: attached))
    }

    private func enqueue(_ outgoing: Outgoing) -> Bool {
        let accepted = state.withLock { state in
            guard !state.closing else { return false }
            guard state.outbox.count < Self.outboxLimit else { return false }
            state.outbox.append(outgoing)
            return true
        }
        guard accepted else {
            close("stopped reading its replies")
            return false
        }
        wakeWriter()
        return true
    }

    // MARK: Writer

    /// Replies and pongs first, each `attached` reply activating its cursor right after it is
    /// written; then a batch of events; then, if there was nothing to write, sleep.
    private func runWriter(_ hubConnection: RemoteConnectionID) {
        defer {
            close("closed")
            threadExited()
        }
        let hub = server.hub
        let budget = server.configuration.eventByteBudget
        let pause = server.configuration.writerPauseForTesting
        // One stream for the connection's life, on this thread alone: everything after the
        // welcome goes through it, the welcome itself having gone plain.
        let deflater = state.withLock { $0.compression } == .deflate ? LatchRemoteDeflater() : nil
        while true {
            let (outgoing, closing, draining) = state.withLock { state in
                defer { state.outbox.removeAll() }
                return (state.outbox, state.closing, state.draining)
            }
            if closing {
                if draining { drain(hubConnection, budget: budget, deflater: deflater) }
                return
            }
            for item in outgoing {
                guard item.framed ? ServerSocket.sendAll(descriptor, item.line) : send(item.line, compressing: deflater) else {
                    close("write failed")
                    return
                }
                if let runtimeID = item.attached {
                    hub.activateAttachment(of: runtimeID, for: hubConnection)
                }
            }
            if pause > .zero { Thread.sleep(forTimeInterval: Double(pause.components.seconds) + Double(pause.components.attoseconds) / 1e18) }
            let lines = hub.pullEventLines(for: hubConnection, byteBudget: budget)
            if !lines.isEmpty {
                var batch = Data()
                batch.reserveCapacity(lines.reduce(0) { $0 + $1.count })
                lines.forEach { batch.append($0) }
                guard send(batch, compressing: deflater) else {
                    close("write failed")
                    return
                }
            }
            if outgoing.isEmpty, lines.isEmpty {
                writerWake.wait()
                state.withLock { $0.wakePending = false }
            }
        }
    }

    /// Writes every event line the client has waiting, and a WebSocket's close frame, then
    /// shuts the socket down. Stops at the first failed write, which is also how
    /// `closeAfterWriting`'s limit ends it.
    private func drain(_ hubConnection: RemoteConnectionID, budget: Int, deflater: LatchRemoteDeflater?) {
        defer { ServerSocket.shutdownBoth(descriptor) }
        while true {
            let lines = server.hub.pullEventLines(for: hubConnection, byteBudget: budget)
            guard !lines.isEmpty else {
                if state.withLock({ $0.webSocket }) { _ = ServerSocket.sendAll(descriptor, ServerWebSocket.closeFrame(code: 1001)) }
                return
            }
            var batch = Data()
            batch.reserveCapacity(lines.reduce(0) { $0 + $1.count })
            lines.forEach { batch.append($0) }
            guard send(batch, compressing: deflater) else { return }
        }
    }

    private func wakeWriter() {
        let signal = state.withLock { state in
            guard !state.wakePending else { return false }
            state.wakePending = true
            return true
        }
        if signal { writerWake.signal() }
    }

    // MARK: Teardown

    private func threadExited() {
        let (last, hubConnection, reason) = state.withLock { state in
            state.runningThreads -= 1
            return (state.runningThreads == 0, state.hubConnection, state.closeReason)
        }
        guard last else { return }
        ServerSocket.close(descriptor)
        if let hubConnection { server.hub.closeConnection(hubConnection) }
        server.ended(self, reason: reason)
    }
}
