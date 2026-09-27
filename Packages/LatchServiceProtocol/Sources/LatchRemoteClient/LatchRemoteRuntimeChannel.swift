#if canImport(Network)
import Foundation
import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization

public enum LatchRemoteLinkState: Equatable, Sendable {
    case idle
    /// The first connection is being made.
    case connecting
    /// Handshake done and, when the channel is attached, re-attached.
    case connected
    /// The link was lost at `since` and has not come back yet.
    case reconnecting(since: Date)
    /// Permanent: the channel's streams have finished and every call fails with this.
    case failed(LatchRemoteClientError)
}

/// What an `attached` reply carried.
public struct LatchRemoteAttachment: Equatable, Sendable {
    public var record: LatchRemoteRuntimeRecord
    public var backlogFrom: UInt64
    /// Events after the requested cursor were evicted before they could be sent.
    public var truncated: Bool

    public init(record: LatchRemoteRuntimeRecord, backlogFrom: UInt64, truncated: Bool) {
        self.record = record
        self.backlogFrom = backlogFrom
        self.truncated = truncated
    }
}

public enum LatchRemoteChannelEvent: Equatable, Sendable {
    /// One journaled event, delivered once, in increasing `sequence` order.
    case event(sequence: UInt64, LatchRemoteEvent)
    /// Events were lost here: evicted from the server's journal before this client read them.
    case gap
    /// The channel re-attached on a new connection. Comes before that connection's backlog,
    /// and before `gap` when the attachment was truncated.
    case reattached(LatchRemoteAttachment)
}

/// One runtime on one server, across any number of connections. Link loss is invisible to
/// callers except through `linkStates`: commands wait for the next connection and are sent
/// again there, the runtime is re-attached from the last delivered sequence, and `events`
/// continues without repeats.
///
/// Sending a command again is safe because each is idempotent on the server, not because
/// the first attempt is known to have failed: `launchAgent` with the same ID, agent and
/// workspace and `newSession`/`loadSession` on a bound runtime return the recorded response;
/// set-* sets the same value; `prompt` is keyed by its turn ID; `cancelPrompt` is harmless
/// twice; `resolvePermission` treats `permissionRequestNotFound` as success and `stopRuntime`
/// treats `runtimeNotFound` as success.
///
/// Those rules assume this channel is the runtime's only client. `cancelPrompt` names no turn,
/// so a cancel still waiting for the link is dropped once the turn that was running when it
/// was submitted has ended, rather than reaching a later one. A set-* sent again after a
/// reconnect can still overwrite a change another client made in between.
///
/// The channel fails permanently, finishing both streams and every pending call, on
/// `unauthorized`, `protocolMismatch`, `destinationNotAllowed`, `runtimeNotFound` when
/// re-attaching, or `close()`. Anything else is retried with `backoff`.
public final class LatchRemoteRuntimeChannel: Sendable {
    public struct Options: Sendable {
        public var connection: LatchRemoteConnectionOptions
        public var runtimeID: AgentRuntimeID
        public var backoff: LatchRemoteBackoff
        /// How long `probe()` and `detach()` wait for the server.
        public var probeTimeout: Duration

        public init(
            host: String,
            port: UInt16 = LatchRemoteProtocol.defaultPort,
            token: LatchRemoteToken,
            allowUnencryptedNetwork: Bool = false,
            client: LatchRemoteClientInfo,
            runtimeID: AgentRuntimeID,
            backoff: LatchRemoteBackoff = LatchRemoteBackoff(),
            probeTimeout: Duration = .seconds(5),
            handshakeTimeout: Duration = .seconds(10)
        ) {
            self.init(
                connection: LatchRemoteConnectionOptions(
                    host: host,
                    port: port,
                    token: token,
                    allowUnencryptedNetwork: allowUnencryptedNetwork,
                    client: client,
                    handshakeTimeout: handshakeTimeout
                ),
                runtimeID: runtimeID,
                backoff: backoff,
                probeTimeout: probeTimeout
            )
        }

        public init(
            connection: LatchRemoteConnectionOptions,
            runtimeID: AgentRuntimeID,
            backoff: LatchRemoteBackoff = LatchRemoteBackoff(),
            probeTimeout: Duration = .seconds(5)
        ) {
            self.connection = connection
            self.runtimeID = runtimeID
            self.backoff = backoff
            self.probeTimeout = probeTimeout
        }
    }

    public let options: Options
    /// Single-consumer. Finishes only on permanent failure or `close()`.
    public let events: AsyncStream<LatchRemoteChannelEvent>
    /// Single-consumer. Every change of `linkState`, ending with `failed`.
    public let linkStates: AsyncStream<LatchRemoteLinkState>

    private let eventContinuation: AsyncStream<LatchRemoteChannelEvent>.Continuation
    private let linkContinuation: AsyncStream<LatchRemoteLinkState>.Continuation
    /// Every connection of this channel delivers here, so callbacks from an old connection
    /// and a new one never run at once.
    private let queue = DispatchQueue(label: "dev.latchapp.remote-channel")
    private let core = Mutex(Core())

    private struct Core {
        var started = false
        var failure: LatchRemoteClientError?
        var link = LatchRemoteLinkState.idle
        /// Identifies the current connection; callbacks from older ones are ignored.
        var generation = 0
        var connection: LatchRemoteConnection?
        /// Connected and, if attached, re-attached: queued commands may go out.
        var commandsReady = false
        /// Connection attempts since the channel was last connected, including its re-attach.
        var failures = 0
        var lostAt: Date?
        var reconnectTimer = 0
        var waitingToReconnect = false
        var reconnectImmediately = false
        var attached = false
        var cursor = LatchRemoteSequenceCursor()
        /// The last attach's `lastSequence`: events up to it are backlog the record already shows.
        var recordSequence: UInt64 = 0
        /// Turn ends and an exit the last attach's record showed, held until the backlog reaches
        /// `recordSequence` so a waiter never resolves ahead of its turn's events.
        var recordOutcomes: RecordOutcomes?
        /// After a truncated attach, the server flags its first backlog frame as a gap, which
        /// the attachment has already reported.
        var gapReported = false
        /// The turn the server was last seen running.
        var runningTurn: UUID?
        var commands: [PendingCommand] = []
        var turnWaiters: [UUID: [UUID: LatchRemoteOneShot<LatchRemoteTurnOutcome>]] = [:]
        var endedTurns: [UUID: LatchRemoteTurnOutcome] = [:]
        var endedTurnOrder: [UUID] = []
        var exited = false
    }

    private struct RecordOutcomes {
        var ended: [LatchRemoteTurnOutcome]
        var exited: Bool
    }

    private struct PendingCommand {
        enum Body {
            case command(LatchRemoteCommand)
            /// Becomes the cursor only once the server answers.
            case attach(after: UInt64)
        }

        let key: UUID
        let body: Body
        let shot: LatchRemoteOneShot<LatchRemoteResponse>
        /// For `cancelPrompt`, the turn that was running when it was submitted.
        var cancelTarget: UUID?
        /// The generation it was last written on; nil while waiting for a connection.
        var sentOn: Int?
    }

    /// How many ended turns are remembered for `awaitTurn` calls that come after the event.
    private static let endedTurnLimit = 64

    public init(options: Options) {
        self.options = options
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (linkStates, linkContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        close()
    }

    public var linkState: LatchRemoteLinkState {
        core.withLock { $0.link }
    }

    /// The last sequence delivered on `events`; 0 before the first.
    public var lastDeliveredSequence: UInt64 {
        core.withLock { $0.cursor.last }
    }

    /// Connects without sending anything yet. Every command does this on its own.
    public func start() {
        core.withLock { start(&$0) }
    }

    // MARK: - Commands

    /// Launches the runtime, then attaches from its first event, so its events follow.
    public func launch(agent: LatchRemoteAgent, workspace: String) async throws -> ACPInitializeResponse {
        let response = try await send(.launchAgent(runtimeID: options.runtimeID, agent: agent, workspace: workspace))
        guard case let .launched(initialization) = response else { throw unexpected(response) }
        _ = try await submitAttach(after: 0)
        return initialization
    }

    /// Attaches to a runtime launched earlier, such as by a previous run of the app, delivering
    /// events after `after`. The caller rebuilds its state from the record before reading them,
    /// and shows its own notice when the attachment is truncated: `events` reports no `gap`
    /// for it.
    public func attach(after: UInt64) async throws -> LatchRemoteAttachment {
        try await submitAttach(after: after)
    }

    /// Sends a command and returns its response, waiting through reconnects and sending it
    /// again on each new connection until a reply arrives. Use `launch`, `attach` and `detach`
    /// rather than sending those commands here.
    public func send(_ command: LatchRemoteCommand) async throws -> LatchRemoteResponse {
        try await submit(.command(command))
    }

    /// Sends a prompt and waits for its turn to end, across reconnects. A connection lost
    /// before the prompt was accepted sends it again with the same `turnID`, which the server
    /// accepts without running it twice. The channel must be attached.
    public func prompt(turnID: UUID, blocks: [ACPPromptBlock]) async throws -> LatchRemoteTurnOutcome {
        try core.withLock { core in
            if let failure = core.failure { throw failure }
            guard core.attached else { throw LatchRemoteClientError.notAttached }
        }
        let command = LatchRemoteCommand.prompt(runtimeID: options.runtimeID, turnID: turnID, blocks: blocks)
        let response: LatchRemoteResponse
        do {
            response = try await send(command)
        } catch LatchRemoteClientError.invalidReply {
            // The server may have started the turn; asking again by turn ID tells without running it twice.
            response = try await send(command)
        }
        guard case .promptAccepted(turnID) = response else { throw unexpected(response) }
        return try await awaitTurn(turnID)
    }

    /// Waits for a turn that is already running, such as the record's `activeTurnID` after
    /// `attach(after:)`. A turn whose runtime exits first ends with `runtimeExited`.
    public func awaitTurn(_ turnID: UUID) async throws -> LatchRemoteTurnOutcome {
        let shot = LatchRemoteOneShot<LatchRemoteTurnOutcome>()
        let waiterID = UUID()
        try core.withLock { core in
            if let outcome = core.endedTurns[turnID] {
                shot.finish(.success(outcome))
                return
            }
            if let failure = core.failure { throw failure }
            guard core.attached else { throw LatchRemoteClientError.notAttached }
            if core.exited {
                shot.finish(.success(Self.exitedOutcome(turnID)))
                return
            }
            core.turnWaiters[turnID, default: [:]][waiterID] = shot
        }
        return try await shot.wait { [weak self] in
            self?.core.withLock { core in
                core.turnWaiters[turnID]?[waiterID] = nil
                if core.turnWaiters[turnID]?.isEmpty == true { core.turnWaiters[turnID] = nil }
            }
        }
    }

    /// Stops following the runtime without stopping it. Best effort: sent once if the link is
    /// up, never retried. Attaches still pending and turns being awaited fail with `notAttached`.
    public func detach() async {
        let connection: LatchRemoteConnection? = core.withLock { core in
            core.attached = false
            core.recordOutcomes = nil
            let attaches = core.commands.filter { if case .attach = $0.body { true } else { false } }
            core.commands.removeAll { if case .attach = $0.body { true } else { false } }
            for command in attaches {
                command.shot.finish(.failure(LatchRemoteClientError.notAttached))
            }
            for waiters in core.turnWaiters.values {
                for shot in waiters.values {
                    shot.finish(.failure(LatchRemoteClientError.notAttached))
                }
            }
            core.turnWaiters = [:]
            return core.commandsReady ? core.connection : nil
        }
        _ = try? await connection?.request(.detach(runtimeID: options.runtimeID), timeout: options.probeTimeout)
    }

    // MARK: - Link

    /// Checks the link now, as after the Mac wakes: pings a connected server and reconnects at
    /// once when it does not answer in time, or skips the rest of a backoff wait.
    public func probe() async {
        enum Action {
            case ping(LatchRemoteConnection)
            case none
        }
        let action: Action = core.withLock { core in
            guard core.failure == nil, core.started else { return .none }
            if core.waitingToReconnect {
                connect(&core)
                return .none
            }
            if let connection = core.connection, case .ready = connection.state {
                return .ping(connection)
            }
            return .none
        }
        guard case let .ping(connection) = action else { return }
        do {
            try await connection.ping(timeout: options.probeTimeout)
        } catch is CancellationError {
            return
        } catch {
            core.withLock { core in
                if core.connection === connection { core.reconnectImmediately = true }
            }
            connection.close(with: .timedOut)
        }
    }

    /// Drops the current connection as if the network had, so tests can exercise reconnects.
    public func dropConnectionForTesting() {
        core.withLock { $0.connection }?.close(with: .connectionLost)
    }

    /// Ends the channel: the connection closes, both streams finish, and pending calls fail
    /// with `closed`. The runtime keeps running. Idempotent.
    public func close() {
        core.withLock { fail(&$0, with: .closed) }
    }

    // MARK: - Commands, internally

    private func submitAttach(after: UInt64) async throws -> LatchRemoteAttachment {
        let response = try await submit(.attach(after: after))
        guard case let .attached(record, backlogFrom, truncated) = response else { throw unexpected(response) }
        return LatchRemoteAttachment(record: record, backlogFrom: backlogFrom, truncated: truncated)
    }

    private func submit(_ body: PendingCommand.Body) async throws -> LatchRemoteResponse {
        let shot = LatchRemoteOneShot<LatchRemoteResponse>()
        let key = UUID()
        try core.withLock { core in
            if let failure = core.failure { throw failure }
            var pending = PendingCommand(key: key, body: body, shot: shot)
            if case .command(.cancelPrompt(options.runtimeID)) = body {
                pending.cancelTarget = core.runningTurn
            }
            core.commands.append(pending)
            start(&core)
            flush(&core)
        }
        return try await shot.wait { [weak self] in
            self?.core.withLock { $0.commands.removeAll { $0.key == key } }
        }
    }

    private func flush(_ core: inout Core) {
        guard core.commandsReady, let connection = core.connection else { return }
        let endedTurns = core.endedTurns
        dropCancels(&core) { endedTurns[$0] != nil }
        for index in core.commands.indices where core.commands[index].sentOn == nil {
            core.commands[index].sentOn = core.generation
            let command: LatchRemoteCommand = switch core.commands[index].body {
            case let .command(command): command
            case let .attach(after): .attach(runtimeID: options.runtimeID, after: after)
            }
            let key = core.commands[index].key
            let generation = core.generation
            connection.request(command) { [weak self] result in
                self?.commandCompleted(key, generation: generation, result: result)
            }
        }
    }

    private func commandCompleted(_ key: UUID, generation: Int, result: Result<LatchRemoteResponse, any Error>) {
        core.withLock { core in
            guard let index = core.commands.firstIndex(where: { $0.key == key }),
                  core.commands[index].sentOn == generation
            else { return }
            if case let .failure(error as LatchRemoteClientError) = result, error.isLinkFailure {
                // Sent again once the link is back.
                core.commands[index].sentOn = nil
                return
            }
            let pending = core.commands.remove(at: index)
            switch (pending.body, result) {
            case let (.attach(after), .success(.attached(record, backlogFrom, truncated))):
                core.attached = true
                // The server resumes from no later than its last event, and so does the cursor.
                core.cursor = LatchRemoteSequenceCursor(after: min(after, record.lastSequence))
                attached(to: record, backlogFrom: backlogFrom, truncated: truncated, &core)
                pending.shot.finish(result)
            case let (.command(command), _):
                let outcome = switch result {
                case let .failure(error as LatchRemoteError): Self.idempotentResult(of: command, failure: error)
                default: result
                }
                if case let .stopRuntime(runtimeID) = command, runtimeID == options.runtimeID, case .success = outcome {
                    // A stopped runtime is never re-attached.
                    core.attached = false
                }
                pending.shot.finish(outcome)
            case (.attach, _):
                pending.shot.finish(result)
            }
        }
    }

    /// A retried command can find its first attempt's work already done.
    private static func idempotentResult(
        of command: LatchRemoteCommand,
        failure: LatchRemoteError
    ) -> Result<LatchRemoteResponse, any Error> {
        switch (command, failure.code) {
        case (.resolvePermission, .permissionRequestNotFound):
            .success(.permissionResolved)
        case (.stopRuntime, .runtimeNotFound):
            .success(.stopped)
        default:
            .failure(failure)
        }
    }

    // MARK: - Connections

    private func start(_ core: inout Core) {
        guard !core.started, core.failure == nil else { return }
        core.started = true
        setLink(.connecting, &core)
        connect(&core)
    }

    private func connect(_ core: inout Core) {
        core.waitingToReconnect = false
        core.reconnectTimer += 1
        core.generation += 1
        let generation = core.generation
        let connection = LatchRemoteConnection(
            options: options.connection,
            queue: queue,
            stateHandler: { [weak self] state in
                self?.connectionStateChanged(state, generation: generation)
            },
            eventHandler: { [weak self] frame in
                self?.received(frame, generation: generation)
            }
        )
        core.connection = connection
        connection.start()
    }

    private func connectionStateChanged(_ state: LatchRemoteConnection.State, generation: Int) {
        core.withLock { core in
            guard generation == core.generation, core.failure == nil else { return }
            switch state {
            case .idle, .connecting, .authenticating:
                break
            case .ready:
                if core.attached {
                    reattach(&core)
                } else {
                    connected(&core)
                }
            case let .closed(error):
                connectionClosed(error, &core)
            }
        }
    }

    private func reattach(_ core: inout Core) {
        guard let connection = core.connection else { return }
        let generation = core.generation
        connection.request(.attach(runtimeID: options.runtimeID, after: core.cursor.last)) { [weak self] result in
            self?.reattached(result, generation: generation)
        }
    }

    private func reattached(_ result: Result<LatchRemoteResponse, any Error>, generation: Int) {
        core.withLock { core in
            guard generation == core.generation, core.failure == nil else { return }
            switch result {
            case let .success(.attached(record, backlogFrom, truncated)):
                guard core.attached else {
                    // Detached while the re-attach was on its way.
                    connected(&core)
                    return
                }
                eventContinuation.yield(.reattached(LatchRemoteAttachment(record: record, backlogFrom: backlogFrom, truncated: truncated)))
                if truncated { eventContinuation.yield(.gap) }
                attached(to: record, backlogFrom: backlogFrom, truncated: truncated, &core)
                // A cancel held through the outage is meant for a turn that has since ended.
                dropCancels(&core) { $0 != record.activeTurnID }
                connected(&core)
            case let .failure(error as LatchRemoteError) where error.code == .runtimeNotFound:
                fail(&core, with: .runtimeNotFound(message: error.message))
            case let .failure(error as LatchRemoteClientError) where error.isLinkFailure:
                // The connection closed; its state change reconnects.
                break
            case .success, .failure:
                // Anything else is unexpected; try again on a fresh connection after a backoff.
                core.connection?.close(with: .protocolViolation("The server did not re-attach the runtime."))
            }
        }
    }

    private func connected(_ core: inout Core) {
        core.failures = 0
        core.commandsReady = true
        core.lostAt = nil
        setLink(.connected, &core)
        flush(&core)
    }

    private func connectionClosed(_ error: LatchRemoteClientError, _ core: inout Core) {
        core.connection = nil
        core.commandsReady = false
        for index in core.commands.indices {
            core.commands[index].sentOn = nil
        }
        if error.isPermanent {
            fail(&core, with: error)
            return
        }
        let lostAt = core.lostAt ?? Date()
        core.lostAt = lostAt
        setLink(.reconnecting(since: lostAt), &core)

        let delay = core.reconnectImmediately ? .zero : options.backoff.delay(afterFailures: core.failures)
        core.reconnectImmediately = false
        core.failures += 1
        core.reconnectTimer += 1
        core.waitingToReconnect = true
        let timer = core.reconnectTimer
        queue.asyncAfter(deadline: .now() + delay.dispatchInterval) { [weak self] in
            self?.core.withLock { core in
                guard core.waitingToReconnect, core.reconnectTimer == timer, core.failure == nil else { return }
                self?.connect(&core)
            }
        }
    }

    private func received(_ frame: LatchRemoteEventFrame, generation: Int) {
        core.withLock { core in
            guard generation == core.generation, core.failure == nil, core.attached, frame.runtimeID == options.runtimeID,
                  core.cursor.admit(frame.sequence)
            else { return }
            if frame.gap, !core.gapReported { eventContinuation.yield(.gap) }
            core.gapReported = false
            eventContinuation.yield(.event(sequence: frame.sequence, frame.event))
            let isNew = frame.sequence > core.recordSequence
            switch frame.event {
            case let .turnStarted(turnID, _, _) where isNew:
                core.runningTurn = turnID
            case let .turnEnded(turnID, stopReason, error):
                if isNew, core.runningTurn == turnID { core.runningTurn = nil }
                turnEnded(LatchRemoteTurnOutcome(turnID: turnID, stopReason: stopReason, error: error), &core)
            case .exited:
                if isNew { core.runningTurn = nil }
                runtimeExited(&core)
            default:
                break
            }
            if core.cursor.last >= core.recordSequence {
                applyRecordOutcomes(&core)
            }
        }
    }

    // MARK: - Turns

    /// Takes in an attach's record. Its ended turns and exit cover events evicted from the
    /// journal while nobody read them, but take effect only once the backlog has been
    /// delivered, or at once when there is none.
    private func attached(to record: LatchRemoteRuntimeRecord, backlogFrom: UInt64, truncated: Bool, _ core: inout Core) {
        core.recordSequence = record.lastSequence
        core.runningTurn = record.activeTurnID
        core.gapReported = truncated
        core.recordOutcomes = RecordOutcomes(
            ended: record.turns.filter { $0.state == .ended }.map {
                LatchRemoteTurnOutcome(turnID: $0.turnID, stopReason: $0.stopReason, error: $0.error)
            },
            exited: record.lifecycle == .exited
        )
        if backlogFrom > record.lastSequence || core.cursor.last >= record.lastSequence {
            applyRecordOutcomes(&core)
        }
    }

    private func applyRecordOutcomes(_ core: inout Core) {
        guard let outcomes = core.recordOutcomes else { return }
        core.recordOutcomes = nil
        for outcome in outcomes.ended {
            turnEnded(outcome, &core)
        }
        if outcomes.exited {
            runtimeExited(&core)
        }
    }

    /// The server ends an active turn before the runtime's exit, so anyone still waiting was
    /// waiting on a turn that will never end.
    private func runtimeExited(_ core: inout Core) {
        core.exited = true
        for turnID in Array(core.turnWaiters.keys) {
            turnEnded(Self.exitedOutcome(turnID), &core)
        }
    }

    /// Answers queued cancels whose target turn matches without sending them: the server
    /// would cancel whatever turn is running now instead.
    private func dropCancels(_ core: inout Core, where isStale: (UUID) -> Bool) {
        let stale = core.commands.filter { $0.sentOn == nil && $0.cancelTarget.map(isStale) == true }
        guard !stale.isEmpty else { return }
        core.commands.removeAll { command in stale.contains { $0.key == command.key } }
        for command in stale {
            command.shot.finish(.success(.cancelRequested))
        }
    }

    private func turnEnded(_ outcome: LatchRemoteTurnOutcome, _ core: inout Core) {
        if core.endedTurns[outcome.turnID] == nil {
            core.endedTurns[outcome.turnID] = outcome
            core.endedTurnOrder.append(outcome.turnID)
            if core.endedTurnOrder.count > Self.endedTurnLimit {
                core.endedTurns[core.endedTurnOrder.removeFirst()] = nil
            }
        }
        let waiters = core.turnWaiters.removeValue(forKey: outcome.turnID) ?? [:]
        let stored = core.endedTurns[outcome.turnID] ?? outcome
        for shot in waiters.values {
            shot.finish(.success(stored))
        }
    }

    private static func exitedOutcome(_ turnID: UUID) -> LatchRemoteTurnOutcome {
        LatchRemoteTurnOutcome(
            turnID: turnID,
            stopReason: nil,
            error: LatchRemoteError(code: .runtimeExited, message: "The agent exited before the turn ended.")
        )
    }

    // MARK: - State

    private func setLink(_ state: LatchRemoteLinkState, _ core: inout Core) {
        guard core.link != state else { return }
        core.link = state
        linkContinuation.yield(state)
    }

    private func fail(_ core: inout Core, with error: LatchRemoteClientError) {
        guard core.failure == nil else { return }
        core.failure = error
        core.commandsReady = false
        core.waitingToReconnect = false
        core.reconnectTimer += 1
        core.connection?.close()
        core.connection = nil
        setLink(.failed(error), &core)
        linkContinuation.finish()
        eventContinuation.finish()
        for command in core.commands {
            command.shot.finish(.failure(error))
        }
        core.commands = []
        for waiters in core.turnWaiters.values {
            for shot in waiters.values {
                shot.finish(.failure(error))
            }
        }
        core.turnWaiters = [:]
    }

    private func unexpected(_ response: LatchRemoteResponse) -> LatchRemoteClientError {
        .protocolViolation("An unexpected \(response.kind) reply arrived.")
    }
}
#endif
