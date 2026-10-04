import Foundation
import LatchACP
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization

/// A session's service on a server, behind the same contract as this Mac's: a long-held
/// prompt reply, and an event stream that finishes only when the runtime is out of reach for
/// good. Each runtime gets a `LatchRemoteRuntimeChannel`, made when it launches or is attached
/// to again, after a relaunch or a failed link, and closed when it stops, is detached from or
/// the next one is followed. The channel reconnects, re-attaches and sends pending commands
/// again on its own, and a change in Settings points it at the server the new way in place.
/// Nothing here retries a command: the channel's retries are safe because every command is
/// idempotent on the server.
public final class RemoteAgentServiceClient: AgentServiceClient {
    /// Only the client's lifetime: `remoteEvents` carries the events, with their sequences.
    public let events: AsyncStream<LatchAgentEvent>
    public let remoteEvents: AsyncStream<RemoteServiceEvent>?
    public var isRemote: Bool { true }
    /// The server in Settings this client reaches, whatever it is called or wherever it is now.
    public let serverID: UUID

    private let lifetime: AsyncStream<LatchAgentEvent>.Continuation
    private let continuation: AsyncStream<RemoteServiceEvent>.Continuation
    /// The server as Settings has it now; nil once it has been removed.
    private let readServer: @MainActor @Sendable () -> ServerProfile?
    private let backoff: LatchRemoteBackoff
    private let firstConnectionLimit: Duration
    private let state: Mutex<State>

    /// How long stopping a runtime waits for the server. Past it the runtime is left running
    /// there, and the server's idle reaper stops it later.
    static let stopTimeout: Duration = .seconds(10)

    private struct State {
        /// The server as it was last read, for messages and the transport description.
        var server: ServerProfile
        /// How the last channel made here reaches the server: `server` as it was then, or
        /// as a change in Settings that channel took up. Not updated for a channel that had
        /// already failed, so the session can tell that its settings have moved on since.
        var reached: ServerProfile
        /// Changes in Settings taken up by the channel in place, each of which gives a first
        /// connection its full time again.
        var reconnections = 0
        var runtime: Runtime?
        var finished = false
        /// Every runtime's stop, once asked for or once none is needed. A second stop of one
        /// waits for the first, and never opens a channel of its own.
        var stops: [AgentRuntimeID: Task<Void, any Error>] = [:]
        /// Runtimes attached to rather than launched here. The server has them whether or not
        /// this client ever reached it, so they always need a stop of their own.
        var attached: Set<AgentRuntimeID> = []
    }

    private struct Runtime {
        let id: AgentRuntimeID
        let channel: LatchRemoteRuntimeChannel
        /// Launched and attached: a permanent failure from here on ends the client.
        var launched = false
        /// This client asked the server to stop it, so its exit is expected.
        var stopping = false
    }

    /// `firstConnectionLimit` bounds a runtime's first connection; see `firstConnection`.
    init(server: ServerProfile, backoff: LatchRemoteBackoff = LatchRemoteBackoff(),
         firstConnectionLimit: Duration = .seconds(15),
         readServer: @escaping @MainActor @Sendable () -> ServerProfile?) {
        self.readServer = readServer
        serverID = server.id
        self.backoff = backoff
        self.firstConnectionLimit = firstConnectionLimit
        state = Mutex(State(server: server, reached: server))
        (events, lifetime) = AsyncStream.makeStream()
        let (stream, continuation) = AsyncStream<RemoteServiceEvent>.makeStream(bufferingPolicy: .unbounded)
        remoteEvents = stream
        self.continuation = continuation
    }

    deinit {
        close()
    }

    public var transportDescription: String { "remote \(state.withLock { $0.server.address })" }

    // MARK: Commands

    public func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        guard case let .remote(agent, path) = launch else {
            throw LatchAgentFailure(code: .invalidRequest, message: "A remote session cannot run a command on \(thisDevice).")
        }
        let (channel, server) = try await follow(id)
        relayEvents(channel, runtimeID: id)
        let initialization = try await firstConnection(of: channel, id: id, server: server) {
            try await channel.launch(agent: agent, workspace: path)
        }
        state.withLock { state in
            if state.runtime?.channel === channel { state.runtime?.launched = true }
        }
        return .runtimeStarted(runtimeID: id, initialization: initialization)
    }

    /// Follows a runtime an earlier run of Latch left on the server. Its events are read only
    /// once the attach has answered, so `.attached` and the record's pending permissions reach
    /// the session ahead of the backlog.
    public func attach(runtimeID id: AgentRuntimeID, after cursor: UInt64) async throws -> LatchRemoteAttachment {
        let (channel, server) = try await follow(id)
        state.withLock { _ = $0.attached.insert(id) }
        let attachment: LatchRemoteAttachment
        do {
            attachment = try await firstConnection(of: channel, id: id, server: server) {
                do {
                    return try await channel.attach(after: cursor)
                } catch let error as LatchRemoteError where error.code == .runtimeNotFound {
                    throw RemoteRuntimeGone(server: serverName)
                }
            }
        } catch {
            // Nothing to follow; a runtime the server no longer has needs no stop either.
            release(id, channel, exited: error is RemoteRuntimeGone)
            throw error
        }
        let current = state.withLock { state in
            guard state.runtime?.channel === channel else { return false }
            state.runtime?.launched = true
            return true
        }
        guard current else { throw LatchRemoteClientError.closed }
        yield(.attached(runtimeID: id, attachment, server: serverName), from: channel)
        relayEvents(channel, runtimeID: id, attached: attachment)
        return attachment
    }

    /// Makes `id` the runtime this client follows, on a channel of its own that has started
    /// connecting. Its link changes are relayed from now on; its events are for the caller to relay.
    private func follow(_ id: AgentRuntimeID) async throws -> (LatchRemoteRuntimeChannel, ServerProfile) {
        guard let server = await readServer() else { throw RemoteSessionNotConnected.serverRemoved }
        let channel = LatchRemoteRuntimeChannel(options: LatchRemoteRuntimeChannel.Options(
            connection: server.connectionOptions, runtimeID: id, backoff: backoff))
        let replaced: Runtime? = try state.withLock { state in
            guard !state.finished else { throw LatchRemoteClientError.closed }
            let replaced = state.runtime
            state.server = server
            state.reached = server
            state.runtime = Runtime(id: id, channel: channel)
            return replaced
        }
        // Left running on the server, if it still is: stopping it is `SessionModel`'s call.
        if let replaced { release(replaced.id, replaced.channel) }
        relayLinks(channel)
        channel.start()
        return (channel, server)
    }

    /// Runs a runtime's first command. One whose server has not answered once within
    /// `firstConnectionLimit` fails: a wrong address or a server that is not running is for
    /// Settings to fix, not for waiting out. A fix made in Settings meanwhile gets the whole
    /// limit to answer in.
    private func firstConnection<Value: Sendable>(
        of channel: LatchRemoteRuntimeChannel, id: AgentRuntimeID, server: ServerProfile,
        _ body: () async throws -> Value
    ) async throws -> Value {
        let watchdog = Task { [firstConnectionLimit, weak self] in
            var seen = self?.state.withLock { $0.reconnections }
            while true {
                try await Task.sleep(for: firstConnectionLimit)
                guard !channel.hasConnected, let self else { return }
                let now = state.withLock { $0.reconnections }
                guard now != seen else { return release(id, channel) }
                seen = now
            }
        }
        defer { watchdog.cancel() }
        do {
            return try await mapFailures(server: server.name, body)
        } catch where !channel.hasConnected && channel.linkState == .failed(.closed) {
            // The watchdog's close, or the session's own stop, before the server ever answered.
            let server = state.withLock { $0.server }
            throw RemoteServerFailure(message: "\(server.name) is not answering at \(server.address). "
                + "Check that latch-server is running there and that \(serversPlace) has its address right.")
        }
    }

    public func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .newSession(id, _):
            // The server starts the session in the runtime's workspace, the path it launched in.
            guard case let .sessionCreated(response) = try await send(.newSession(runtimeID: id), to: id) else {
                throw Self.unexpectedReply
            }
            return .sessionCreated(runtimeID: id, session: response)
        case let .loadSession(id, sessionID, _):
            guard case let .sessionLoaded(response) = try await send(.loadSession(runtimeID: id, sessionID: sessionID), to: id) else {
                throw Self.unexpectedReply
            }
            return .sessionLoaded(runtimeID: id, response: response)
        case let .setSessionConfigOption(id, configID, value):
            guard case let .configOptionSet(response) = try await send(
                .setConfigOption(runtimeID: id, configID: configID, value: value), to: id) else {
                throw Self.unexpectedReply
            }
            return .sessionConfigOptionSet(runtimeID: id, response: response)
        case let .setSessionModel(id, modelID):
            guard case let .modelSet(sequence) = try await send(.setModel(runtimeID: id, modelID: modelID), to: id) else {
                throw Self.unexpectedReply
            }
            return .sessionModelSet(runtimeID: id, sequence: sequence)
        case let .setSessionMode(id, modeID):
            guard case let .modeSet(sequence) = try await send(.setMode(runtimeID: id, modeID: modeID), to: id) else {
                throw Self.unexpectedReply
            }
            return .sessionModeSet(runtimeID: id, sequence: sequence)
        case let .prompt(id, blocks):
            return try await prompt(runtimeID: id, turnID: UUID(), blocks: blocks)
        case let .cancelPrompt(id):
            _ = try await send(.cancelPrompt(runtimeID: id), to: id)
            return .promptCancellationRequested(runtimeID: id)
        case let .resolvePermission(id, requestID, outcome):
            _ = try await send(.resolvePermission(runtimeID: id, requestID: requestID, outcome: outcome), to: id)
            return .permissionResolved(runtimeID: id, requestID: requestID)
        case let .resolveElicitation(id, requestID, response):
            _ = try await send(.resolveElicitation(runtimeID: id, requestID: requestID, response: response), to: id)
            return .elicitationResolved(runtimeID: id, requestID: requestID)
        case let .stopRuntime(id):
            try await stop(id)
            return .runtimeStopped(runtimeID: id)
        case .startRuntime:
            throw LatchAgentFailure(code: .invalidRequest, message: "A remote session cannot run a command on \(thisDevice).")
        case .listRuntimes:
            throw LatchAgentFailure(code: .invalidRequest, message: "A remote session lists only its own runtime.")
        }
    }

    public func prompt(runtimeID: AgentRuntimeID, turnID: UUID, blocks: [ACPPromptBlock]) async throws -> LatchAgentResponse {
        try await endOfTurn(runtimeID: runtimeID, turnID: turnID, sending: blocks).result.get()
    }

    public func awaitTurn(runtimeID: AgentRuntimeID, turnID: UUID) async throws -> LatchAgentResponse {
        try await endOfTurn(runtimeID: runtimeID, turnID: turnID, sending: nil).result.get()
    }

    /// Waits for the turn across reconnects; the channel sends the prompt again under the same
    /// turn ID if the first attempt's reply was lost, and the server runs it once. The end
    /// comes with where the channel's events had got to when the channel learned of it.
    public func endOfTurn(runtimeID: AgentRuntimeID, turnID: UUID, sending blocks: [ACPPromptBlock]?) async -> TurnEnd {
        let outcome: LatchRemoteTurnOutcome
        do {
            let (channel, server) = try current(runtimeID)
            outcome = try await awaitingTurn(on: channel, server: server) {
                guard let blocks else { return try await channel.awaitTurn(turnID) }
                return try await channel.prompt(turnID: turnID, blocks: blocks)
            }
        } catch {
            return TurnEnd(.failure(error))
        }
        return TurnEnd(Result { try Self.completion(of: outcome, runtimeID: runtimeID) }, journaledThrough: outcome.deliveredThrough)
    }

    /// Waits for a turn. A channel that fails for good under it, rather than being closed
    /// here, ends this client next, and the turn may well run on without it; the session is
    /// told so, and keeps the turn for a re-attach to follow instead of ending it.
    private func awaitingTurn(on channel: LatchRemoteRuntimeChannel, server: String,
                              _ body: () async throws -> LatchRemoteTurnOutcome) async throws -> LatchRemoteTurnOutcome {
        do {
            return try await mapFailures(server: server, body)
        } catch let error as RemoteServerFailure {
            if case let .failed(failure) = channel.linkState, failure != .closed {
                throw RemoteTurnInterrupted(message: error.message)
            }
            throw error
        }
    }

    private static func completion(of outcome: LatchRemoteTurnOutcome, runtimeID: AgentRuntimeID) throws -> LatchAgentResponse {
        // The runtime's exit event comes next and says whether it crashed or was stopped.
        if let error = outcome.error, error.code == .runtimeExited { throw RemoteAgentExited(message: error.message) }
        if let error = outcome.error { throw agentFailure(error) }
        return .promptCompleted(runtimeID: runtimeID, response: ACPPromptResponse(stopReason: outcome.stopReason ?? "end_turn"))
    }

    /// Stops following the runtime and leaves it running on the server. The server hears so
    /// if the link is up; if not, it notices the connection gone.
    public func detach(runtimeID id: AgentRuntimeID) async {
        let channel: LatchRemoteRuntimeChannel? = state.withLock { state in
            guard let runtime = state.runtime, runtime.id == id else { return nil }
            state.runtime = nil
            return runtime.channel
        }
        guard let channel else { return }
        await channel.detach()
        channel.close()
    }

    /// Releases the channel and finishes the streams. The runtime keeps running on the server.
    public func close() {
        let channel: LatchRemoteRuntimeChannel? = state.withLock { state in
            let channel = state.runtime?.channel
            state.finished = true
            state.runtime = nil
            return channel
        }
        channel?.close()
        continuation.finish()
        lifetime.finish()
    }

    /// Settings changed this client's server. A channel still reaching it is pointed at it the
    /// new way in place, so the cursor, a prompt waiting for the link and the turn being
    /// awaited all carry over, and the session sees at most a reconnect. With no such channel
    /// the session is told, since only it knows whether it kept a runtime it could not reach.
    /// A new name is used from the next message on.
    func serverChanged(to server: ServerProfile) {
        let (channel, previous, finished) = state.withLock { state in
            defer { state.server = server }
            return (state.runtime?.channel, state.server, state.finished)
        }
        guard !finished else { return }
        guard let channel else {
            if !server.connects(like: previous) { continuation.yield(.serverChanged) }
            return
        }
        let reached = state.withLock { $0.reached }
        guard !server.connects(like: reached) else { return }
        // A channel that has failed ends this client instead, and its session finds the new
        // settings through `serverSettingsChangedSinceLastChannel()`.
        guard channel.reconnect(using: server.connectionOptions) else { return }
        state.withLock { state in
            guard state.runtime?.channel === channel else { return }
            state.reached = server
            state.reconnections += 1
        }
    }

    /// Whether Settings now reaches the server differently from the last channel made here,
    /// as when a change landed while that channel was failing and this client ending.
    public func serverSettingsChangedSinceLastChannel() async -> Bool {
        guard let current = await readServer() else { return false }
        return !current.connects(like: state.withLock { $0.reached })
    }

    /// Checks the link now, as after the Mac wakes.
    public func probe() async {
        await state.withLock { $0.runtime?.channel }?.probe()
    }

    public func dropConnectionForTesting() {
        state.withLock { $0.runtime?.channel }?.dropConnectionForTesting()
    }

    /// The runtime this client follows, for tests.
    var followedRuntimeID: AgentRuntimeID? { state.withLock { $0.runtime?.id } }

    private func current(_ id: AgentRuntimeID) throws -> (LatchRemoteRuntimeChannel, String) {
        try state.withLock { state in
            guard let runtime = state.runtime, runtime.id == id else {
                throw LatchAgentFailure(code: .commandFailed, message: "Runtime not found.")
            }
            return (runtime.channel, state.server.name)
        }
    }

    private func send(_ command: LatchRemoteCommand, to id: AgentRuntimeID) async throws -> LatchRemoteResponse {
        let (channel, server) = try current(id)
        return try await mapFailures(server: server) { try await channel.send(command) }
    }

    /// Stops a runtime once, however many times it is asked: a disconnect and the launch it
    /// interrupted both stop the same one. The stop runs on its own, so a caller that is
    /// cancelled, such as a launch being drained, neither cuts it short nor closes the channel
    /// under it.
    private func stop(_ id: AgentRuntimeID) async throws {
        let stop: Task<Void, any Error> = state.withLock { state in
            if let stop = state.stops[id] { return stop }
            let followed = state.runtime.flatMap { $0.id == id ? $0.channel : nil }
            if followed != nil { state.runtime?.stopping = true }
            let known = state.attached.contains(id)
            let stop = Task { [server = state.server] in
                try await self.performStop(id, followed: followed, known: known, server: server)
            }
            state.stops[id] = stop
            return stop
        }
        try await stop.value
    }

    /// Sends the stop and closes the runtime's channel. A runtime this client no longer
    /// follows, such as one whose channel failed, gets a channel of its own for the one command.
    /// `known` when the server had the runtime before this client connected.
    private func performStop(_ id: AgentRuntimeID, followed: LatchRemoteRuntimeChannel?, known: Bool,
                             server: ServerProfile) async throws {
        defer {
            if let followed {
                state.withLock { state in
                    if state.runtime?.channel === followed { state.runtime = nil }
                }
                followed.close()
            }
        }
        var channel = followed
        if let followed {
            // A channel sends nothing before its first connection, and closing it ends its
            // attempts, so a runtime launched on a channel that never connected is unknown to
            // the server.
            if !followed.hasConnected, !known {
                followed.close()
                guard followed.hasConnected else { return }
            }
            if case .failed = followed.linkState { channel = nil }
        }
        let sender = channel ?? LatchRemoteRuntimeChannel(options: LatchRemoteRuntimeChannel.Options(
            connection: server.connectionOptions, runtimeID: id, backoff: backoff))
        defer { sender.close() }
        try await mapFailures(server: server.name) {
            try await Self.withTimeout(Self.stopTimeout, server: server.name) {
                _ = try await sender.send(.stopRuntime(runtimeID: id))
            }
        }
    }

    /// Stops following a runtime without stopping it. One launched on a channel that never
    /// connected, or whose agent has exited, needs no stop later either.
    private func release(_ id: AgentRuntimeID, _ channel: LatchRemoteRuntimeChannel, exited: Bool = false) {
        channel.close()
        let unheardOf = !channel.hasConnected
        state.withLock { state in
            if state.runtime?.channel === channel { state.runtime = nil }
            let settled = exited || (unheardOf && !state.attached.contains(id))
            if settled, state.stops[id] == nil { state.stops[id] = Task {} }
        }
    }

    // MARK: Events

    /// The server's name as Settings has it now, for what is said from here on.
    private var serverName: String { state.withLock { $0.server.name } }

    /// Forwards one channel's link changes for as long as it is this client's.
    private func relayLinks(_ channel: LatchRemoteRuntimeChannel) {
        Task { [weak self] in
            for await link in channel.linkStates {
                guard let self else { return }
                switch link {
                case .idle, .connecting, .connected:
                    yield(.link(.connected), from: channel)
                case let .reconnecting(since):
                    yield(.link(.reconnecting(server: serverName, since: since)), from: channel)
                case .failed:
                    // Told once the events have all been delivered, if it ends this client.
                    break
                }
            }
        }
    }

    /// Forwards one channel's events for as long as it is this client's. `attached` is the
    /// attach that came before them, whose record says which permissions are still pending.
    private func relayEvents(_ channel: LatchRemoteRuntimeChannel, runtimeID: AgentRuntimeID,
                             attached: LatchRemoteAttachment? = nil) {
        Task { [weak self] in
            var permissions = RemotePermissionLedger()
            if let attached, let self {
                for change in permissions.reattached(to: attached.record) {
                    yield(.agent(change.event(runtimeID: runtimeID), sequence: nil), from: channel)
                }
            }
            for await event in channel.events {
                guard let self else { return }
                let translated = translate(event, runtimeID: runtimeID, permissions: &permissions, from: channel)
                for event in translated {
                    yield(event, from: channel)
                }
                // An agent that exited on its own leaves nothing to follow, and nothing to stop.
                if translated.contains(where: \.isTermination) { release(runtimeID, channel, exited: true) }
            }
            self?.channelEnded(channel)
        }
    }

    private func translate(
        _ event: LatchRemoteChannelEvent,
        runtimeID id: AgentRuntimeID,
        permissions: inout RemotePermissionLedger,
        from channel: LatchRemoteRuntimeChannel
    ) -> [RemoteServiceEvent] {
        switch event {
        case let .reattached(attachment):
            return permissions.reattached(to: attachment.record).map { .agent($0.event(runtimeID: id), sequence: nil) }
        case .gap:
            return [.outputLost(runtimeID: id, sequence: nil)]
        case let .event(sequence, event):
            let skipped = RemoteServiceEvent.skipped(runtimeID: id, sequence: sequence)
            switch event {
            case let .sessionUpdate(notification, replay: true):
                return [.replayed(runtimeID: id, notification, sequence: sequence)]
            case let .sessionUpdate(notification, replay: false):
                return [.agent(.sessionUpdate(runtimeID: id, notification: notification), sequence: sequence)]
            case let .permissionRequested(requestID, request):
                guard permissions.raise(requestID, at: sequence) else { return [skipped] }
                return [.agent(.permissionRequested(runtimeID: id, requestID: requestID, request: request), sequence: sequence)]
            case let .permissionClosed(requestID):
                guard permissions.close(requestID) else { return [skipped] }
                return [.agent(.permissionClosed(runtimeID: id, requestID: requestID), sequence: sequence)]
            case let .elicitationRequested(requestID, request):
                guard permissions.ask(requestID, at: sequence) else { return [skipped] }
                return [.agent(.elicitationRequested(runtimeID: id, requestID: requestID, request: request), sequence: sequence)]
            case let .elicitationClosed(requestID):
                guard permissions.withdraw(requestID) else { return [skipped] }
                return [.agent(.elicitationClosed(runtimeID: id, requestID: requestID), sequence: sequence)]
            case let .turnStarted(turnID, text, attachments):
                return [.turnStarted(runtimeID: id, turnID: turnID, text: text,
                                     attachments: attachments.map(ChatAttachment.init), sequence: sequence)]
            case let .turnEnded(turnID, _, _):
                return [.turnEnded(runtimeID: id, turnID: turnID, sequence: sequence)]
            case let .configurationSet(configuration):
                return [.configurationSet(runtimeID: id, configuration, sequence: sequence)]
            case let .exited(exit):
                // A stop this client asked for is not news to the session that asked.
                let expected = state.withLock { $0.runtime?.channel === channel && $0.runtime?.stopping == true }
                guard !expected else { return [skipped] }
                if exit.stopped { return [.stopped(runtimeID: id, server: serverName, sequence: sequence)] }
                return [.agent(.processTerminated(runtimeID: id, status: exit.status ?? 0), sequence: sequence)]
            case .omitted:
                return [.outputLost(runtimeID: id, sequence: sequence)]
            case .unknown:
                return [skipped]
            }
        }
    }

    /// Only the current runtime's channel reaches the session: one replaced or stopped may
    /// still be draining.
    private func yield(_ event: RemoteServiceEvent, from channel: LatchRemoteRuntimeChannel) {
        let isCurrent = state.withLock { !$0.finished && $0.runtime?.channel === channel }
        if isCurrent { continuation.yield(event) }
    }

    /// A launched runtime whose channel failed for good cannot be reached again from here, so
    /// the client ends, the way a lost XPC service does. Unless the server no longer has the
    /// runtime, the session keeps it, to attach to again through a new client. A failure while
    /// launching is the launch's to report, and closing a channel on purpose is no failure at all.
    private func channelEnded(_ channel: LatchRemoteRuntimeChannel) {
        guard case let .failed(error) = channel.linkState else { return }
        let ends = state.withLock { state in
            guard !state.finished, let runtime = state.runtime, runtime.channel === channel, runtime.launched else { return false }
            state.finished = true
            state.runtime = nil
            return true
        }
        guard ends else { return }
        let runtimeGone = if case .runtimeNotFound = error { true } else { false }
        let server = serverName
        continuation.yield(.link(.failed(server: server, reason: Self.reason(for: error, server: server), runtimeGone: runtimeGone)))
        continuation.finish()
        lifetime.finish()
    }

    // MARK: Failures

    private static let unexpectedReply = LatchAgentFailure(code: .commandFailed, message: "The server sent an unexpected reply.")

    /// Server answers become the failures this Mac's service reports, so `SessionModel`'s
    /// handling, such as signing in again, works the same; link failures name the server.
    private func mapFailures<Value>(server: String, _ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch let error as LatchRemoteError where error.code == .workspaceNotFound {
            throw RemoteWorkspaceNotFound(message: error.message)
        } catch let error as LatchRemoteError {
            throw Self.agentFailure(error)
        } catch let error as LatchRemoteClientError {
            throw RemoteServerFailure(message: Self.reason(for: error, server: server))
        }
    }

    private static func agentFailure(_ error: LatchRemoteError) -> LatchAgentFailure {
        let code: LatchAgentFailureCode = switch error.code {
        case .authenticationRequired: .authenticationRequired
        case .invalidRequest: .invalidRequest
        default: .commandFailed
        }
        return LatchAgentFailure(code: code, message: error.message)
    }

    /// Why the server cannot be reached, in plain words and with what to do about it.
    static func reason(for error: LatchRemoteClientError, server: String) -> String {
        switch error {
        case .unauthorized:
            "\(server) refused the token. Update its token in \(serversPlace)."
        case let .destinationNotAllowed(address):
            "Latch did not send the token to \(server): \(address) is neither \(thisDevice) nor on a Tailscale network. "
                + "Turn on “Allow unencrypted network” for it in \(serversPlace) to connect anyway."
        case .protocolMismatch:
            "\(server) runs a latch-server this version of Latch can’t talk to. Update Latch or the server so they match."
        case .runtimeNotFound:
            "The agent is no longer running on \(server); the server may have restarted."
        case .invalidEndpoint:
            "The port set for \(server) is not valid. Fix it in \(serversPlace)."
        case .timedOut:
            "\(server) did not answer in time."
        default:
            "Lost the connection to \(server). \(error.localizedDescription)"
        }
    }

    private static func withTimeout(_ limit: Duration, server: String,
                                    _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await body()
                return true
            }
            group.addTask {
                try await Task.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            guard try await group.next() == true else { throw LatchRemoteClientError.timedOut }
        }
    }
}

private extension RemoteServiceEvent {
    var isTermination: Bool {
        switch self {
        case .agent(.processTerminated, _), .stopped: true
        default: false
        }
    }
}

private extension ChatAttachment {
    /// What a turn started elsewhere sent: a name and a kind, never the bytes.
    init(_ summary: LatchRemoteAttachmentSummary) {
        let isImage = summary.kind == "image"
        self.init(kind: isImage ? .image : .file, name: summary.name ?? (isImage ? "Image" : "File"), path: nil)
    }
}

/// A server that cannot be reached, as a session reports it.
struct RemoteServerFailure: RemoteConnectionFailure, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A session's folder that is not on its server. The folder is fixed when a session is made,
/// so no retry finds it.
struct RemoteWorkspaceNotFound: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A turn whose channel failed for good while it was awaited. Not the turn's end: the client
/// ends next and says why, and the turn is followed again if the session re-attaches.
struct RemoteTurnInterrupted: RemoteConnectionFailure, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A turn that ended because its agent's runtime did. Not how the session learns of the exit:
/// the runtime's `exited` event follows it, and says whether the agent crashed or was stopped.
struct RemoteAgentExited: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Which permission requests the session has been shown and not yet seen closed, so a
/// re-attach neither raises one twice nor leaves a closed one on screen.
struct RemotePermissionLedger {
    enum Change {
        case raised(UUID, ACPPermissionRequest)
        case closed(UUID)
        /// The same for the agent's questions.
        case asked(UUID, ACPElicitationRequest)
        case withdrawn(UUID)

        func event(runtimeID: AgentRuntimeID) -> LatchAgentEvent {
            switch self {
            case let .raised(requestID, request): .permissionRequested(runtimeID: runtimeID, requestID: requestID, request: request)
            case let .closed(requestID): .permissionClosed(runtimeID: runtimeID, requestID: requestID)
            case let .asked(requestID, request): .elicitationRequested(runtimeID: runtimeID, requestID: requestID, request: request)
            case let .withdrawn(requestID): .elicitationClosed(runtimeID: runtimeID, requestID: requestID)
            }
        }
    }

    private var open: Set<UUID> = []
    /// The last re-attach's record: what was pending as of its last sequence.
    private var pendingAtRecord: Set<UUID> = []
    private var openQuestions: Set<UUID> = []
    private var questionsAtRecord: Set<UUID> = []
    private var recordThrough: UInt64 = 0

    /// Brings the session in line with the record before the backlog arrives: requests it
    /// shows that the server has closed are closed, and pending ones it never saw, perhaps
    /// because their events were evicted, are raised.
    mutating func reattached(to record: LatchRemoteRuntimeRecord) -> [Change] {
        let pending = record.pendingPermissions
        pendingAtRecord = Set(pending.map(\.requestID))
        recordThrough = record.lastSequence
        var changes: [Change] = open.subtracting(pendingAtRecord).sorted { $0.uuidString < $1.uuidString }.map { .closed($0) }
        open.formIntersection(pendingAtRecord)
        for permission in pending where !open.contains(permission.requestID) {
            open.insert(permission.requestID)
            changes.append(.raised(permission.requestID, permission.request))
        }
        let questions = record.pendingElicitations ?? []
        questionsAtRecord = Set(questions.map(\.requestID))
        changes += openQuestions.subtracting(questionsAtRecord).sorted { $0.uuidString < $1.uuidString }.map { .withdrawn($0) }
        openQuestions.formIntersection(questionsAtRecord)
        for question in questions where !openQuestions.contains(question.requestID) {
            openQuestions.insert(question.requestID)
            changes.append(.asked(question.requestID, question.request))
        }
        return changes
    }

    /// Whether to show a request. Not one already shown, nor one from the backlog that the
    /// record no longer had pending: its close is in the same backlog.
    mutating func raise(_ requestID: UUID, at sequence: UInt64) -> Bool {
        guard !open.contains(requestID), sequence > recordThrough || pendingAtRecord.contains(requestID) else { return false }
        open.insert(requestID)
        return true
    }

    /// Whether to close a request: only one that is showing.
    mutating func close(_ requestID: UUID) -> Bool {
        open.remove(requestID) != nil
    }

    /// Whether to show a question, as `raise` decides for a request.
    mutating func ask(_ requestID: UUID, at sequence: UInt64) -> Bool {
        guard !openQuestions.contains(requestID), sequence > recordThrough || questionsAtRecord.contains(requestID) else { return false }
        openQuestions.insert(requestID)
        return true
    }

    /// Whether to take a question down: only one that is showing.
    mutating func withdraw(_ requestID: UUID) -> Bool {
        openQuestions.remove(requestID) != nil
    }
}
