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
    /// An idle runtime nobody has been attached to for this long is stopped. Zero disables it.
    public var detachedTimeout: Duration = .seconds(24 * 60 * 60)
    public var reaperInterval: Duration = .seconds(60)
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

    /// Stops every runtime that is idle, has no pending permission, and has had no attached
    /// connection for the configured timeout as of `now`. A reaped runtime is forgotten
    /// rather than kept as exited, so a returning client's attach fails with `runtimeNotFound`
    /// and it resumes the session instead.
    public func reapDetachedRuntimes(now: ContinuousClock.Instant) async {
        let timeout = configuration.detachedTimeout
        guard timeout > .zero else { return }
        func isReapable(_ id: AgentRuntimeID) -> Bool {
            guard let state = runtimes[id], state.lifecycle == .ready, state.activeTurnID == nil,
                  state.pendingPermissions.isEmpty, let since = journal.detachedSince(id) else { return false }
            return since.duration(to: now) >= timeout
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
            workspace: workspace, workingDirectory: resolved.workingDirectory, launch: task
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
            // A failed launch leaves nothing behind, so the client can retry it.
            if runtimes[id]?.incarnation == incarnation, runtimes[id]?.lifecycle == .starting {
                runtimes[id] = nil
                journal.removeRuntime(id)
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
        guard var state = runtimes[id], state.lifecycle != .exited else { return }
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
        state.heldUpdates = []
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
                    // The client already has the history the load replayed; publish only what
                    // followed the reply.
                    runtimes[id]!.loadedThrough = response.localSequence
                    publishHeldUpdates(id, after: response.localSequence)
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
        runtimes[id] = state
        publish(Self.turnStarted(turnID, blocks: blocks), for: id)

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
                runtimes[id]!.hold(notification)
                return
            }
            // History that reached the hub after the load's reply did.
            if let loadedThrough = runtimes[id]!.loadedThrough, let sequence = notification.localSequence,
               sequence <= loadedThrough {
                return
            }
            publish(.sessionUpdate(notification: notification), for: id)

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

    /// Publishes the updates held while a load ran that came after `loadedThrough`, or all of
    /// them when the load failed or its reply had no sequence.
    private func publishHeldUpdates(_ id: AgentRuntimeID, after loadedThrough: UInt64?) {
        guard let held = runtimes[id]?.heldUpdates, !held.isEmpty else { return }
        runtimes[id]!.heldUpdates = []
        for notification in held {
            if let loadedThrough, let sequence = notification.localSequence, sequence <= loadedThrough { continue }
            publish(.sessionUpdate(notification: notification), for: id)
        }
    }

    /// Encodes once; every frame that carries the event splices these bytes.
    private func publish(_ event: LatchRemoteEvent, for id: AgentRuntimeID) {
        var encoded = (try? LatchRemoteCoding.encodeEvent(event)) ?? Data()
        if encoded.isEmpty || encoded.count > configuration.maxEncodedEventBytes {
            let omitted = LatchRemoteEvent.omitted(originalKind: event.kind, byteCount: encoded.count)
            encoded = (try? LatchRemoteCoding.encodeEvent(omitted)) ?? Data(#"{"kind":"omitted"}"#.utf8)
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
            pendingPermissions: state.pendingPermissions,
            lastSequence: journal.lastSequence(of: id),
            loadedThrough: state.loadedThrough
        )
    }

    private func summary(_ id: AgentRuntimeID, _ state: RuntimeState) -> LatchRemoteRuntimeSummary {
        LatchRemoteRuntimeSummary(
            runtimeID: id,
            agentTitle: state.agentTitle,
            workspace: state.workspace,
            lifecycle: state.lifecycle,
            activeTurnID: state.activeTurnID,
            pendingPermissionCount: state.pendingPermissions.count,
            lastSequence: journal.lastSequence(of: id)
        )
    }

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
    var heldUpdates: [ACPSessionNotification] = []
    /// The latest notification of each kind in `stateKinds`.
    var sessionState: [String: ACPSessionNotification] = [:]
    var configurationSets: [LatchRemoteConfigurationRoute: LatchRemoteConfigurationSet] = [:]
    var activeTurnID: UUID?
    var turns: [LatchRemoteTurnRecord] = []
    var pendingPermissions: [LatchRemotePendingPermission] = []

    init(
        incarnation: UInt64,
        agent: LatchRemoteAgent,
        agentTitle: String,
        workspace: String,
        workingDirectory: String,
        launch: Task<ACPInitializeResponse, any Error>
    ) {
        self.incarnation = incarnation
        self.agent = agent
        self.agentTitle = agentTitle
        self.workspace = workspace
        self.workingDirectory = workingDirectory
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

    /// Replayed history comes first and is dropped anyway; only the few updates that follow
    /// the reply matter, so a long history cannot grow this without bound.
    mutating func hold(_ notification: ACPSessionNotification) {
        heldUpdates.append(notification)
        if heldUpdates.count > 256 { heldUpdates.removeFirst(heldUpdates.count - 256) }
    }

    mutating func endTurn(_ turnID: UUID, stopReason: String?, error: LatchRemoteError?) {
        activeTurnID = nil
        guard let index = turns.lastIndex(where: { $0.turnID == turnID }) else { return }
        turns[index] = LatchRemoteTurnRecord(turnID: turnID, state: .ended, stopReason: stopReason, error: error)
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
