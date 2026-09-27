import Foundation
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization

/// One network connection as the hub knows it: a set of attached runtimes and a writer to wake.
public struct RemoteConnectionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public var description: String { "connection-\(rawValue)" }
}

/// Every runtime's journaled events and every connection's cursor into them.
///
/// Guarded by a mutex rather than the hub's actor so a connection's blocking writer thread can
/// pull without awaiting anything. Only the hub appends, from inside its actor, so a record the
/// hub reads is consistent with the journal's `lastSequence` at the same moment.
final class RemoteEventJournal: Sendable {
    private let state = Mutex(State())
    private let runtimeBudget: Int
    private let globalBudget: Int
    private let clock: @Sendable () -> ContinuousClock.Instant

    init(runtimeBudget: Int, globalBudget: Int, clock: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.runtimeBudget = runtimeBudget
        self.globalBudget = globalBudget
        self.clock = clock
    }

    // MARK: Connections

    func openConnection(wake: @escaping @Sendable () -> Void) -> RemoteConnectionID {
        state.withLock { state in
            let id = RemoteConnectionID(rawValue: state.nextConnection)
            state.nextConnection += 1
            state.connections[id] = Connection(wake: wake)
            return id
        }
    }

    /// Drops the connection's cursors. Runtimes keep running; nothing else is cancelled.
    func closeConnection(_ id: RemoteConnectionID) {
        let now = clock()
        state.withLock { state in
            guard let connection = state.connections.removeValue(forKey: id) else { return }
            for runtimeID in connection.subscriptions.keys {
                state.runtimes[runtimeID]?.detach(at: now)
                state.trimRetired(runtimeID)
            }
        }
    }

    /// Starts a cursor at `after`, inactive until `activate` has been called once per
    /// `subscribe`. Reattaching replaces the cursor. The connection may already be closed, in
    /// which case only the reply values are computed.
    ///
    /// `truncated` reports a discontinuity once: events after `after` that were evicted, or a
    /// cursor beyond anything this runtime journaled, which can only come from another runtime
    /// that had the same ID. The first backlog frame then carries no `gap` of its own.
    func subscribe(_ connectionID: RemoteConnectionID, to runtimeID: AgentRuntimeID, after: UInt64)
        -> (backlogFrom: UInt64, truncated: Bool) {
        state.withLock { state in
            guard let runtime = state.runtimes[runtimeID] else { return (after + 1, false) }
            // A cursor beyond what exists would silently skip future events.
            let cursor = max(min(after, runtime.lastSequence), runtime.evictedThrough)
            let truncated = after > runtime.lastSequence || after < runtime.evictedThrough
            let backlogFrom = runtime.index(after: cursor).map { runtime.entries[$0].sequence } ?? runtime.lastSequence + 1

            if state.connections[connectionID] != nil {
                let previous = state.connections[connectionID]!.subscriptions[runtimeID]
                state.connections[connectionID]!.subscriptions[runtimeID] = Subscription(
                    cursor: cursor,
                    pendingActivations: (previous?.pendingActivations ?? 0) + 1
                )
                if previous == nil {
                    state.connections[connectionID]!.rotation.append(runtimeID)
                    state.runtimes[runtimeID]!.attach()
                }
            }
            return (backlogFrom, truncated)
        }
    }

    func activate(_ connectionID: RemoteConnectionID, runtimeID: AgentRuntimeID) {
        let wake: (@Sendable () -> Void)? = state.withLock { state in
            guard var subscription = state.connections[connectionID]?.subscriptions[runtimeID],
                  subscription.pendingActivations > 0 else { return nil }
            subscription.pendingActivations -= 1
            state.connections[connectionID]!.subscriptions[runtimeID] = subscription
            return subscription.isActive ? state.connections[connectionID]!.wake : nil
        }
        wake?()
    }

    func unsubscribe(_ connectionID: RemoteConnectionID, from runtimeID: AgentRuntimeID) {
        let now = clock()
        state.withLock { state in
            guard state.connections[connectionID]?.subscriptions.removeValue(forKey: runtimeID) != nil else { return }
            state.connections[connectionID]!.rotation.removeAll { $0 == runtimeID }
            state.runtimes[runtimeID]?.detach(at: now)
            state.trimRetired(runtimeID)
        }
    }

    /// The next frames for one connection, round-robin across its active cursors, advancing
    /// them. Stops before `byteBudget` would be exceeded, but always returns at least one frame
    /// when one is ready.
    func pull(_ connectionID: RemoteConnectionID, byteBudget: Int) -> [Data] {
        let batch: [PulledEvent] = state.withLock { state in
            guard var connection = state.connections[connectionID], !connection.rotation.isEmpty else { return [] }
            var batch: [PulledEvent] = []
            var used = 0
            var index = connection.nextIndex % connection.rotation.count
            var idle = 0
            while idle < connection.rotation.count {
                let runtimeID = connection.rotation[index]
                guard let subscription = connection.subscriptions[runtimeID], subscription.isActive,
                      let runtime = state.runtimes[runtimeID],
                      let entryIndex = runtime.index(after: subscription.cursor) else {
                    idle += 1
                    index = (index + 1) % connection.rotation.count
                    continue
                }
                let entry = runtime.entries[entryIndex]
                let estimate = entry.encodedEvent.count + runtimeID.rawValue.utf8.count + 80
                if !batch.isEmpty, used + estimate > byteBudget { break }
                batch.append(PulledEvent(
                    runtimeID: runtimeID,
                    sequence: entry.sequence,
                    gap: subscription.cursor < runtime.evictedThrough,
                    encodedEvent: entry.encodedEvent
                ))
                used += estimate
                connection.subscriptions[runtimeID]!.cursor = entry.sequence
                idle = 0
                index = (index + 1) % connection.rotation.count
            }
            connection.nextIndex = index
            state.connections[connectionID] = connection
            for runtimeID in Set(batch.map(\.runtimeID)) {
                state.trimRetired(runtimeID)
            }
            return batch
        }
        // Frames are assembled outside the lock; the event bytes are shared, not copied.
        return batch.map {
            LatchRemoteEventFrame.encodedLine(
                runtimeID: $0.runtimeID, sequence: $0.sequence, gap: $0.gap, encodedEvent: $0.encodedEvent
            )
        }
    }

    // MARK: Runtimes

    func createRuntime(_ id: AgentRuntimeID) {
        let now = clock()
        state.withLock { state in
            guard state.runtimes[id] == nil else { return }
            state.runtimes[id] = RuntimeJournal(detachedSince: now)
        }
    }

    func removeRuntime(_ id: AgentRuntimeID) {
        state.withLock { state in
            guard let runtime = state.runtimes.removeValue(forKey: id) else { return }
            state.byteCount -= runtime.byteCount
            for connectionID in Array(state.connections.keys) {
                guard state.connections[connectionID]!.subscriptions.removeValue(forKey: id) != nil else { continue }
                state.connections[connectionID]!.rotation.removeAll { $0 == id }
            }
        }
    }

    /// Journals an event under the runtime's next sequence and wakes every connection whose
    /// active cursor follows it.
    @discardableResult
    func append(_ encodedEvent: Data, to id: AgentRuntimeID) -> UInt64? {
        let result: (UInt64, [@Sendable () -> Void])? = state.withLock { state in
            guard state.runtimes[id] != nil else { return nil }
            let order = state.nextOrder
            state.nextOrder += 1
            let sequence = state.runtimes[id]!.append(encodedEvent, order: order)
            state.byteCount += encodedEvent.count

            // The newest event always stays, even when it alone is over budget.
            while state.runtimes[id]!.byteCount > runtimeBudget, state.runtimes[id]!.retainedCount > 1 {
                state.byteCount -= state.runtimes[id]!.evictOldest()
            }
            while state.byteCount > globalBudget {
                let oldest = state.runtimes
                    .compactMap { runtimeID, runtime in runtime.oldestOrder.map { (runtimeID, $0) } }
                    .min { $0.1 < $1.1 }
                guard let (victim, victimOrder) = oldest, victimOrder != order else { break }
                state.byteCount -= state.runtimes[victim]!.evictOldest()
            }

            let wakes = state.connections.values.compactMap { connection in
                connection.subscriptions[id]?.isActive == true ? connection.wake : nil
            }
            return (sequence, wakes)
        }
        guard let (sequence, wakes) = result else { return nil }
        for wake in wakes { wake() }
        return sequence
    }

    /// Marks the runtime's events up to and including `sequence` as no longer worth keeping,
    /// and evicts them as soon as every cursor on the runtime has passed them. Until then a
    /// viewer that is behind still receives them without a gap.
    func retire(_ id: AgentRuntimeID, through sequence: UInt64) {
        state.withLock { state in
            guard state.runtimes[id] != nil else { return }
            state.runtimes[id]!.retiredThrough = sequence
            state.trimRetired(id)
        }
    }

    func lastSequence(of id: AgentRuntimeID) -> UInt64 {
        state.withLock { $0.runtimes[id]?.lastSequence ?? 0 }
    }

    /// When the runtime's last connection left, or nil while one is attached.
    func detachedSince(_ id: AgentRuntimeID) -> ContinuousClock.Instant? {
        state.withLock { state in
            guard let runtime = state.runtimes[id], runtime.attachedConnections == 0 else { return nil }
            return runtime.detachedSince
        }
    }

    /// Total journaled bytes, for tests.
    var byteCount: Int {
        state.withLock { $0.byteCount }
    }

    // MARK: State

    private struct State: ~Copyable {
        var runtimes: [AgentRuntimeID: RuntimeJournal] = [:]
        var connections: [RemoteConnectionID: Connection] = [:]
        var byteCount = 0
        var nextOrder: UInt64 = 0
        var nextConnection: UInt64 = 1

        /// Evicts what `retire` marked, as far as the slowest cursor on the runtime allows.
        mutating func trimRetired(_ id: AgentRuntimeID) {
            guard var limit = runtimes[id]?.retiredThrough else { return }
            for connection in connections.values {
                if let cursor = connection.subscriptions[id]?.cursor { limit = min(limit, cursor) }
            }
            while let oldest = runtimes[id]!.oldestSequence, oldest <= limit {
                byteCount -= runtimes[id]!.evictOldest()
            }
        }
    }

    private struct Connection {
        let wake: @Sendable () -> Void
        var subscriptions: [AgentRuntimeID: Subscription] = [:]
        /// Attached runtimes in attach order; `pull` resumes at `nextIndex`.
        var rotation: [AgentRuntimeID] = []
        var nextIndex = 0
    }

    private struct Subscription {
        /// The last sequence sent, or the attach point.
        var cursor: UInt64
        /// `attached` replies not yet handed to the writer. Events wait for all of them.
        var pendingActivations: Int

        var isActive: Bool { pendingActivations == 0 }
    }

    private struct PulledEvent {
        let runtimeID: AgentRuntimeID
        let sequence: UInt64
        let gap: Bool
        let encodedEvent: Data
    }

    private struct Entry {
        let sequence: UInt64
        var encodedEvent: Data
        /// Publish order across all runtimes, so the global budget evicts the oldest first.
        let order: UInt64
    }

    private struct RuntimeJournal {
        /// Retained entries are `entries[head...]`, contiguous and in sequence order.
        var entries: [Entry] = []
        var head = 0
        var lastSequence: UInt64 = 0
        var evictedThrough: UInt64 = 0
        var retiredThrough: UInt64?
        var byteCount = 0
        var attachedConnections = 0
        var detachedSince: ContinuousClock.Instant

        init(detachedSince: ContinuousClock.Instant) {
            self.detachedSince = detachedSince
        }

        var retainedCount: Int { entries.count - head }

        var oldestOrder: UInt64? { head < entries.count ? entries[head].order : nil }

        var oldestSequence: UInt64? { head < entries.count ? entries[head].sequence : nil }

        /// The first retained entry after `cursor`.
        func index(after cursor: UInt64) -> Int? {
            var low = head
            var high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if entries[middle].sequence <= cursor { low = middle + 1 } else { high = middle }
            }
            return low < entries.count ? low : nil
        }

        mutating func append(_ encodedEvent: Data, order: UInt64) -> UInt64 {
            lastSequence += 1
            entries.append(Entry(sequence: lastSequence, encodedEvent: encodedEvent, order: order))
            byteCount += encodedEvent.count
            return lastSequence
        }

        /// Returns the bytes freed.
        mutating func evictOldest() -> Int {
            let freed = entries[head].encodedEvent.count
            evictedThrough = entries[head].sequence
            entries[head].encodedEvent = Data()
            head += 1
            byteCount -= freed
            // Compact occasionally so eviction stays O(1) amortized.
            if head >= 1024, head * 2 >= entries.count {
                entries.removeFirst(head)
                head = 0
            }
            return freed
        }

        mutating func attach() {
            attachedConnections += 1
        }

        mutating func detach(at now: ContinuousClock.Instant) {
            attachedConnections -= 1
            if attachedConnections == 0 { detachedSince = now }
        }
    }
}
