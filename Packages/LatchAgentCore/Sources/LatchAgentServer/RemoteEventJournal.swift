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
/// With a `historyBudget`, events a runtime's budget pushes out are condensed rather than
/// dropped (see `RemoteHistoryCondenser`), and a client attaching from the start reads that
/// condensed history before the journal, so a device that adopts a long-running runtime still
/// gets its whole conversation. A cursor already inside the history gets the journal alone,
/// with a gap for what it missed, as without condensing.
///
/// Guarded by a mutex rather than the hub's actor so a connection's blocking writer thread can
/// pull without awaiting anything. Only the hub appends, from inside its actor, so a record the
/// hub reads is consistent with the journal's `lastSequence` at the same moment.
final class RemoteEventJournal: Sendable {
    private let state = Mutex(State())
    private let runtimeBudget: Int
    private let globalBudget: Int
    private let historyBudget: Int
    private let clock: @Sendable () -> ContinuousClock.Instant

    /// - Parameter historyBudget: Condensed history bytes kept per runtime, within
    ///   `globalBudget`. Zero drops what the runtime's budget pushes out.
    init(runtimeBudget: Int, globalBudget: Int, historyBudget: Int = 0,
         clock: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.runtimeBudget = runtimeBudget
        self.globalBudget = globalBudget
        self.historyBudget = historyBudget
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
            // Saturating: the cursor is whatever a client sent.
            guard let runtime = state.runtimes[runtimeID] else { return (after == .max ? .max : after + 1, false) }
            let cursor: UInt64
            let truncated: Bool
            let backlogFrom: UInt64
            var condensedNext: UInt64?
            if after == 0, let first = runtime.firstCondensed {
                cursor = 0
                truncated = runtime.condensedTruncated
                backlogFrom = first.entry.sequence
                condensedNext = first.id
            } else {
                // A cursor beyond what exists would silently skip future events.
                cursor = max(min(after, runtime.lastSequence), runtime.evictedThrough)
                truncated = after > runtime.lastSequence || after < runtime.evictedThrough
                backlogFrom = runtime.index(after: cursor).map { runtime.entries[$0].sequence } ?? runtime.lastSequence + 1
            }

            if state.connections[connectionID] != nil {
                let previous = state.connections[connectionID]!.subscriptions[runtimeID]
                state.connections[connectionID]!.subscriptions[runtimeID] = Subscription(
                    cursor: cursor,
                    pendingActivations: (previous?.pendingActivations ?? 0) + 1,
                    condensedNext: condensedNext
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
                      let next = state.runtimes[runtimeID]?.next(for: subscription) else {
                    idle += 1
                    index = (index + 1) % connection.rotation.count
                    continue
                }
                let entry = next.entry
                let estimate = entry.encodedEvent.count + runtimeID.rawValue.utf8.count + 80
                if !batch.isEmpty, used + estimate > byteBudget { break }
                batch.append(PulledEvent(
                    runtimeID: runtimeID,
                    sequence: entry.sequence,
                    gap: next.gap,
                    encodedEvent: entry.encodedEvent
                ))
                used += estimate
                connection.subscriptions[runtimeID]!.cursor = entry.sequence
                connection.subscriptions[runtimeID]!.condensedNext = next.condensedID.map { $0 + 1 }
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
            state.byteCount -= runtime.byteCount + runtime.condensedByteCount
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
                if historyBudget > 0 {
                    // A thirty-second of the budget at a time: long enough for most tool calls'
                    // updates to fold into them, short enough that condensing under the lock
                    // takes milliseconds.
                    state.byteCount += state.runtimes[id]!.condenseOldest(blockBytes: max(1, runtimeBudget / 32), budget: historyBudget)
                } else {
                    state.byteCount -= state.runtimes[id]!.evictOldest()
                }
            }
            while state.byteCount > globalBudget {
                let oldest = state.runtimes
                    .compactMap { runtimeID, runtime in runtime.oldestOrder.map { (runtimeID, $0) } }
                    .min { $0.1 < $1.1 }
                guard let (victim, victimOrder) = oldest, victimOrder != order else { break }
                state.byteCount -= state.runtimes[victim]!.evictOldestOfAll()
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
            while let oldest = runtimes[id]!.firstCondensed?.entry.sequence, oldest <= limit {
                byteCount -= runtimes[id]!.dropOldestCondensed()
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
        /// The condensed entry to send next, while this cursor reads the condensed history;
        /// nil once it has sent an event from the journal.
        var condensedNext: UInt64?

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

    private struct CondensedEntry {
        /// Consecutive, but for one skipped where history was lost before it, so that a cursor
        /// reading the history notices.
        let id: UInt64
        var entry: Entry
    }

    private struct RuntimeJournal {
        /// Retained entries are `entries[head...]`, contiguous and in sequence order.
        var entries: [Entry] = []
        var head = 0
        var lastSequence: UInt64 = 0
        var evictedThrough: UInt64 = 0
        var retiredThrough: UInt64?
        /// Bytes in `entries`, which the runtime's budget limits.
        var byteCount = 0
        /// What condensing made of entries the budget pushed out, oldest first; retained
        /// entries are `condensed[condensedHead...]`.
        var condensed: [CondensedEntry] = []
        var condensedHead = 0
        var nextCondensedID: UInt64 = 1
        /// The last sequence condensed.
        var condensedThrough: UInt64 = 0
        /// Some of the history from the start is gone, condensed or not.
        var condensedTruncated = false
        var condensedByteCount = 0
        var attachedConnections = 0
        var detachedSince: ContinuousClock.Instant

        init(detachedSince: ContinuousClock.Instant) {
            self.detachedSince = detachedSince
        }

        var retainedCount: Int { entries.count - head }

        /// Condensed history is always older than the entries.
        var oldestOrder: UInt64? { firstCondensed?.entry.order ?? (head < entries.count ? entries[head].order : nil) }

        var firstCondensed: CondensedEntry? { condensedHead < condensed.count ? condensed[condensedHead] : nil }

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

        /// The next event for `subscription`, `gap` when something before it is lost: the
        /// condensed history while it reads that, then the entries after where it ends.
        func next(for subscription: Subscription) -> (entry: Entry, gap: Bool, condensedID: UInt64?)? {
            if let id = subscription.condensedNext {
                var low = condensedHead
                var high = condensed.count
                while low < high {
                    let middle = (low + high) / 2
                    if condensed[middle].id < id { low = middle + 1 } else { high = middle }
                }
                if low < condensed.count { return (condensed[low].entry, condensed[low].id != id, condensed[low].id) }
            }
            let cursor = subscription.condensedNext == nil ? subscription.cursor : max(subscription.cursor, condensedThrough)
            guard let index = index(after: cursor) else { return nil }
            return (entries[index], cursor < evictedThrough, nil)
        }

        /// Takes the oldest entries, about `blockBytes` of them and never the newest, into the
        /// condensed history, then drops its oldest past `budget`. Returns the change in bytes held.
        mutating func condenseOldest(blockBytes: Int, budget: Int) -> Int {
            let before = byteCount + condensedByteCount
            var block: [RemoteHistoryCondenser.Event] = []
            var taken = 0
            while retainedCount > 1, taken < blockBytes {
                let entry = entries[head]
                block.append(RemoteHistoryCondenser.Event(sequence: entry.sequence, encodedEvent: entry.encodedEvent, order: entry.order))
                taken += evictOldest()
            }
            guard let first = block.first, let last = block.last else { return 0 }
            if first.sequence > condensedThrough + 1 {
                // Dropped outright, by the global budget: the history before this block is gone.
                condensedTruncated = true
                nextCondensedID += 1
            }
            for event in RemoteHistoryCondenser.condense(block, maxEncodedEventBytes: LatchRemoteProtocol.maxEncodedEventBytes) {
                condensed.append(CondensedEntry(id: nextCondensedID,
                                                entry: Entry(sequence: event.sequence, encodedEvent: event.encodedEvent, order: event.order)))
                nextCondensedID += 1
                condensedByteCount += event.encodedEvent.count
            }
            condensedThrough = last.sequence
            while condensedByteCount > budget, firstCondensed != nil {
                _ = dropOldestCondensed()
            }
            return byteCount + condensedByteCount - before
        }

        /// Returns the bytes freed.
        mutating func dropOldestCondensed() -> Int {
            let freed = condensed[condensedHead].entry.encodedEvent.count
            condensed[condensedHead].entry.encodedEvent = Data()
            condensedHead += 1
            condensedByteCount -= freed
            condensedTruncated = true
            if condensedHead >= 1024, condensedHead * 2 >= condensed.count {
                condensed.removeFirst(condensedHead)
                condensedHead = 0
            }
            return freed
        }

        /// The oldest of the condensed history and the entries. Returns the bytes freed.
        mutating func evictOldestOfAll() -> Int {
            firstCondensed != nil ? dropOldestCondensed() : evictOldest()
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
