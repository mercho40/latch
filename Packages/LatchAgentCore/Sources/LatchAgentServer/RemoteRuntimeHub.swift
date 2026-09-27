import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol

/// Limits and timings for a `RemoteRuntimeHub`.
public struct RemoteRuntimeHubConfiguration: Sendable {
    /// Journaled event bytes kept per runtime; the oldest go first.
    public var runtimeJournalBudget = 8 * 1024 * 1024
    /// Journaled event bytes kept across all runtimes, exited ones included.
    public var globalJournalBudget = 128 * 1024 * 1024
    /// An event whose encoding is larger is journaled as `omitted`.
    public var maxEncodedEventBytes = LatchRemoteProtocol.maxEncodedEventBytes
    /// An idle runtime nobody has been attached to for this long is stopped. Zero disables it,
    /// and `detachedPermissionTimeout` with it.
    public var detachedTimeout: Duration = .seconds(24 * 60 * 60)
    /// A runtime whose turn is held up by a permission request nobody has been attached to
    /// answer for this long is stopped too: a client that stopped it while the server was out
    /// of reach, and forgot it, would otherwise leave it running for good.
    public var detachedPermissionTimeout: Duration = .seconds(7 * 24 * 60 * 60)
    public var reaperInterval: Duration = .seconds(60)
    /// How long after a load's reply the hub waits for the rest of the history the load
    /// replayed, when nothing it has received shows that all of it is in. What the hub itself
    /// publishes for the runtime meanwhile waits too, so that it follows the history.
    public var replayDrainTimeout: Duration = .seconds(1)
    /// Exited runtimes whose record stays attachable, and whose IDs cannot be reused.
    public var retainedExitedRuntimes = 8
    public var retainedTurns = 64

    public init() {}
}

/// What the hub reports for the server's log.
public enum RemoteRuntimeLifecycleEvent: Equatable, Sendable {
    case launched(agentTitle: String)
    /// Stopped on request, by the detached reaper, or by shutdown.
    case stopped
    case exited(status: Int32?)
    /// A launch that never got as far as `launched`: the agent could not be found, could not
    /// start, or exited or failed while starting, with its status if it exited. `executable`
    /// is the resolved path, when it got that far; `reason` is for the server's log only.
    case failedToLaunch(agentTitle: String?, executable: String?, status: Int32?, reason: String)
}

extension RemoteRuntimeLifecycleEvent {
    /// The log line for `failedToLaunch`: the one place a failed launch is explained, since
    /// the client is told only that the agent command failed.
    static func failedLaunchLine(_ id: AgentRuntimeID, agentTitle: String?, executable: String?, status: Int32?,
                                 reason: String, standardErrorLogged: Bool) -> String {
        var line = "runtime \(id.rawValue) failed to launch"
        if let agentTitle { line += " " + ServerLog.escape(agentTitle) }
        if let executable { line += " (" + ServerLog.escape(executable) + ")" }
        if let status { line += ": the agent exited with status \(status) while starting" }
        let reason = reason.count > 300 ? String(reason.prefix(300)) + "…" : reason
        line += "; " + ServerLog.escape(reason)
        if executable != nil, !standardErrorLogged {
            line += "; run latch-server with --log-agent-stderr to see what the agent printed"
        }
        return line
    }
}

/// The server's only consumer of `LatchAgentService.events`: it journals each runtime's events
/// for replay, remembers what a reattaching client needs, and gives network retries their
/// idempotent meaning. Transport-agnostic; a connection layer drives it:
///
/// 1. `openConnection(wake:)` when a client authenticates, `closeConnection(_:)` when it goes.
///    Closing drops only that connection's cursors; turns and permission waits keep running.
/// 2. `handle(_:from:)` for every request.
/// 3. The writer drains its reply queue and writes the replies. Right after writing an
///    `attached` reply it calls `activateAttachment(of:for:)`; until then the cursor that
///    attach created or replaced yields nothing, while events accumulate behind it in the
///    journal.
/// 4. Then it writes what `pullEventLines(for:byteBudget:)` returns, and repeats. When a pull
///    returns nothing, the writer sleeps until `wake` runs.
///
/// Because only the writer activates, and only once the reply is on the wire, no event of a
/// runtime is written before its `attached` reply, and lines pulled from a cursor that a later
/// `attach` or `detach` replaced are always written before that reply, never after it.
public actor RemoteRuntimeHub {
    private let service: LatchAgentService
    private let configuration: RemoteRuntimeHubConfiguration
    private let launchEnvironment: @Sendable () -> AgentLaunchEnvironment
    private let homeDirectory: String
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let standardError: (@Sendable (AgentRuntimeID, Data) -> Void)?
    private let lifecycle: (@Sendable (AgentRuntimeID, RemoteRuntimeLifecycleEvent) -> Void)?
    private let journal: RemoteEventJournal

    private var runtimes: [AgentRuntimeID: RuntimeState] = [:]
    /// Exited runtimes, oldest first.
    private var exited: [AgentRuntimeID] = []
    private var nextIncarnation: UInt64 = 0
    private var nextBinding: UInt64 = 0
    private var isShutDown = false
    private var eventTask: Task<Void, Never>?
    private var reaperTask: Task<Void, Never>?

    /// - Parameters:
    ///   - launchEnvironment: The server's own environment, made per launch so newly installed
    ///     agents are found.
    ///   - homeDirectory: Where a `~/` workspace points.
    ///   - standardError: Agent stderr, which is never journaled or sent. Dropped when nil;
    ///     otherwise called on the hub's actor, so it must not block.
    ///   - lifecycle: Launches, stops and exits, for logging. Called on the hub's actor.
    public init(
        service: LatchAgentService,
        configuration: RemoteRuntimeHubConfiguration = RemoteRuntimeHubConfiguration(),
        launchEnvironment: @escaping @Sendable () -> AgentLaunchEnvironment = { AgentLaunchEnvironment() },
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        standardError: (@Sendable (AgentRuntimeID, Data) -> Void)? = nil,
        lifecycle: (@Sendable (AgentRuntimeID, RemoteRuntimeLifecycleEvent) -> Void)? = nil
    ) {
        self.service = service
        self.configuration = configuration
        self.launchEnvironment = launchEnvironment
        self.homeDirectory = homeDirectory
        self.clock = clock
        self.standardError = standardError
        self.lifecycle = lifecycle
        journal = RemoteEventJournal(
            runtimeBudget: configuration.runtimeJournalBudget,
            globalBudget: configuration.globalJournalBudget,
            clock: clock
        )
    }

    /// Begins consuming the service's events and, unless disabled, reaping detached runtimes.
    public func start() {
        guard eventTask == nil else { return }
        let events = service.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.ingest(event)
            }
        }
        guard configuration.detachedTimeout > .zero else { return }
        let interval = configuration.reaperInterval
        let clock = clock
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.reapDetachedRuntimes(now: clock())
            }
        }
    }

    /// Refuses further commands, stops consuming events, and stops every runtime, including
    /// any whose launch was in flight. Waits for those launches, so no agent outlives it.
    public func shutdown() async {
        isShutDown = true
        eventTask?.cancel()
        reaperTask?.cancel()
        eventTask = nil
        reaperTask = nil
        var launches: [(AgentRuntimeID, Task<ACPInitializeResponse, any Error>)] = []
        for (id, state) in runtimes where state.lifecycle != .exited {
            if let launch = state.launch { launches.append((id, launch)) }
            finish(id, exit: LatchRemoteExit(status: nil, stopped: true), keepJournal: false)
        }
        await service.shutdown()
        // A launch task that had not reached the registry yet starts its agent only now.
        for (id, launch) in launches where (try? await launch.value) != nil {
            _ = try? await runService(.stopRuntime(id: id))
        }
    }

    // MARK: Connections

    /// `wake` runs, on whatever thread published, whenever one of the connection's active
    /// cursors has a new event to pull. It must not block.
    public nonisolated func openConnection(wake: @escaping @Sendable () -> Void) -> RemoteConnectionID {
        journal.openConnection(wake: wake)
    }

    public nonisolated func closeConnection(_ connection: RemoteConnectionID) {
        journal.closeConnection(connection)
    }

    /// Lets the cursor an `attach` created or replaced yield events. The writer calls it once
    /// per `attached` reply, right after writing it; see the type's documentation for the
    /// ordering this provides.
    public nonisolated func activateAttachment(of runtimeID: AgentRuntimeID, for connection: RemoteConnectionID) {
        journal.activate(connection, runtimeID: runtimeID)
    }

    /// Ready-to-write event frame lines, each ending in a newline, round-robin across the
    /// connection's active cursors and advancing them. At least one line when any is ready,
    /// however large; otherwise stops short of `byteBudget`. Synchronous and non-blocking, for
    /// a writer thread.
    public nonisolated func pullEventLines(for connection: RemoteConnectionID, byteBudget: Int) -> [Data] {
        journal.pull(connection, byteBudget: byteBudget)
    }

    // MARK: Commands

    public func handle(_ command: LatchRemoteCommand, from connection: RemoteConnectionID) async -> LatchRemoteReplyResult {
        guard !isShutDown else {
            return .failure(LatchRemoteError(code: .commandFailed, message: "The server is shutting down."))
        }
        // Exhaustive on purpose: a new command must not compile until its network policy is decided.
        switch command {
        case let .launchAgent(runtimeID, agent, workspace):
            return await launch(runtimeID, agent: agent, workspace: workspace)
        case let .newSession(runtimeID):
            return await bindSession(runtimeID, request: .new)
        case let .loadSession(runtimeID, sessionID):
            return await bindSession(runtimeID, request: .load(sessionID))
        case let .setConfigOption(runtimeID, configID, value):
            return await configure(runtimeID, .setSessionConfigOption(runtimeID: runtimeID, configID: configID, value: value)) {
                guard case let .sessionConfigOptionSet(_, response) = $0 else { return nil }
                return (.configOptionSet(response: response), LatchRemoteConfigurationSet(
                    route: .config, configID: configID, value: value,
                    acpSequence: response.localSequence, configOptions: response.configOptions
                ))
            }
        case let .setModel(runtimeID, modelID):
            return await configure(runtimeID, .setSessionModel(runtimeID: runtimeID, modelID: modelID)) {
                guard case let .sessionModelSet(_, sequence) = $0 else { return nil }
                return (.modelSet(sequence: sequence), LatchRemoteConfigurationSet(route: .model, value: modelID, acpSequence: sequence))
            }
        case let .setMode(runtimeID, modeID):
            return await configure(runtimeID, .setSessionMode(runtimeID: runtimeID, modeID: modeID)) {
                guard case let .sessionModeSet(_, sequence) = $0 else { return nil }
                return (.modeSet(sequence: sequence), LatchRemoteConfigurationSet(route: .mode, value: modeID, acpSequence: sequence))
            }
        case let .prompt(runtimeID, turnID, blocks):
            return startTurn(runtimeID, turnID: turnID, blocks: blocks)
        case let .cancelPrompt(runtimeID):
            return await cancelTurn(runtimeID)
        case let .resolvePermission(runtimeID, requestID, outcome):
            return await resolvePermission(runtimeID, requestID: requestID, outcome: outcome)
        case let .attach(runtimeID, after):
            guard let state = runtimes[runtimeID] else { return .failure(.runtimeNotFound) }
            let (backlogFrom, truncated) = journal.subscribe(connection, to: runtimeID, after: after)
            return .success(.attached(record: record(runtimeID, state), backlogFrom: backlogFrom, truncated: truncated))
        case let .detach(runtimeID):
            journal.unsubscribe(connection, from: runtimeID)
            return .success(.detached)
        case let .stopRuntime(runtimeID):
            await stop(runtimeID)
            return .success(.stopped)
        case .listRuntimes:
            return .success(.runtimes(runtimes.keys.sorted { $0.rawValue < $1.rawValue }.map { summary($0, runtimes[$0]!) }))
        case .unknown:
            return .failure(LatchRemoteError(code: .unsupportedCommand, message: "This server does not support that command."))
        }
    }

    /// Stops every runtime that has had no attached connection as of `now` for the configured
    /// timeout and is idle, or for `detachedPermissionTimeout` and is waiting on a permission
    /// request. One running a turn that waits on nothing is never stopped. A reaped runtime is
    /// forgotten rather than kept as exited, so a returning client's attach fails with
    /// `runtimeNotFound` and it resumes the session instead.
    public func reapDetachedRuntimes(now: ContinuousClock.Instant) async {
        let timeout = configuration.detachedTimeout
        guard timeout > .zero else { return }
        let permissionTimeout = max(timeout, configuration.detachedPermissionTimeout)
        func isReapable(_ id: AgentRuntimeID) -> Bool {
            guard let state = runtimes[id], state.lifecycle == .ready, let since = journal.detachedSince(id) else { return false }
            let detached = since.duration(to: now)
            if state.pendingPermissions.isEmpty { return state.activeTurnID == nil && detached >= timeout }
            return detached >= permissionTimeout
        }
        for id in runtimes.keys.sorted(by: { $0.rawValue < $1.rawValue }) where isReapable(id) {
            // Earlier stops suspended; check again before this one.
            guard isReapable(id) else { continue }
            await stop(id, forget: true)
        }
    }

    // MARK: Launch and stop

    private func launch(_ id: AgentRuntimeID, agent: LatchRemoteAgent, workspace: String) async -> LatchRemoteReplyResult {
        guard LatchRemoteProtocol.isValidRuntimeID(id.rawValue) else {
            return .failure(LatchRemoteError(code: .invalidRequest, message: "Runtime IDs are 1 to 64 letters, digits, dots, dashes or underscores."))
        }
        if let existing = runtimes[id] {
            // A retry of the launch that made this runtime gets that launch's result.
            guard existing.lifecycle != .exited, existing.agent == agent, existing.workspace == workspace else {
                return .failure(LatchRemoteError(code: .duplicateRuntime, message: "A runtime with this ID already exists."))
            }
            if let initialization = existing.initialization { return .success(.launched(initialization: initialization)) }
            guard let task = existing.launch else { return .failure(.runtimeNotFound) }
            return await launchResult(of: task, id: id, incarnation: existing.incarnation)
        }

        let resolved: RemoteAgentLaunch
        do {
            resolved = try RemoteAgentLaunch(
                agent: agent, workspace: workspace, environment: launchEnvironment(), homeDirectory: homeDirectory
            )
        } catch {
            lifecycle?(id, .failedToLaunch(agentTitle: nil, executable: nil, status: nil, reason: error.message))
            return .failure(error)
        }
        let profile = resolved.profile
        let task = Task { [service] () throws -> ACPInitializeResponse in
            guard case let .runtimeStarted(_, initialization) = try await service.execute(.startRuntime(id: id, profile: profile)) else {
                throw HubError.unexpectedResponse
            }
            return initialization
        }
        nextIncarnation += 1
        runtimes[id] = RuntimeState(
            incarnation: nextIncarnation, agent: agent, agentTitle: resolved.agentTitle,
            workspace: workspace, workingDirectory: resolved.workingDirectory,
            executablePath: profile.executablePath, launch: task
        )
        journal.createRuntime(id)
        return await launchResult(of: task, id: id, incarnation: nextIncarnation)
    }

    private func launchResult(
        of task: Task<ACPInitializeResponse, any Error>,
        id: AgentRuntimeID,
        incarnation: UInt64
    ) async -> LatchRemoteReplyResult {
        do {
            let initialization = try await task.value
            if runtimes[id]?.incarnation == incarnation, runtimes[id]?.lifecycle == .starting {
                runtimes[id]!.lifecycle = .ready
                runtimes[id]!.initialization = initialization
                runtimes[id]!.launch = nil
                lifecycle?(id, .launched(agentTitle: runtimes[id]!.agentTitle))
                // The agent may have exited before this continuation ran.
                if let status = runtimes[id]!.terminationWhileStarting {
                    finish(id, exit: LatchRemoteExit(status: status, stopped: false), keepJournal: true)
                }
            }
            return .success(.launched(initialization: initialization))
        } catch {
            // A failed launch leaves nothing behind, so the client can retry it. The client
            // hears only that the command failed; the log says what happened.
            if let state = runtimes[id], state.incarnation == incarnation, state.lifecycle == .starting {
                runtimes[id] = nil
                journal.removeRuntime(id)
                lifecycle?(id, .failedToLaunch(agentTitle: state.agentTitle, executable: state.executablePath,
                                               status: state.terminationWhileStarting, reason: String(describing: error)))
            }
            return .failure(Self.remoteError(for: error))
        }
    }

    /// Idempotent: an unknown or exited runtime is already stopped. `forget` drops the runtime
    /// once its agent has stopped, freeing the ID; until then it is exited and ignores events.
    private func stop(_ id: AgentRuntimeID, forget: Bool = false) async {
        guard let state = runtimes[id], state.lifecycle != .exited else { return }
        finish(id, exit: LatchRemoteExit(status: nil, stopped: true), keepJournal: false, retain: !forget)
        _ = try? await runService(.stopRuntime(id: id))
        if forget, runtimes[id]?.incarnation == state.incarnation {
            runtimes[id] = nil
            journal.removeRuntime(id)
        }
    }

    /// Ends a runtime's journal with `exited` as its last event, after `turnEnded` for an
    /// active turn and `permissionClosed` for each pending request. Anything published for it
    /// later is ignored. After a crash the registry has usually closed the requests already,
    /// so they may precede `turnEnded`; only `exited` being last is guaranteed.
    private func finish(_ id: AgentRuntimeID, exit: LatchRemoteExit, keepJournal: Bool, retain: Bool = true) {
        guard runtimes[id]?.lifecycle != .exited else { return }
        // What waited for history that will not come now goes first.
        endReplayDrain(id)
        guard var state = runtimes[id] else { return }
        let before = journal.lastSequence(of: id)
        if let turnID = state.activeTurnID {
            let error = LatchRemoteError.runtimeExited
            state.endTurn(turnID, stopReason: nil, error: error)
            runtimes[id] = state
            publish(.turnEnded(turnID: turnID, stopReason: nil, error: error), for: id)
        }
        for pending in state.pendingPermissions {
            publish(.permissionClosed(requestID: pending.requestID), for: id)
        }
        state.pendingPermissions = []
        // History of a load that never finished.
        state.heldUpdates = HeldUpdates()
        state.lifecycle = .exited
        state.exit = exit
        state.launch = nil
        runtimes[id] = state
        publish(.exited(exit), for: id)
        lifecycle?(id, exit.stopped ? .stopped : .exited(status: exit.status))
        // A crash keeps its journal for whoever reattaches. A stop keeps only the closing
        // events above, once viewers still attached have been sent what came before them.
        if !keepJournal { journal.retire(id, through: before) }

        guard retain else { return }
        exited.append(id)
        while exited.count > configuration.retainedExitedRuntimes {
            let oldest = exited.removeFirst()
            runtimes[oldest] = nil
            journal.removeRuntime(oldest)
        }
    }

    // MARK: Sessions

    private func bindSession(_ id: AgentRuntimeID, request: SessionRequest) async -> LatchRemoteReplyResult {
        guard var state = runtimes[id] else { return .failure(.runtimeNotFound) }
        guard state.lifecycle != .exited else { return .failure(.runtimeGone) }

        switch state.binding {
        case let .bound(.new(response)) where request == .new:
            return .success(.sessionCreated(response: response))
        case let .bound(.load(response)) where request == .load(state.sessionID ?? ""):
            return .success(.sessionLoaded(response: response))
        case .bound:
            return .failure(LatchRemoteError(code: .sessionAlreadyBound, message: "This runtime already has a session."))
        case let .binding(pending, token, task):
            guard pending == request else {
                return .failure(LatchRemoteError(code: .sessionAlreadyBound, message: "This runtime already has a session."))
            }
            return await bindingResult(of: task, id: id, token: token)
        case .unbound:
            guard state.lifecycle == .ready else {
                return .failure(LatchRemoteError(code: .busy, message: "The agent is still starting."))
            }
        }

        let cwd = state.workingDirectory
        let task: Task<LatchRemoteSessionBinding, any Error>
        switch request {
        case .new:
            task = Task { [service] in
                guard case let .sessionCreated(_, session) = try await service.execute(.newSession(runtimeID: id, cwd: cwd)) else {
                    throw HubError.unexpectedResponse
                }
                return .new(session)
            }
        case let .load(sessionID):
            task = Task { [service] in
                guard case let .sessionLoaded(_, response) = try await service.execute(
                    .loadSession(runtimeID: id, sessionID: sessionID, cwd: cwd)
                ) else {
                    throw HubError.unexpectedResponse
                }
                return .load(response)
            }
        }
        nextBinding += 1
        state.binding = .binding(request, token: nextBinding, task)
        runtimes[id] = state
        return await bindingResult(of: task, id: id, token: nextBinding)
    }

    private func bindingResult(
        of task: Task<LatchRemoteSessionBinding, any Error>,
        id: AgentRuntimeID,
        token: UInt64
    ) async -> LatchRemoteReplyResult {
        do {
            let binding = try await task.value
            // Only the first of several awaiting retries records the binding.
            if case let .binding(request, current, _)? = runtimes[id]?.binding, current == token {
                switch (request, binding) {
                case (.new, let .new(response)):
                    runtimes[id]!.sessionID = response.sessionId
                case let (.load(sessionID), .load(response)):
                    runtimes[id]!.sessionID = sessionID
                    // The client that loaded it already has the history the load replayed; it
                    // is journaled marked as replay, for viewers that do not.
                    runtimes[id]!.loadedThrough = response.localSequence
                    let complete = publishHeldUpdates(id, after: response.localSequence)
                    if let loadedThrough = response.localSequence, !complete {
                        beginReplayDrain(id, loadedThrough: loadedThrough, token: token)
                    } else {
                        finishReplayTitle(id)
                    }
                default:
                    break
                }
                runtimes[id]!.binding = .bound(binding)
            }
            switch binding {
            case let .new(response): return .success(.sessionCreated(response: response))
            case let .load(response): return .success(.sessionLoaded(response: response))
            case .unknown: return .failure(Self.remoteError(for: HubError.unexpectedResponse))
            }
        } catch {
            if case let .binding(_, current, _)? = runtimes[id]?.binding, current == token {
                runtimes[id]!.binding = .unbound
                publishHeldUpdates(id, after: nil)
            }
            return .failure(Self.remoteError(for: error))
        }
    }

    /// Forwards a set-* command, then publishes what it set.
    private func configure(
        _ id: AgentRuntimeID,
        _ command: LatchAgentCommand,
        reply: (LatchAgentResponse) -> (LatchRemoteResponse, LatchRemoteConfigurationSet)?
    ) async -> LatchRemoteReplyResult {
        guard let state = runtimes[id] else { return .failure(.runtimeNotFound) }
        guard state.lifecycle != .exited else { return .failure(.runtimeGone) }
        guard case .bound = state.binding else { return .failure(.noSession) }
        do {
            let serviceResponse = try await runService(command)
            guard let (response, configurationSet) = reply(serviceResponse) else {
                throw HubError.unexpectedResponse
            }
            if runtimes[id]?.incarnation == state.incarnation, runtimes[id]?.lifecycle == .ready {
                runtimes[id]!.configurationSets[configurationSet.route] = configurationSet
                publish(.configurationSet(configurationSet), for: id)
            }
            return .success(response)
        } catch {
            return .failure(Self.remoteError(for: error))
        }
    }

    // MARK: Turns

    /// Every check happens before the first suspension, so two prompts cannot both start.
    private func startTurn(_ id: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock]) -> LatchRemoteReplyResult {
        guard var state = runtimes[id] else { return .failure(.runtimeNotFound) }
        // A resend after a lost reply; the outcome arrives, or arrived, as `turnEnded`.
        if state.turns.contains(where: { $0.turnID == turnID }) { return .success(.promptAccepted(turnID: turnID)) }
        guard state.lifecycle != .exited else { return .failure(.runtimeGone) }
        guard case .bound = state.binding else { return .failure(.noSession) }
        guard state.activeTurnID == nil else {
            return .failure(LatchRemoteError(code: .busy, message: "A turn is already running."))
        }

        state.activeTurnID = turnID
        state.turns.append(LatchRemoteTurnRecord(turnID: turnID, state: .running))
        if state.turns.count > configuration.retainedTurns {
            state.turns.removeFirst(state.turns.count - configuration.retainedTurns)
        }
        let started = Self.turnStarted(turnID, blocks: blocks)
        if state.title == nil, case let .turnStarted(_, text, _) = started { state.title = Self.title(of: text) }
        runtimes[id] = state
        publish(started, for: id)

        // Not tied to any connection: the turn runs to its end whoever is listening.
        let incarnation = state.incarnation
        Task { [service] in
            let outcome: (stopReason: String?, error: LatchRemoteError?)
            do {
                guard case let .promptCompleted(_, response) = try await service.execute(.prompt(runtimeID: id, blocks: blocks)) else {
                    throw HubError.unexpectedResponse
                }
                outcome = (response.stopReason, nil)
            } catch {
                outcome = (nil, Self.turnError(for: error))
            }
            self.endTurn(id, turnID: turnID, incarnation: incarnation, stopReason: outcome.stopReason, error: outcome.error)
        }
        return .success(.promptAccepted(turnID: turnID))
    }

    private func endTurn(_ id: AgentRuntimeID, turnID: UUID, incarnation: UInt64, stopReason: String?, error: LatchRemoteError?) {
        // An exit or stop already ended it.
        guard var state = runtimes[id], state.incarnation == incarnation, state.lifecycle != .exited,
              state.activeTurnID == turnID else { return }
        state.endTurn(turnID, stopReason: stopReason, error: error)
        runtimes[id] = state
        publish(.turnEnded(turnID: turnID, stopReason: stopReason, error: error), for: id)
    }

    /// Idempotent: with no turn running there is nothing to cancel.
    private func cancelTurn(_ id: AgentRuntimeID) async -> LatchRemoteReplyResult {
        guard let state = runtimes[id] else { return .failure(.runtimeNotFound) }
        guard state.lifecycle != .exited, let turnID = state.activeTurnID else { return .success(.cancelRequested) }
        do {
            _ = try await runService(.cancelPrompt(runtimeID: id))
        } catch {
            // Fails only if that turn is still running; one that ended, or whose runtime exited
            // or went away, while the cancel was on its way has nothing left to cancel.
            if let current = runtimes[id], current.incarnation == state.incarnation, current.lifecycle != .exited,
               current.activeTurnID == turnID {
                return .failure(Self.remoteError(for: error))
            }
        }
        return .success(.cancelRequested)
    }

    private func resolvePermission(_ id: AgentRuntimeID, requestID: UUID, outcome: ACPPermissionOutcome) async -> LatchRemoteReplyResult {
        guard let state = runtimes[id] else { return .failure(.runtimeNotFound) }
        guard state.pendingPermissions.contains(where: { $0.requestID == requestID }) else {
            return .failure(.permissionRequestNotFound)
        }
        do {
            _ = try await runService(.resolvePermission(runtimeID: id, requestID: requestID, outcome: outcome))
            return .success(.permissionResolved)
        } catch {
            return .failure(Self.remoteError(for: error))
        }
    }

    // MARK: Events

    private func ingest(_ event: LatchAgentEvent) {
        switch event {
        case let .sessionUpdate(id, notification):
            guard runtimes[id]?.lifecycle != .exited, runtimes[id] != nil else { return }
            runtimes[id]!.remember(notification)
            if case .binding(.load, _, _) = runtimes[id]!.binding {
                // Most likely history the load is replaying; `bindingResult` decides.
                let encoded = Self.encodedReplay(of: notification)
                runtimes[id]!.hold(notification, as: encoded, fitsAFrame: fitsAFrame(encoded),
                                   budget: configuration.runtimeJournalBudget)
                return
            }
            let sequence = notification.localSequence
            let loadedThrough = runtimes[id]!.loadedThrough
            let isHistory = sequence.flatMap { sequence in loadedThrough.map { sequence <= $0 } } ?? false
            // History that reached the hub after the load's reply did.
            if isHistory { publishReplayed(notification, for: id) }
            if let sequence, runtimes[id]!.replayDrain?.isComplete(through: sequence) == true { endReplayDrain(id) }
            if !isHistory { publish(.sessionUpdate(notification: notification), for: id) }

        case let .standardError(id, data):
            standardError?(id, data)

        case let .processTerminated(id, status):
            guard let state = runtimes[id] else { return }
            if state.lifecycle == .starting {
                // The launch's continuation decides: it fails, or it finishes the runtime.
                runtimes[id]!.terminationWhileStarting = status
                return
            }
            finish(id, exit: LatchRemoteExit(status: status, stopped: false), keepJournal: true)

        case let .permissionRequested(id, requestID, request):
            guard runtimes[id]?.lifecycle != .exited, runtimes[id] != nil else { return }
            runtimes[id]!.pendingPermissions.append(LatchRemotePendingPermission(requestID: requestID, request: request))
            publish(.permissionRequested(requestID: requestID, request: request), for: id)

        case let .permissionClosed(id, requestID):
            guard runtimes[id]?.lifecycle != .exited,
                  let index = runtimes[id]?.pendingPermissions.firstIndex(where: { $0.requestID == requestID }) else { return }
            runtimes[id]!.pendingPermissions.remove(at: index)
            publish(.permissionClosed(requestID: requestID), for: id)
        }
    }

    /// Publishes the updates held while a load ran, those up to `loadedThrough` marked as
    /// replay, or all of them unmarked when the load failed or its reply had no sequence.
    /// Returns whether they show that all of the load's history is in.
    @discardableResult
    private func publishHeldUpdates(_ id: AgentRuntimeID, after loadedThrough: UInt64?) -> Bool {
        guard let held = runtimes[id]?.heldUpdates, !held.isEmpty else { return false }
        runtimes[id]!.heldUpdates = HeldUpdates()
        var complete = false
        for update in held.updates {
            let isHistory = update.localSequence.flatMap { sequence in loadedThrough.map { sequence <= $0 } } ?? false
            if let loadedThrough, let sequence = update.localSequence {
                complete = complete || ReplayDrain.isComplete(through: sequence, loadedThrough: loadedThrough)
            }
            switch (update.notification, isHistory) {
            case let (notification?, true):
                publishReplayed(notification, encoded: update.encodedReplay, for: id)
            case let (notification?, false):
                publish(.sessionUpdate(notification: notification), for: id)
            case (nil, true):
                // Too large for a frame, and history: left out, as `publishReplayed` would.
                break
            case (nil, false):
                publish(.omitted(originalKind: "sessionUpdate", byteCount: update.byteCount), for: id)
            }
        }
        return complete
    }

    /// Journals history a load replayed. One update too large for a frame is left out rather
    /// than journaled as `omitted`, which would tell the client that loaded it, and has it,
    /// that output was lost.
    private func publishReplayed(_ notification: ACPSessionNotification, encoded: Data? = nil, for id: AgentRuntimeID) {
        collectReplayTitle(id, from: notification)
        let encoded = encoded ?? Self.encodedReplay(of: notification)
        guard fitsAFrame(encoded) else { return }
        journal.append(encoded, to: id)
    }

    private func fitsAFrame(_ encoded: Data) -> Bool {
        !encoded.isEmpty && encoded.count <= configuration.maxEncodedEventBytes
    }

    private static func encodedReplay(of notification: ACPSessionNotification) -> Data {
        (try? LatchRemoteCoding.encodeEvent(.sessionUpdate(notification: notification, replay: true))) ?? Data()
    }

    /// Holds back what the hub publishes for the runtime until the rest of the history the
    /// load replayed is in: that history reaches the hub through several streams, and the
    /// reply through none, so a prompt or set-* command handled now could otherwise be
    /// journaled before or among it. Ended by an update from the frame before the reply or
    /// later, by the runtime finishing, or by the timeout.
    private func beginReplayDrain(_ id: AgentRuntimeID, loadedThrough: UInt64, token: UInt64) {
        runtimes[id]!.replayDrain = ReplayDrain(loadedThrough: loadedThrough, token: token)
        let timeout = configuration.replayDrainTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.endReplayDrain(id, token: token)
        }
    }

    /// Publishes what waited for the load's history, and takes the title that history gives.
    /// With a `token`, only the drain that load began.
    private func endReplayDrain(_ id: AgentRuntimeID, token: UInt64? = nil) {
        guard let drain = runtimes[id]?.replayDrain, token.map({ $0 == drain.token }) ?? true else { return }
        runtimes[id]!.replayDrain = nil
        finishReplayTitle(id)
        for event in drain.deferred { publish(event, for: id) }
    }

    /// The first user message of the history a load replayed names the runtime, as the
    /// prompt of its first turn would have, for devices that did not load it.
    private func collectReplayTitle(_ id: AgentRuntimeID, from notification: ACPSessionNotification) {
        guard var prompt = runtimes[id]?.replayedPrompt else { return }
        if case let .messageChunk(chunk) = notification.event, chunk.role == .user {
            // Enough for a first line; a pasted file need not be kept whole.
            guard prompt.utf8.count < 4096 else { return }
            prompt += chunk.text ?? ""
            runtimes[id]!.replayedPrompt = prompt
        } else if Self.title(of: prompt) != nil {
            finishReplayTitle(id)
        }
    }

    private func finishReplayTitle(_ id: AgentRuntimeID) {
        guard let prompt = runtimes[id]?.replayedPrompt, let title = Self.title(of: prompt) else { return }
        runtimes[id]!.replayedPrompt = nil
        // Earlier in the conversation than any turn since the load.
        runtimes[id]!.title = title
    }

    /// Encodes once; every frame that carries the event splices these bytes. While a load's
    /// history is still on its way, the event waits for it.
    private func publish(_ event: LatchRemoteEvent, for id: AgentRuntimeID) {
        if runtimes[id]?.replayDrain != nil {
            runtimes[id]!.replayDrain!.deferred.append(event)
            return
        }
        var encoded = (try? LatchRemoteCoding.encodeEvent(event)) ?? Data()
        if encoded.isEmpty || encoded.count > configuration.maxEncodedEventBytes {
            // A request left out could never be answered: it goes as its summary instead.
            if case let .permissionRequested(requestID, request) = event,
               let summary = try? LatchRemoteCoding.encodeEvent(.permissionRequested(requestID: requestID, request: Self.summary(of: request))),
               summary.count <= configuration.maxEncodedEventBytes {
                encoded = summary
            } else {
                let omitted = LatchRemoteEvent.omitted(originalKind: event.kind, byteCount: encoded.count)
                encoded = (try? LatchRemoteCoding.encodeEvent(omitted)) ?? Data(#"{"kind":"omitted"}"#.utf8)
            }
        }
        journal.append(encoded, to: id)
    }

    // MARK: Records

    private func record(_ id: AgentRuntimeID, _ state: RuntimeState) -> LatchRemoteRuntimeRecord {
        var session: LatchRemoteSessionBinding?
        if case let .bound(binding) = state.binding { session = binding }
        return LatchRemoteRuntimeRecord(
            runtimeID: id,
            agent: state.agent,
            agentTitle: state.agentTitle,
            workspace: state.workspace,
            lifecycle: state.lifecycle,
            exit: state.exit,
            initialization: state.initialization,
            sessionID: session == nil ? nil : state.sessionID,
            session: session,
            state: state.sessionState.values.sorted { ($0.localSequence ?? 0) < ($1.localSequence ?? 0) },
            configurationSets: state.configurationSets.values.sorted { $0.route.rawValue < $1.route.rawValue },
            activeTurnID: state.activeTurnID,
            turns: state.turns,
            pendingPermissions: Self.recorded(state.pendingPermissions, budget: configuration.maxEncodedEventBytes / 2),
            lastSequence: journal.lastSequence(of: id),
            loadedThrough: state.loadedThrough
        )
    }

    /// Pending requests as an attach's record carries them. A record goes in one frame, and a
    /// runtime may have several requests of megabytes each, such as edits with large diffs:
    /// past `budget` bytes, a request goes as its summary, which can still be shown and answered.
    static func recorded(_ pending: [LatchRemotePendingPermission], budget: Int) -> [LatchRemotePendingPermission] {
        let encoder = JSONEncoder()
        var used = 0
        return pending.map { permission in
            let size = (try? encoder.encode(permission).count) ?? Int.max
            if size <= budget - used {
                used += size
                return permission
            }
            let summarized = LatchRemotePendingPermission(requestID: permission.requestID, request: summary(of: permission.request))
            used += (try? encoder.encode(summarized).count) ?? 0
            return summarized
        }
    }

    /// A request cut to what identifies it and what answering it needs: the tool call's ID,
    /// kind, status and title, the title shortened, and the options. Its content, such as a
    /// diff, and its raw input are left out.
    static func summary(of request: ACPPermissionRequest) -> ACPPermissionRequest {
        var toolCall: [String: ACPJSONValue] = [:]
        if case let .object(fields) = request.toolCall {
            for key in ["toolCallId", "kind", "status", "title"] {
                guard case let .string(value)? = fields[key] else { continue }
                toolCall[key] = .string(value.count > summaryFieldLength ? String(value.prefix(summaryFieldLength)) + "…" : value)
            }
        }
        return ACPPermissionRequest(sessionId: request.sessionId, toolCall: .object(toolCall), options: request.options)
    }

    private static let summaryFieldLength = 1024

    private func summary(_ id: AgentRuntimeID, _ state: RuntimeState) -> LatchRemoteRuntimeSummary {
        LatchRemoteRuntimeSummary(
            runtimeID: id,
            agentTitle: state.agentTitle,
            workspace: state.workspace,
            lifecycle: state.lifecycle,
            activeTurnID: state.activeTurnID,
            pendingPermissionCount: state.pendingPermissions.count,
            lastSequence: journal.lastSequence(of: id),
            title: state.title,
            agent: state.agent
        )
    }

    /// A prompt's text as a runtime's title: its first line with any text, each run of
    /// whitespace made one space, at most `titleLength` characters with the ellipsis.
    static func title(of text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > titleLength ? String(line.prefix(titleLength - 1)) + "…" : line
    }

    static let titleLength = 80

    // MARK: Helpers

    /// In an unstructured task, so a request cancelled with its connection never cancels the
    /// agent's work.
    private func runService(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        try await Task { [service] in try await service.execute(command) }.value
    }

    private static func turnStarted(_ turnID: UUID, blocks: [ACPPromptBlock]) -> LatchRemoteEvent {
        var text: [String] = []
        var attachments: [LatchRemoteAttachmentSummary] = []
        for block in blocks {
            switch block {
            case let .text(value):
                text.append(value)
            case let .image(data, mimeType):
                attachments.append(LatchRemoteAttachmentSummary(kind: "image", mimeType: mimeType, byteCount: data.count))
            case let .resourceLink(_, name, mimeType):
                attachments.append(LatchRemoteAttachmentSummary(kind: "resourceLink", mimeType: mimeType, name: name, byteCount: 0))
            }
        }
        return .turnStarted(turnID: turnID, text: text.joined(separator: "\n"), attachments: attachments)
    }

    /// A prompt that failed because the agent went away ended with the runtime, not in error.
    private static func turnError(for error: any Error) -> LatchRemoteError {
        switch error {
        case ACPJSONRPCConnectionError.closed, AgentRuntimeRegistryError.runtimeNotFound, is ACPAgentRuntimeError:
            return .runtimeExited
        default:
            return remoteError(for: error)
        }
    }

    static func remoteError(for error: any Error) -> LatchRemoteError {
        let failure = LatchAgentService.publicFailure(for: error)
        let code: LatchRemoteFailureCode
        switch error {
        case AgentRuntimeRegistryError.runtimeNotFound: code = .runtimeNotFound
        case AgentRuntimeRegistryError.duplicateRuntime: code = .duplicateRuntime
        case AgentRuntimeRegistryError.permissionRequestNotFound: code = .permissionRequestNotFound
        case AgentRuntimeRegistryError.invalidPermissionOption: code = .invalidPermissionOption
        case ACPClientError.noActiveSession: return .noSession
        case ACPClientError.promptAlreadyActive:
            return LatchRemoteError(code: .busy, message: "A turn is already running.")
        default: code = failure.code == .authenticationRequired ? .authenticationRequired : .commandFailed
        }
        return LatchRemoteError(code: code, message: failure.message)
    }
}

private enum HubError: Error {
    case unexpectedResponse
}

private enum SessionRequest: Equatable {
    case new
    case load(String)
}

private enum SessionBindingState {
    case unbound
    /// Retries of the same request await the same task.
    case binding(SessionRequest, token: UInt64, Task<LatchRemoteSessionBinding, any Error>)
    case bound(LatchRemoteSessionBinding)
}

private struct RuntimeState {
    /// Distinguishes this launch from a later one under the same ID.
    let incarnation: UInt64
    let agent: LatchRemoteAgent
    let agentTitle: String
    /// As the client sent it; retries compare against this.
    let workspace: String
    let workingDirectory: String
    let executablePath: String
    var lifecycle = LatchRemoteLifecycle.starting
    var exit: LatchRemoteExit?
    var launch: Task<ACPInitializeResponse, any Error>?
    var terminationWhileStarting: Int32?
    var initialization: ACPInitializeResponse?
    var binding = SessionBindingState.unbound
    var sessionID: String?
    var loadedThrough: UInt64?
    /// Session updates that arrived while a load ran, unpublished until its reply says which
    /// were replayed history.
    var heldUpdates = HeldUpdates()
    /// From a load's reply until the history it replayed is all journaled.
    var replayDrain: ReplayDrain?
    /// The first user message of a load's history so far; nil once it has named the runtime.
    var replayedPrompt: String? = ""
    /// The latest notification of each kind in `stateKinds`.
    var sessionState: [String: ACPSessionNotification] = [:]
    var configurationSets: [LatchRemoteConfigurationRoute: LatchRemoteConfigurationSet] = [:]
    var activeTurnID: UUID?
    var turns: [LatchRemoteTurnRecord] = []
    var pendingPermissions: [LatchRemotePendingPermission] = []
    /// From the first turn whose prompt had text.
    var title: String?

    init(
        incarnation: UInt64,
        agent: LatchRemoteAgent,
        agentTitle: String,
        workspace: String,
        workingDirectory: String,
        executablePath: String,
        launch: Task<ACPInitializeResponse, any Error>
    ) {
        self.incarnation = incarnation
        self.agent = agent
        self.agentTitle = agentTitle
        self.workspace = workspace
        self.workingDirectory = workingDirectory
        self.executablePath = executablePath
        self.launch = launch
    }

    static let stateKinds: Set<String> = [
        "config_option_update", "current_mode_update", "current_model_update", "available_commands_update",
    ]

    mutating func remember(_ notification: ACPSessionNotification) {
        guard case let .object(update) = notification.update, case let .string(kind)? = update["sessionUpdate"],
              Self.stateKinds.contains(kind) else { return }
        if let previous = sessionState[kind]?.localSequence, let sequence = notification.localSequence, sequence < previous {
            return
        }
        sessionState[kind] = notification
    }

    /// `encodedReplay` is how the update is journaled if it turns out to be history, as nearly
    /// all of it is. Held to the journal's budget for one runtime, beyond which the journal
    /// would evict the oldest anyway.
    mutating func hold(_ notification: ACPSessionNotification, as encodedReplay: Data, fitsAFrame: Bool, budget: Int) {
        heldUpdates.append(HeldUpdate(notification, encodedReplay: encodedReplay, fitsAFrame: fitsAFrame), budget: budget)
    }

    mutating func endTurn(_ turnID: UUID, stopReason: String?, error: LatchRemoteError?) {
        activeTurnID = nil
        guard let index = turns.lastIndex(where: { $0.turnID == turnID }) else { return }
        turns[index] = LatchRemoteTurnRecord(turnID: turnID, state: .ended, stopReason: stopReason, error: error)
    }
}

private struct HeldUpdate {
    let localSequence: UInt64?
    /// Nil for one too large for a frame, which is never journaled whole: as history it is
    /// left out, and otherwise it goes as `omitted`. Only its size is kept, and it costs
    /// nothing against the budget, so it cannot push out the history held before it.
    let notification: ACPSessionNotification?
    let encodedReplay: Data
    /// Of the encoding, whether or not it is kept.
    let byteCount: Int

    init(_ notification: ACPSessionNotification, encodedReplay: Data, fitsAFrame: Bool) {
        localSequence = notification.localSequence
        self.notification = fitsAFrame ? notification : nil
        self.encodedReplay = fitsAFrame ? encodedReplay : Data()
        byteCount = encodedReplay.count
    }
}

/// See `RemoteRuntimeHub.beginReplayDrain`.
private struct ReplayDrain {
    let loadedThrough: UInt64
    /// The binding's, so a timeout ends only the drain its load began.
    let token: UInt64
    /// Published once the drain ends, in order.
    var deferred: [LatchRemoteEvent] = []

    func isComplete(through sequence: UInt64) -> Bool {
        Self.isComplete(through: sequence, loadedThrough: loadedThrough)
    }

    /// An agent replays a session's history and then replies, so the frame just before the
    /// reply is the last of the history, and every stream keeps the order: once the hub has
    /// an update from that frame or later, nothing the load replayed is still on its way.
    static func isComplete(through sequence: UInt64, loadedThrough: UInt64) -> Bool {
        sequence >= loadedThrough || loadedThrough - sequence == 1
    }
}

/// Updates held while a load runs, the oldest dropped past a byte budget.
private struct HeldUpdates {
    /// Held updates are `storage[head...]`; dropped ones before `head` are nil until compacted.
    private var storage: [HeldUpdate?] = []
    private var head = 0
    private var byteCount = 0

    var isEmpty: Bool { head == storage.count }

    var updates: [HeldUpdate] { storage[head...].compactMap { $0 } }

    /// The newest always stays, even when it alone is over budget.
    mutating func append(_ update: HeldUpdate, budget: Int) {
        storage.append(update)
        byteCount += update.encodedReplay.count
        while byteCount > budget, storage.count - head > 1 {
            byteCount -= storage[head]?.encodedReplay.count ?? 0
            storage[head] = nil
            head += 1
        }
        // Compact occasionally so dropping stays O(1) amortized.
        if head >= 1024, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}

extension LatchRemoteError {
    static let runtimeNotFound = LatchRemoteError(code: .runtimeNotFound, message: "Runtime not found.")
    /// Ends a turn whose runtime went away.
    static let runtimeExited = LatchRemoteError(code: .runtimeExited, message: "The agent exited.")
    /// Answers a command for an exited runtime, whose record is still attachable.
    static let runtimeGone = LatchRemoteError(code: .runtimeNotFound, message: "The agent has exited.")
    static let noSession = LatchRemoteError(code: .noSession, message: "Start or load a session first.")
    static let permissionRequestNotFound = LatchRemoteError(
        code: .permissionRequestNotFound, message: "Permission request not found."
    )
}
