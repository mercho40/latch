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

/// One client socket. The reader thread authenticates it and then decodes its frames; the
/// writer thread, started once it has authenticated, is the only one that writes after the
/// welcome. Whoever closes first shuts the socket down, which wakes both threads; the
/// descriptor itself is closed only after both have exited, so no thread can be blocked on a
/// descriptor number that has been reused.
final class RemoteServerConnection: Sendable {
    let serial: UInt64
    let peer: String
    private let descriptor: Int32
    private let server: RemoteServer
    private let state = Mutex(State())
    /// The writer sleeps here; `wakeWriter` signals it at most once per sleep.
    private let writerWake = DispatchSemaphore(value: 0)

    private static let readSize = 64 * 1024
    /// Replies and pongs a client that stopped reading may pile up before it is dropped.
    private static let outboxLimit = 4096

    private struct State {
        var hubConnection: RemoteConnectionID?
        var token: LatchRemoteToken?
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
    }

    init(serial: UInt64, descriptor: Int32, peer: String, server: RemoteServer) {
        self.serial = serial
        self.descriptor = descriptor
        self.peer = peer
        self.server = server
    }

    /// The token this connection authenticated with; nil before then.
    var authenticatedToken: LatchRemoteToken? {
        state.withLock { $0.token }
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
        guard state.withLock({ $0.token == nil }) else { return }
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
            decoder.append(Data(bytes: buffer, count: count))
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
        }
    }

    /// Checks the hello: the token first, so version ranges are never shown to a client
    /// without it. Never logs the hello, which carries the token.
    private func authenticate(_ line: Data) -> Bool {
        guard let hello = try? LatchRemoteHello.decode(line: line) else {
            server.authenticationFailed(self, reason: "the first line was not a hello")
            close("sent no valid hello")
            return false
        }
        guard let token = server.checkToken(), token.matches(hello.token) else {
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
        let welcome = LatchRemoteServerFrame.welcome(LatchRemoteWelcome(
            protocolVersion: version,
            server: configuration.serverInfo,
            heartbeatSeconds: configuration.heartbeatSeconds,
            maxFrameBytes: LatchRemoteProtocol.maxFrameBytes
        ))
        // From here the handshake deadline no longer applies.
        let proceed = state.withLock { state in
            guard !state.closing else { return false }
            state.token = token
            return true
        }
        guard proceed, server.authenticated(self) else {
            close("closed before the hello was accepted")
            return false
        }
        // A check that ran between reading the token and recording it skipped this
        // connection; read it again so a rotation and SIGHUP in that window still count.
        guard server.tokens.current() == token else {
            close("the server token changed")
            return false
        }
        guard let line = try? LatchRemoteCoding.encodeLine(welcome), ServerSocket.sendAll(descriptor, line) else {
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
        server.log.log("connection \(serial) from \(peer) authenticated")
        server.spawn("latch.server.write") { self.runWriter(hubConnection) }
        return true
    }

    /// Sends the rejection, then lets the client read it before the socket goes: closing with
    /// unread input would reset the connection and could discard it.
    private func reject(_ rejected: LatchRemoteRejected) {
        if let line = try? LatchRemoteCoding.encodeLine(LatchRemoteServerFrame.rejected(rejected)),
           ServerSocket.sendAll(descriptor, line) {
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
        close("rejected: \(rejected.reason.rawValue)")
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

    /// Hands the request to the hub in a Task of its own; closing the connection never
    /// cancels it, and its reply is dropped if the connection has gone by then. Requests read
    /// after the connection was closed, as for a rotated token, are not run at all.
    private func submit(_ request: LatchRemoteRequest) -> Bool {
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
            return enqueue(line: line, attached: attached)
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
        return enqueue(line: line, attached: attached)
    }

    private func enqueue(line: Data, attached: AgentRuntimeID?) -> Bool {
        let accepted = state.withLock { state in
            guard !state.closing else { return false }
            guard state.outbox.count < Self.outboxLimit else { return false }
            state.outbox.append(Outgoing(line: line, attached: attached))
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
        while true {
            let (outgoing, closing, draining) = state.withLock { state in
                defer { state.outbox.removeAll() }
                return (state.outbox, state.closing, state.draining)
            }
            if closing {
                if draining { drain(hubConnection, budget: budget) }
                return
            }
            for item in outgoing {
                guard ServerSocket.sendAll(descriptor, item.line) else {
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
                guard ServerSocket.sendAll(descriptor, batch) else {
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

    /// Writes every event line the client has waiting, then shuts the socket down. Stops at
    /// the first failed write, which is also how `closeAfterWriting`'s limit ends it.
    private func drain(_ hubConnection: RemoteConnectionID, budget: Int) {
        defer { ServerSocket.shutdownBoth(descriptor) }
        while true {
            let lines = server.hub.pullEventLines(for: hubConnection, byteBudget: budget)
            guard !lines.isEmpty else { return }
            var batch = Data()
            batch.reserveCapacity(lines.reduce(0) { $0 + $1.count })
            lines.forEach { batch.append($0) }
            guard ServerSocket.sendAll(descriptor, batch) else { return }
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
