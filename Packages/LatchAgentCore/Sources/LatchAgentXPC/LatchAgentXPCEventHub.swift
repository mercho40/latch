import Foundation
import LatchServiceProtocol

@objc public protocol LatchAgentXPCEventReceiver {
    /// Acknowledge after accepting the event. Only one event is in flight per connection.
    func receiveEvent(_ payload: Data, withReply reply: @escaping @Sendable () -> Void)
}

public enum LatchAgentXPCEventHubError: Error {
    case stopped
    case duplicateConnection
}

/// The sole consumer of a service's event stream, shared by all authorized XPC connections.
/// Recipients are selected when this hub consumes each event; upstream buffered events may
/// predate attachment. No history or replay API is provided. Sequence numbers are hub-scoped.
public actor LatchAgentXPCEventHub {
    private struct Subscriber {
        let connection: NSXPCConnection
        var pending: [(sequence: UInt64, payload: Data)] = []
        var inFlight: UInt64?
    }

    private let events: AsyncStream<LatchAgentEvent>
    private let codec: LatchServiceCodec
    private let maximumPendingEvents: Int
    private var subscribers: [UUID: Subscriber] = [:]
    private var forwardingTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var stopped = false

    public init(
        events: AsyncStream<LatchAgentEvent>,
        codec: LatchServiceCodec = LatchServiceCodec(),
        maximumPendingEvents: Int = 128
    ) {
        precondition(maximumPendingEvents > 0)
        self.events = events
        self.codec = codec
        self.maximumPendingEvents = maximumPendingEvents
    }

    deinit {
        forwardingTask?.cancel()
    }

    public nonisolated static func interface() -> NSXPCInterface {
        NSXPCInterface(with: LatchAgentXPCEventReceiver.self)
    }

    /// Call once at service startup, before producing events. Keep running with no clients
    /// to discard events as they are consumed rather than retaining a disconnected history.
    public func start() {
        guard !stopped, forwardingTask == nil else { return }
        forwardingTask = Task { [weak self, events] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.broadcast(event)
            }
            await self?.shutdown()
        }
    }

    /// Transfer an authorized, not-yet-resumed connection after configuring its request adapter.
    /// The hub owns its remote interface and lifecycle handlers, and resumes it before returning.
    /// The host must call shutdown before releasing the hub.
    @discardableResult
    public func attach(_ connection: sending NSXPCConnection) throws -> UUID {
        guard !stopped else {
            connection.invalidate()
            throw LatchAgentXPCEventHubError.stopped
        }
        guard !subscribers.values.contains(where: { $0.connection === connection }) else {
            throw LatchAgentXPCEventHubError.duplicateConnection
        }
        let id = UUID()
        connection.remoteObjectInterface = Self.interface()
        connection.interruptionHandler = { [weak self] in
            Task { await self?.disconnect(id) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.disconnect(id) }
        }
        subscribers[id] = Subscriber(connection: connection)
        connection.resume()
        return id
    }

    /// Disconnecting one peer never cancels the shared stream or shuts down the service.
    public func disconnect(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.connection.invalidate()
    }

    /// Abortive final teardown, also used when the source finishes: pending and in-flight
    /// events are not drained. Clients must treat interruption/invalidation as a stale view.
    /// Cancelling the sole iterator terminates its AsyncStream; this hub cannot restart.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        forwardingTask?.cancel()
        forwardingTask = nil
        for id in Array(subscribers.keys) { disconnect(id) }
    }

    var subscriberCount: Int { subscribers.count }

    private func broadcast(_ event: LatchAgentEvent) {
        guard !stopped else { return }
        guard sequence < UInt64.max else { shutdown(); return }
        sequence += 1
        guard !subscribers.isEmpty else { return }
        let payload: Data
        do {
            payload = try codec.encode(LatchAgentEventEnvelope(sequence: sequence, event: event))
        } catch {
            // Never silently omit an event. Invalidation tells clients their view is stale.
            for id in Array(subscribers.keys) { disconnect(id) }
            return
        }
        for id in Array(subscribers.keys) {
            guard var subscriber = subscribers[id] else { continue }
            let bufferedCount = subscriber.pending.count + (subscriber.inFlight == nil ? 0 : 1)
            guard bufferedCount < maximumPendingEvents else { disconnect(id); continue }
            subscriber.pending.append((sequence: sequence, payload: payload))
            subscribers[id] = subscriber
            sendNext(id)
        }
    }

    private func sendNext(_ id: UUID) {
        guard var subscriber = subscribers[id], subscriber.inFlight == nil,
              !subscriber.pending.isEmpty else { return }
        let next = subscriber.pending.removeFirst()
        let payload = next.payload
        // A unique token prevents a duplicate or late acknowledgement from advancing the queue.
        let token = next.sequence
        subscriber.inFlight = token
        subscribers[id] = subscriber
        let proxy = subscriber.connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { await self?.disconnect(id) }
        }
        guard let receiver = proxy as? LatchAgentXPCEventReceiver else { disconnect(id); return }
        receiver.receiveEvent(payload) { [weak self] in
            Task { await self?.acknowledge(id, token: token) }
        }
    }

    private func acknowledge(_ id: UUID, token: UInt64) {
        guard subscribers[id]?.inFlight == token else { return }
        subscribers[id]?.inFlight = nil
        sendNext(id)
    }
}
