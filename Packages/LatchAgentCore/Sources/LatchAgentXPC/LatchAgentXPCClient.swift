import Foundation
import LatchServiceProtocol

public enum LatchAgentXPCClientError: Error, Equatable, Sendable {
    case connectionUnavailable
    case emptyReply
    case mismatchedReply
    case outOfOrderEvent(expectedAfter: UInt64, received: UInt64)
}

/// Client side of one connection to a Latch Agent XPC host.
///
/// Requests are correlated by envelope; command failures surface as `LatchAgentFailure`.
/// `events` is single-consumer and finishes when the connection is interrupted or
/// invalidated, or when an event arrives out of sequence: the view is then stale and a
/// new client must be created. Nothing is replayed.
public final class LatchAgentXPCClient: @unchecked Sendable {
    public let events: AsyncStream<LatchAgentEvent>

    private let connection: NSXPCConnection
    private let codec: LatchServiceCodec
    private let receiver: Receiver
    private let lock = NSLock()
    private var closed = false

    /// Connects to a bundled XPC service by its bundle identifier.
    public convenience init(serviceName: String, codec: LatchServiceCodec = LatchServiceCodec()) {
        self.init(connection: NSXPCConnection(serviceName: serviceName), codec: codec)
    }

    /// Takes ownership of an unresumed connection and resumes it.
    public init(connection: NSXPCConnection, codec: LatchServiceCodec = LatchServiceCodec()) {
        let pair = AsyncStream<LatchAgentEvent>.makeStream()
        self.connection = connection
        self.codec = codec
        self.receiver = Receiver(codec: codec, continuation: pair.continuation)
        self.events = pair.stream
        connection.remoteObjectInterface = LatchAgentXPCAdapter.interface()
        connection.exportedInterface = LatchAgentXPCEventHub.interface()
        connection.exportedObject = receiver
        connection.interruptionHandler = { [weak self] in self?.close() }
        connection.invalidationHandler = { [weak self] in self?.close() }
        receiver.onFailure = { [weak self] in self?.close() }
        connection.resume()
    }

    deinit { close() }

    public var remoteProcessIdentifier: pid_t { connection.processIdentifier }

    public func request(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        guard !lock.withLock({ closed }) else { throw LatchAgentXPCClientError.connectionUnavailable }
        let request = LatchAgentRequest(command: command)
        let payload = try codec.encode(request)
        let codec = codec
        let reply: LatchAgentReply = try await withCheckedThrowingContinuation { continuation in
            let completion = OneShot(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                completion.finish(.failure(error))
            }) as? LatchAgentXPCProtocol else {
                completion.finish(.failure(LatchAgentXPCClientError.connectionUnavailable))
                return
            }
            proxy.sendRequest(payload) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw LatchAgentXPCClientError.emptyReply }
                    completion.finish(.success(try codec.decode(LatchAgentReply.self, from: data)))
                } catch {
                    completion.finish(.failure(error))
                }
            }
        }
        guard reply.requestID == request.requestID, reply.protocolVersion == request.protocolVersion else {
            throw LatchAgentXPCClientError.mismatchedReply
        }
        switch reply.result {
        case let .success(response): return response
        case let .failure(failure): throw failure
        }
    }

    /// Finishes `events` and invalidates the connection. Safe to call repeatedly.
    public func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        receiver.finish()
        connection.invalidate()
    }

    private final class Receiver: NSObject, LatchAgentXPCEventReceiver, @unchecked Sendable {
        private let codec: LatchServiceCodec
        private let continuation: AsyncStream<LatchAgentEvent>.Continuation
        private let lock = NSLock()
        private var lastSequence: UInt64 = 0
        var onFailure: (@Sendable () -> Void)?

        init(codec: LatchServiceCodec, continuation: AsyncStream<LatchAgentEvent>.Continuation) {
            self.codec = codec
            self.continuation = continuation
        }

        func receiveEvent(_ payload: Data, withReply reply: @escaping @Sendable () -> Void) {
            defer { reply() }
            let envelope: LatchAgentEventEnvelope
            do { envelope = try codec.decode(LatchAgentEventEnvelope.self, from: payload) }
            catch { onFailure?(); return }
            let ordered = lock.withLock {
                guard envelope.protocolVersion == LatchServiceProtocolVersion.current,
                      envelope.sequence > lastSequence else { return false }
                lastSequence = envelope.sequence
                return true
            }
            guard ordered else { onFailure?(); return }
            continuation.yield(envelope.event)
        }

        func finish() { continuation.finish() }
    }

    /// Guards the one-shot continuation across the reply and error-handler queues.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LatchAgentReply, any Error>?
        init(_ continuation: CheckedContinuation<LatchAgentReply, any Error>) { self.continuation = continuation }
        func finish(_ result: Result<LatchAgentReply, any Error>) {
            let pending = lock.withLock { let value = continuation; continuation = nil; return value }
            pending?.resume(with: result)
        }
    }
}
