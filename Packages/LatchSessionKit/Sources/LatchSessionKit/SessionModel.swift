import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol

/// One session's conversation with its agent, whatever shows it. What owns a model keeps to
/// an order the model does not enforce:
/// - `connect` and `adopt` do nothing unless `phase` is `.disconnected`, so each waits for the
///   `detach()` or `disconnect()` before it to return, or it is dropped.
/// - A snapshot saves `messages`, `savedAgentSessionID` and `remoteBinding` together, and none
///   of them while a new context is pending: that context replaces all three.
/// - Quitting detaches a remote session, so its runtime runs on; closing one disconnects, then
///   calls `discardRemoteBinding()` once that has returned, so a runtime never attached to
///   again is stopped rather than left running.
@MainActor
public final class SessionModel {
    public enum Phase: Sendable { case disconnected, connecting, ready, prompting, stopping }
    public private(set) var phase: Phase = .disconnected
    public private(set) var status = "Not connected"
    // Read a snapshot on demand rather than retaining a second array/String copy
    // that forces history's next streaming append to copy its growing response.
    public var messages: [ChatMessage] { history.messages }
    public var transcript: String { history.transcript }
    private var history = ChatHistory()
    /// What went wrong, in the words it arrived in. Setting it clears `errorAdvice`, so
    /// advice never outlives the failure it was written for.
    public private(set) var errorMessage: String? {
        didSet {
            errorAdvice = nil
            errorIsConnectionFailure = false
            stoppedOnServer = false
        }
    }
    /// What to do about `errorMessage`, in Latch's words; kept apart so the banner can set
    /// the agent's text off from the advice instead of running them into one sentence.
    public private(set) var errorAdvice: String?
    /// `errorMessage` is about reaching a server, not about the agent on it.
    public private(set) var errorIsConnectionFailure = false
    /// `errorMessage` says the agent was stopped on its server by something other than this
    /// session, which is neither a crash nor a failure to start.
    public private(set) var stoppedOnServer = false
    public static let idleSavedStatus = "Saved · Not connected"
    /// The name the agent gave itself when it last started or was attached to, such as
    /// "Claude Code"; kept once it stops, for a custom command whose own name says little.
    public private(set) var agentName: String?
    /// Turns that have come to an end while this session followed them, so each end is
    /// announced once. A turn whose link failed under it has not ended: it runs on, and a
    /// re-attach follows it again.
    public private(set) var turnsEnded = 0
    /// The last turn to end did so because its agent was stopped on the server.
    public private(set) var lastTurnEndedByStop = false
    /// Every launch or attach counts one, so a failure that repeats an earlier one word for
    /// word is still a new failure to report.
    public private(set) var connectionAttempts = 0
    public private(set) var cancellationRequested = false
    public private(set) var configuration = SessionConfiguration()
    public private(set) var isChangingConfiguration = false
    /// State changes (including permissions) are delivered immediately.
    public var onChange: (() -> Void)?
    /// History is already current; consumers may coalesce its rendering only.
    public var onTranscriptChange: (() -> Void)?
    public var serviceTransportDescription: String { client.transportDescription }
    /// Whether a remote session's server can be reached. Always `.connected` on this Mac. A
    /// lost link changes nothing else: the runtime, the turn in flight and any permission
    /// sheet all wait for it to come back.
    public private(set) var linkState = SessionLinkState.connected

    public let permissions = PermissionQueue()
    private var sessionID: String?
    /// Agent-owned context identity survives runtime teardown. Local runtime IDs are never
    /// persisted; remote ones are, in `remoteBinding`, because the server outlives the app.
    public private(set) var savedAgentSessionID: String?
    /// History restored without the agent's session ID. It can be read, never continued: there is
    /// no context to resume, and prompting a fresh agent under an old transcript would misrepresent it.
    public private(set) var archivedWithoutContext = false
    private var loadedThroughSequence: UInt64?

    public func restore(messages: [ChatMessage], agentSessionID: String?, lastActiveAt: Date? = nil,
                        remote: SavedSession.RemoteBinding? = nil) {
        guard phase == .disconnected else { return }
        self.lastActiveAt = lastActiveAt
        history.restore(messages)
        savedAgentSessionID = agentSessionID
        savedBinding = remote
        bindingKeptFromLink = false
        archivedWithoutContext = agentSessionID == nil && !messages.isEmpty
        status = Self.idleSavedStatus
        onChange?()
    }
    private var client: AgentServiceClient
    private let makeClient: @MainActor () -> AgentServiceClient
    private var eventTask: Task<Void, Never>?
    /// Brokered permission decisions in flight, keyed by the service's request ID.
    private var permissionTasks: [UUID: Task<Void, Never>] = [:]
    private var runtimeID: AgentRuntimeID?
    /// The turn `send` is waiting for, or one an attach found running, under the ID a server
    /// knows it by.
    public private(set) var turnID: UUID?
    /// The last journal sequence of this runtime that has been taken in. Zero on this Mac.
    public private(set) var appliedSequence: UInt64 = 0
    /// The connection sequence of the last session update taken in from this Mac's service,
    /// which a local turn's reply names as where its updates end. Zero on a server.
    private var updatesTakenThrough: UInt64 = 0
    /// A remote runtime this session is not following yet, or no longer: restored with the
    /// session, or kept when Latch quit. The next remote connection attaches to it rather than
    /// launching another.
    private var savedBinding: SavedSession.RemoteBinding?
    /// `savedBinding` was kept when the link to a live runtime failed, rather than restored
    /// with the session: attaching to it again is reconnecting, not resuming after a relaunch.
    private var bindingKeptFromLink = false
    /// The prompt of a turn whose link failed before the server accepted it. A re-attach
    /// whose record does not know the turn sends it again under the same turn ID; this Mac
    /// still has it, unlike after a relaunch.
    private var interruptedPrompt: (turn: UUID, blocks: [ACPPromptBlock])?
    /// The runtime was launched on, or attached to, a server, which keeps it when Latch quits.
    private var runtimeIsRemote = false
    /// The last journal sequence an attach's backlog could hold. A turn that started at or
    /// before it has been followed or finished already; one after it started while this
    /// session looked on.
    private var backlogThrough: UInt64 = 0
    /// The binding an attach in flight is for, until its record arrives.
    private var attaching: (id: AgentRuntimeID, binding: SavedSession.RemoteBinding)?
    /// What the last remote connection asked for, so a change to the server's settings can
    /// attach again without being asked. An adopted runtime's comes from its record.
    private var remoteTarget: (agent: LatchRemoteAgent, path: String)?
    /// The attach in flight takes up a runtime this session never had; see `adopt(runtimeID:)`.
    private var adopting = false
    /// The attach waiting for its record to be taken in, so it returns with the session ready.
    private var attachWaiter: CheckedContinuation<Void, Never>?
    /// A turn whose outcome came before the events it names were all taken in; see
    /// `finishTurn`. The step that takes in the last of them ends it.
    private var endingTurn: (turn: UUID, result: Result<LatchAgentResponse, any Error>, through: UInt64,
                             resume: CheckedContinuation<Void, Never>)?
    /// For tests: a turn's outcome is in and its last events are not.
    var turnEndIsWaiting: Bool { endingTurn != nil }
    /// Where the transcript stood when the running turn began; see `remoteBinding`.
    private var turnBoundary: SavedSession.RemoteBinding?
    /// Turns whose prompts the transcript already shows, so their `turnStarted` is not shown
    /// again: sent from here, or the turn a saved binding was running.
    private var knownTurns: [UUID] = []
    /// Another client's turn that started while this session was sending its own, and has not
    /// ended. The server runs one turn at a time, so it refuses this session's prompt as busy,
    /// or runs it first; either way, once this session's turn is over it follows that one,
    /// from the boundary at its prompt, rather than offer a prompt the server would refuse.
    private var foreignTurn: (turn: UUID, boundary: SavedSession.RemoteBinding)?
    /// An attach found the runtime exited. Its exit is shown once its last output is in;
    /// `stoppedOn` names the server when the agent was stopped there rather than exiting.
    private var pendingExit: (through: UInt64, status: Int32, stoppedOn: String?)?
    /// The turn a saved binding was sending that the server's record does not know. Unless
    /// the backlog up to `through` shows it starting, the prompt never left this Mac.
    /// `atQuit` when the binding was saved at quit, rather than kept when the link failed.
    private var unsentTurn: (turn: UUID, through: UInt64, atQuit: Bool)?
    /// What an attach took out of the transcript for the journal to replay, until the replay
    /// has passed `through`. Put back if the journal turns out to have lost part of it: output
    /// evicted after the attach answered, which a truncated attach would have said up front.
    private var replaced: (boundary: UUID?, messages: [ChatMessage], through: UInt64)?
    /// After `replaced` was put back: the next event says whether anything after `through`,
    /// which the transcript never had, was lost as well.
    private var lostPast: UInt64?
    /// The transcript is what this runtime's journal replayed from its start, so it shows the
    /// history an agent replayed when another client loaded its session. Otherwise that
    /// history is already in the transcript, which is where the session loaded it from.
    private var showsReplayedHistory = false
    /// Output was lost just before the next event, and this notice says so. Unless the
    /// transcript shows replayed history, a loss that the next event shows to be only such
    /// history is not news.
    private var lostBeforeNext: String?
    /// Since the last replayed chunk of a message, an update that ends a user message, such as
    /// a thought: the user's next chunk begins a message of its own. See `showReplayed`.
    private var replayEndedMessage = false
    private var replayedMessageID: String?
    /// The runtime an adoption attached to has no session yet: it is still creating or loading
    /// one. `adopt` attaches again shortly.
    private var adoptionFoundNoSession = false
    public static let outputLostWhileClosed = "Some output from while Latch was closed could not be recovered."
    public static let outputLostWhileUnreachable = "Some output from while the server was out of reach could not be recovered."
    public static let promptNotSent = "This message was not sent before Latch quit."
    public static let promptNotSentOverLink = "This message was not sent: the server could not be reached."
    public static let outputLostNotice = "Some output could not be shown."

    /// What a relaunch needs to attach to this session's runtime again, saved in the same
    /// snapshot as `messages`. While a turn runs, the transcript is cut back to its prompt and
    /// the turn replayed from the journal, because a restored transcript never merges later
    /// output into an earlier message; otherwise it continues from the last sequence applied.
    public var remoteBinding: SavedSession.RemoteBinding? {
        if let savedBinding { return savedBinding }
        guard runtimeIsRemote, let runtimeID, phase == .ready || phase == .prompting else { return nil }
        if phase == .prompting, var turnBoundary {
            turnBoundary.applied = max(appliedSequence, turnBoundary.cursor)
            turnBoundary.showsReplayedHistory = showsReplayedHistory ? true : nil
            return turnBoundary
        }
        return SavedSession.RemoteBinding(runtimeID: runtimeID.rawValue, cursor: appliedSequence,
                                          boundaryMessageID: history.messages.last?.id,
                                          showsReplayedHistory: showsReplayedHistory ? true : nil)
    }
    private var generation = UUID() {
        // Whatever moved the session on lets go of a turn's end still waiting for its events.
        didSet { releaseEndingTurn() }
    }
    private var promptGeneration = UUID()
    private var authenticationStop: (token: UUID, task: Task<Void, Never>)?
    private var configurationSequence: UInt64 = 0
    private var legacyModelSequence: UInt64 = 0
    private var legacyModeSequence: UInt64 = 0
    private var pendingStateUpdates: [ACPSessionNotification] = []
    /// The agent's slash commands, replaced whole by each update. Empty until it sends some.
    public private(set) var commands: [ACPAvailableCommand] = []
    /// Unlike the configuration's, this starts from zero rather than the session reply's
    /// position: the reply carries no commands, so a list sent just before it is still the newest.
    private var commandsSequence: UInt64 = 0
    /// From the agent's prompt capabilities at connection; without it, images go as file links.
    public private(set) var acceptsImages = false
    /// The agent runs on a server, where a link to a file on this Mac means nothing: only an
    /// image, and only to an agent that takes images, can go with a prompt. Implied by a
    /// remote channel; set it for a session on a server whose channel could not be made.
    public var sendsAttachmentsRemotely = false

    /// Whether the agent cannot receive this attachment. An image is judged by the agent's
    /// capabilities, so it is refused only once they are known.
    public func refusesRemotely(_ attachment: PromptAttachment) -> Bool {
        guard sendsAttachmentsRemotely || client.isRemote else { return false }
        guard attachment.isImage else { return true }
        return (phase == .ready || phase == .prompting) && !acceptsImages
    }
    /// When the conversation last moved: a prompt sent, or a turn that finished.
    public private(set) var lastActiveAt: Date?
    /// When the turn now running began. Only meaningful while `phase` is `.prompting`.
    public private(set) var promptStartedAt: Date?
    /// The clock for both; tests substitute their own.
    public var now: () -> Date = Date.init

    /// `makeClient` opens the session's channel to its service, now and whenever the last one ends.
    public init(makeClient: @escaping @MainActor () -> AgentServiceClient) {
        self.makeClient = makeClient
        client = makeClient()
        permissions.onChange = { [weak self] in self?.onChange?() }
        startEventTask()
    }

    deinit {
        eventTask?.cancel()
        permissionTasks.values.forEach { $0.cancel() }
        client.close()
    }

    private func startEventTask() {
        eventTask?.cancel()
        if let remoteEvents = client.remoteEvents {
            eventTask = Task { [weak self] in
                for await event in remoteEvents {
                    guard !Task.isCancelled else { return }
                    self?.receive(event)
                }
                guard !Task.isCancelled else { return }
                self?.serviceConnectionLost()
            }
            return
        }
        eventTask = Task { [weak self, events = client.events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
            guard !Task.isCancelled else { return }
            self?.serviceConnectionLost()
        }
    }

    /// The service channel ended (XPC interruption or invalidation). Any runtime it owned is
    /// unreachable now; present that like an agent exit and open a fresh channel for next time.
    private func serviceConnectionLost() {
        let ended = client
        client.close()
        client = makeClient()
        startEventTask()
        guard phase != .disconnected else { return }
        // A server that turned the session away for good said why, naming itself. One that
        // answered but has lost the agent is reachable: the agent stopped, not the link. When
        // only the link failed, the agent is most likely still running, so the session keeps
        // its binding: Retry, or fixing the server in Settings, attaches to it again from where
        // it had got to, the turn in flight included, rather than starting another agent.
        if case let .failed(_, reason, runtimeGone) = linkState {
            let binding = runtimeGone ? nil : remoteBinding
            if runtimeGone, phase == .prompting {
                // What the turn said after the link failed went with the runtime.
                history.appendNotice(Self.outputLostWhileUnreachable)
                publishHistory()
            }
            // A runtime gone from its server, as after a restart, stopped there: a turn it was
            // running did not finish, and is never announced as if it had.
            resetAfterLoss(status: runtimeGone ? "Agent stopped" : "Not connected", error: reason,
                           advice: runtimeGone ? "Retry to start it again." : nil, connectionFailure: !runtimeGone,
                           turnStopped: runtimeGone)
            guard let binding else { return }
            savedBinding = binding
            bindingKeptFromLink = true
            // A fix saved in Settings while the link was failing reached no channel of this
            // session's; it is taken up now.
            let token = generation
            Task { [weak self] in
                guard await ended.serverSettingsChangedSinceLastChannel(), let self, generation == token else { return }
                followAgainAfterServerChange()
            }
            return
        }
        resetAfterLoss(status: "Agent service disconnected",
                       error: "Lost the connection to the Latch agent service. Select the agent again to reconnect.")
    }

    /// `turnStopped` says a running turn was stopped rather than ended, when the server did
    /// not say so itself; `stoppedOnServer` implies it.
    private func resetAfterLoss(status: String, error: String, advice: String? = nil, connectionFailure: Bool = false,
                                stoppedOnServer: Bool = false, turnStopped: Bool = false) {
        // The agent ending ends its turn; a failed link does not, since the turn runs on.
        if phase == .prompting, !connectionFailure { noteTurnEnded(stopped: stoppedOnServer || turnStopped) }
        generation = UUID()
        runtimeID = nil
        forgetRemoteRuntime()
        sessionID = nil
        clearConfiguration()
        cancellationRequested = false
        permissions.cancelAll()
        permissionTasks.values.forEach { $0.cancel() }
        permissionTasks.removeAll()
        phase = .disconnected
        self.status = status
        errorMessage = error
        errorAdvice = advice
        errorIsConnectionFailure = connectionFailure
        self.stoppedOnServer = stoppedOnServer
        onChange?()
    }

    /// Stopped on the server by something other than this session: another client or the server
    /// shutting down. (The idle reaper only takes runtimes nobody is attached to, and forgets
    /// them, so a session finds those gone rather than stopped.) Retry starts the agent again and resumes its session.
    private func resetAfterStop(on server: String) {
        // Whatever the link was doing, there is nothing left on it to wait for.
        linkState = .connected
        resetAfterLoss(status: "Stopped on \(server)", error: "The agent was stopped on \(server).",
                       advice: "Retry to start it again.", stoppedOnServer: true)
    }

    #if os(macOS)
    public func connect(command: String, workspace: URL?, launchEnvironment: AgentLaunchEnvironment = AgentLaunchEnvironment(), startNewSession: Bool = false) async {
        guard beginConnecting(startNewSession: startNewSession) else { return }
        let parsed: ResolvedAgentCommand
        do {
            parsed = try launchEnvironment.resolve(AgentCommand(command))
            var isDirectory: ObjCBool = false
            guard let workspace, workspace.isFileURL,
                  FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw CommandError.workspaceRequired }
        } catch {
            errorMessage = error.localizedDescription
            onChange?()
            return
        }
        guard let workspace else { return }
        await launch(.local(ACPCommandProfile(
            executablePath: parsed.executable, arguments: parsed.arguments,
            workingDirectoryPath: workspace.path, environment: parsed.environment
        )), cwd: workspace.path, startNewSession: startNewSession)
    }
    #endif

    /// A session on a server. The server resolves the agent and checks the folder, so
    /// nothing is looked up on this Mac; the client launches it, and everything after the
    /// launch is the local path's.
    public func connect(remote agent: LatchRemoteAgent, path: String, startNewSession: Bool = false) async {
        guard beginConnecting(startNewSession: startNewSession) else { return }
        remoteTarget = (agent, path)
        if let binding = savedBinding {
            guard startNewSession else { return await reattach(binding, resuming: (agent, path)) }
            // A new context replaces the one that runtime holds, so nothing will attach to it again.
            await discardRemoteBinding()
        }
        await launch(.remote(agent: agent, path: path), cwd: path, startNewSession: startNewSession)
    }

    /// What the last remote connection asked for, or what an adopted runtime's record said it
    /// runs: the agent to save with the session, and to launch again should the runtime go.
    public var remoteAgent: LatchRemoteAgent? { remoteTarget?.agent }
    /// The folder on the server that `remoteAgent` works in.
    public var remoteWorkspace: String? { remoteTarget?.path }

    /// Takes up a runtime on the server that this session did not start, such as one launched
    /// from another device, and follows it from the start of its journal, so all of it that the
    /// server still has replays. Its record says which agent it is, in `remoteAgent`. A runtime
    /// gone by then is reported, never replaced by a new one: nothing here knows what to start.
    /// For a session with no transcript and no binding of its own.
    ///
    /// A runtime still creating or loading its session, whose record cannot yet say which
    /// session it is or how it is set up, is attached to again until it has one, for up to
    /// about a minute.
    public func adopt(runtimeID id: AgentRuntimeID) async {
        guard messages.isEmpty, savedAgentSessionID == nil, savedBinding == nil,
              beginConnecting(startNewSession: false) else { return }
        remoteTarget = nil
        var delay = Duration.milliseconds(250)
        for _ in 0..<Self.adoptionAttempts {
            adopting = true
            adoptionFoundNoSession = false
            await reattach(SavedSession.RemoteBinding(runtimeID: id.rawValue, cursor: 0), resuming: nil)
            guard adoptionFoundNoSession else { return }
            adoptionFoundNoSession = false
            let token = generation
            await client.detach(runtimeID: id)
            try? await Task.sleep(for: delay)
            // A detach or disconnect meanwhile gave the adoption up.
            guard generation == token, phase == .connecting else { return }
            delay = min(delay * 2, .seconds(2))
        }
        phase = .disconnected
        status = "Not connected"
        errorMessage = "The agent on the server has not started its session."
        errorAdvice = "Try again once it has."
        onChange?()
    }

    static let adoptionAttempts = 32

    /// Attaches to the runtime the last run of Latch left on the server rather than launching
    /// another. The record arrives ahead of the backlog, in `receive(.attached)`, which
    /// rebuilds the session from it. A server that no longer has the runtime gets the resume
    /// path, as after any lost runtime, when the user asked to connect and `resuming` says what
    /// to launch; an attach that a change in Settings started launches nothing unasked, on what
    /// may now be another machine, and nor does an adoption.
    private func reattach(_ binding: SavedSession.RemoteBinding,
                          resuming target: (agent: LatchRemoteAgent, path: String)?) async {
        let token = UUID()
        generation = token
        connectionAttempts += 1
        let id = AgentRuntimeID(binding.runtimeID)
        let reconnecting = bindingKeptFromLink || adopting
        attaching = (id, binding)
        runtimeID = nil
        sessionID = nil
        linkState = .connected
        clearConfiguration()
        phase = .connecting
        status = reconnecting ? "Connecting…" : "Resuming…"
        onChange?()
        do {
            _ = try await client.attach(runtimeID: id, after: binding.cursor)
            // The record comes with the events, which may not have been read yet.
            if generation == token, attaching != nil {
                await withCheckedContinuation { attachWaiter = $0 }
            }
        } catch let gone as RemoteRuntimeGone {
            guard generation == token else { return }
            let adopted = adopting
            attaching = nil
            adopting = false
            savedBinding = nil
            bindingKeptFromLink = false
            // Whatever the turn running at quit, or when the link failed, went on to say went
            // with the runtime.
            if binding.boundaryTurnID != nil {
                history.appendNotice(reconnecting ? Self.outputLostWhileUnreachable : Self.outputLostWhileClosed)
                publishHistory()
            }
            guard let target else {
                let reason = gone.localizedDescription
                linkState = .failed(server: gone.server, reason: reason, runtimeGone: true)
                return resetAfterLoss(status: "Agent stopped", error: reason,
                                      advice: adopted ? nil : "Retry to start it again.")
            }
            phase = .disconnected
            await launch(.remote(agent: target.agent, path: target.path), cwd: target.path, startNewSession: false)
        } catch {
            guard generation == token else { return }
            // The runtime may well still be there: keep the binding, so Retry attaches again.
            // Reconnecting after a failed link fails as that link did; only a relaunch's
            // resume has saved history to reassure about. An adoption saved no binding: adopting
            // again starts it over.
            attaching = nil
            adopting = false
            phase = .disconnected
            status = reconnecting ? "Not connected" : "Saved · Resume failed"
            errorMessage = error.localizedDescription
            errorIsConnectionFailure = error is RemoteConnectionFailure
            if !reconnecting { errorAdvice = "Your saved history is unchanged. Retry, or start a new session." }
            onChange?()
            // Settings may have been fixed while this attach was failing the old way.
            guard errorIsConnectionFailure, await client.serverSettingsChangedSinceLastChannel(),
                  generation == token else { return }
            followAgainAfterServerChange()
        }
    }

    /// Takes in the record of a runtime attached to again: the session as the server has it
    /// now. Everything after the binding's boundary is about to arrive again in the backlog,
    /// so it is dropped first, unless the journal no longer reaches back that far. When it does
    /// not, the saved transcript stays whole, what it already shows is skipped as it arrives
    /// again, and only output evicted from after it is reported lost.
    private func rebuild(from attachment: LatchRemoteAttachment, binding: SavedSession.RemoteBinding, id: AgentRuntimeID,
                         server: String) {
        let record = attachment.record
        attaching = nil
        defer { resumeAttachWaiter() }
        let adopted = adopting
        adopting = false
        if adopted, record.session == nil, record.lifecycle != .exited {
            adoptionFoundNoSession = true
            return
        }
        // An adopted runtime's transcript starts empty, and all of it comes from the journal.
        showsReplayedHistory = adopted || binding.showsReplayedHistory == true
        replayEndedMessage = false
        replayedMessageID = nil
        if remoteTarget == nil { remoteTarget = (record.agent, record.workspace) }
        let afterLinkFailure = bindingKeptFromLink
        let interrupted = interruptedPrompt
        savedBinding = nil
        bindingKeptFromLink = false
        interruptedPrompt = nil
        runtimeIsRemote = true
        backlogThrough = record.lastSequence
        foreignTurn = nil
        runtimeID = id
        if let bound = record.sessionID { savedAgentSessionID = bound }
        sessionID = record.sessionID ?? savedAgentSessionID
        loadedThroughSequence = record.loadedThrough
        if attachment.truncated {
            appliedSequence = min(binding.applied, record.lastSequence)
            // Subtracted rather than added: a saved sequence came from the server, which could
            // have sent the largest there is.
            if attachment.backlogFrom > 0, attachment.backlogFrom - 1 > binding.applied {
                let notice = adopted ? Self.outputLostNotice : Self.outputLostWhileClosed
                // A transcript of its own already has the history another client's load
                // replayed: the first event left says whether only that was lost. With none
                // left, nothing will say.
                if showsReplayedHistory || attachment.backlogFrom > record.lastSequence {
                    history.appendNotice(notice)
                } else {
                    lostBeforeNext = notice
                }
            }
        } else {
            appliedSequence = min(binding.cursor, record.lastSequence)
            let saved = history.messages
            history.removeMessages(after: binding.boundaryMessageID)
            let cut = binding.boundaryMessageID.map { id in saved.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0 } ?? 0
            let through = min(binding.applied, record.lastSequence)
            if through > appliedSequence, cut < saved.count {
                replaced = (binding.boundaryMessageID, Array(saved[cut...]), through)
            }
        }
        publishHistory()
        if let turn = binding.boundaryTurnID { remember(turn) }
        clearConfiguration()
        let sequence: UInt64?
        switch record.session {
        case let .new(response):
            configuration = SessionConfiguration(configOptions: response.configOptions, models: response.models, modes: response.modes)
            sequence = response.localSequence
        case let .load(response):
            configuration = SessionConfiguration(configOptions: response.configOptions, models: response.models, modes: response.modes)
            sequence = response.localSequence
        case .unknown, nil:
            sequence = nil
        }
        configurationSequence = sequence ?? 0
        legacyModelSequence = sequence ?? 0
        legacyModeSequence = sequence ?? 0
        applyState(of: record)
        acceptsImages = record.initialization?.agentCapabilities.acceptsImages ?? false
        let title = record.initialization?.agentInfo?.title ?? record.initialization?.agentInfo?.name ?? record.agentTitle
        agentName = title
        status = "Connected · \(title)"
        phase = .ready
        if record.lifecycle == .exited {
            pendingExit = (record.lastSequence, record.exit?.status ?? 0, record.exit?.stopped == true ? server : nil)
        } else if let turn = record.activeTurnID {
            followTurn(turn, runtimeID: id, boundary: binding.boundaryTurnID == turn ? binding : nil)
        } else if let turn = binding.boundaryTurnID {
            if record.turns.contains(where: { $0.turnID == turn && $0.state == .ended }) {
                // It ended while Latch was closed. Followed to its end as the backlog replays
                // it, it finishes here like any turn, so it is announced like one.
                followTurn(turn, runtimeID: id, boundary: binding)
            } else if !record.turns.contains(where: { $0.turnID == turn }) {
                if let interrupted, interrupted.turn == turn {
                    // The server never had it, so this is its first delivery, not a retry; the
                    // turn ID would keep a second one from running twice all the same.
                    followTurn(turn, runtimeID: id, boundary: binding, sending: interrupted.blocks)
                } else {
                    unsentTurn = (turn, record.lastSequence, !afterLinkFailure)
                }
            }
        }
        onChange?()
        caughtUp()
    }

    /// The record's latest state notifications and set-* results, in the order the agent
    /// produced them, through the same sequence guards as live ones. Those without a position
    /// go first, so none of them replaces a change whose position is known.
    private func applyState(of record: LatchRemoteRuntimeRecord) {
        enum Change {
            case notification(ACPSessionNotification)
            case set(LatchRemoteConfigurationSet)
        }
        let changes: [(sequence: UInt64?, change: Change)] =
            record.state.filter { $0.sessionId == sessionID }.map { ($0.localSequence, .notification($0)) }
            + record.configurationSets.map { ($0.acpSequence, .set($0)) }
        let ordered = changes.enumerated().sorted {
            ($0.element.sequence ?? 0, $0.offset) < ($1.element.sequence ?? 0, $1.offset)
        }
        for (_, entry) in ordered {
            switch entry.change {
            case let .notification(notification): applyStateUpdate(notification)
            case let .set(change): apply(change)
            }
        }
    }

    /// A turn the record shows running, from before Latch quit or from another client. No
    /// `send` waits for it, so this does, and ends it the way `send` ends its own. `boundary`
    /// is the saved binding when it is that binding's turn, whose prompt is already shown.
    /// With `sending`, the turn is this session's own whose prompt never reached the server,
    /// and this sends it.
    private func followTurn(_ turn: UUID, runtimeID id: AgentRuntimeID, boundary: SavedSession.RemoteBinding?,
                            sending blocks: [ACPPromptBlock]? = nil) {
        let token = generation
        phase = .prompting
        status = "Working…"
        promptStartedAt = now()
        promptGeneration = UUID()
        let prompting = promptGeneration
        cancellationRequested = false
        turnID = turn
        turnBoundary = boundary
        let client = client
        Task { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Agent prompt in flight")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let end = await client.endOfTurn(runtimeID: id, turnID: turn, sending: blocks)
            if let blocks { self?.keepIfInterrupted(turn, blocks: blocks, end.result, prompting: prompting) }
            await self?.finishTurn(turn, end, generation: token)
        }
    }

    /// Settings changed how this session's server is reached. A session holding a runtime it
    /// could not reach attaches to it again with the new settings, from where it had got to,
    /// and follows a turn still running there to its end. One that follows a runtime needs
    /// nothing from here: its client points the channel at the server the new way in place.
    private func followAgainAfterServerChange() {
        guard remoteTarget != nil, authenticationStop == nil, phase == .disconnected,
              errorIsConnectionFailure, let binding = savedBinding else { return }
        // Connecting from now, so a second notice of the same change starts nothing more.
        phase = .connecting
        errorMessage = nil
        Task { [weak self] in await self?.reattach(binding, resuming: nil) }
    }

    /// Quitting Latch: lets go of a remote session's runtime and leaves it running on the
    /// server, with its binding kept for the next launch to attach to. Decision tasks are
    /// cancelled before the queue, so taking a sheet down refuses nothing on the server.
    public func detach() async {
        if let stop = authenticationStop { await stop.task.value }
        guard phase != .stopping else { return }
        let binding = remoteBinding
        let id = runtimeIsRemote ? runtimeID : attaching?.id
        generation = UUID()
        permissionTasks.values.forEach { $0.cancel() }
        permissionTasks.removeAll()
        permissions.cancelAll()
        runtimeID = nil
        forgetRemoteRuntime()
        savedBinding = binding
        bindingKeptFromLink = false
        sessionID = nil
        clearConfiguration()
        cancellationRequested = false
        phase = .disconnected
        status = Self.idleSavedStatus
        onChange?()
        if let id { await client.detach(runtimeID: id) }
    }

    /// Closing a session: stops the runtime a saved binding left on its server, since no
    /// session will attach to it again. The transcript and agent context stay, so reopening
    /// the session resumes it instead.
    public func discardRemoteBinding() async {
        guard let binding = savedBinding else { return }
        savedBinding = nil
        bindingKeptFromLink = false
        _ = try? await client.execute(.stopRuntime(id: AgentRuntimeID(binding.runtimeID)))
    }

    /// Clears what ties the session to a remote runtime it no longer follows. A saved binding
    /// is kept: only a close or a new context gives that one up.
    private func forgetRemoteRuntime() {
        runtimeIsRemote = false
        replaced = nil
        lostPast = nil
        lostBeforeNext = nil
        attaching = nil
        adopting = false
        resumeAttachWaiter()
        turnBoundary = nil
        pendingExit = nil
        unsentTurn = nil
        foreignTurn = nil
    }

    private func resumeAttachWaiter() {
        attachWaiter?.resume()
        attachWaiter = nil
    }

    private func remember(_ turn: UUID) {
        guard !knownTurns.contains(turn) else { return }
        knownTurns.append(turn)
        if knownTurns.count > 64 { knownTurns.removeFirst() }
    }

    /// What shows only once the events before it are taken in: the end of a turn whose outcome
    /// came first, and what an attach's record said, a prompt that never reached the server and
    /// an exit. An `exited` event in the backlog shows the exit first, and this finds nothing.
    private func caughtUp() {
        endTurnIfTakenIn()
        if let unsent = unsentTurn, appliedSequence >= unsent.through {
            unsentTurn = nil
            history.appendNotice(unsent.atQuit ? Self.promptNotSent : Self.promptNotSentOverLink)
            publishHistory()
        }
        guard let exit = pendingExit, appliedSequence >= exit.through else { return }
        if let server = exit.stoppedOn { return resetAfterStop(on: server) }
        resetAfterLoss(status: "Agent exited (\(exit.status))",
                       error: "The agent process ended. Select the agent again to reconnect.")
    }

    private func beginConnecting(startNewSession: Bool) -> Bool {
        guard phase == .disconnected else { return false }
        errorMessage = nil
        if !startNewSession, archivedWithoutContext {
            // Not a failure: nothing was attempted, so there is nothing to retry.
            status = "Saved · Read only"
            onChange?()
            return false
        }
        return true
    }

    private func launch(_ launch: AgentLaunch, cwd: String, startNewSession: Bool) async {
        let token = UUID()
        generation = token
        connectionAttempts += 1
        interruptedPrompt = nil
        let id = AgentRuntimeID(token.uuidString)
        runtimeID = id
        if startNewSession {
            savedAgentSessionID = nil
            archivedWithoutContext = false
        }
        let resumingID = savedAgentSessionID
        if resumingID == nil { history.reset() }
        else { history.restore(messages) }
        sessionID = resumingID
        loadedThroughSequence = nil
        appliedSequence = 0
        updatesTakenThrough = 0
        // The transcript is this session's own, and a load replays what it already shows.
        showsReplayedHistory = false
        forgetRemoteRuntime()
        linkState = .connected
        clearConfiguration()
        phase = .connecting
        status = resumingID == nil ? "Connecting…" : "Resuming…"
        onChange?()
        do {
            let result = try await client.launch(launch, id: id)
            // Superseded while starting: the service may outlive this session, so release the runtime.
            guard generation == token else { _ = try? await client.execute(.stopRuntime(id: id)); return }
            let sequence: UInt64?
            if let resumingID {
                guard case let .runtimeStarted(_, initialization) = result,
                      initialization.agentCapabilities.loadSession else {
                    throw ResumeError.unsupported
                }
                let session = try await client.execute(.loadSession(runtimeID: id, sessionID: resumingID, cwd: cwd))
                guard generation == token else { _ = try? await client.execute(.stopRuntime(id: id)); return }
                guard case let .sessionLoaded(_, response) = session else { throw ResumeError.invalidResponse }
                configuration = SessionConfiguration(configOptions: response.configOptions, models: response.models, modes: response.modes)
                sequence = response.localSequence
                loadedThroughSequence = sequence
            } else {
                let session = try await client.execute(.newSession(runtimeID: id, cwd: cwd))
                guard generation == token else { _ = try? await client.execute(.stopRuntime(id: id)); return }
                guard case let .sessionCreated(_, response) = session else { throw ResumeError.invalidResponse }
                sessionID = response.sessionId
                savedAgentSessionID = response.sessionId
                configuration = SessionConfiguration(configOptions: response.configOptions, models: response.models, modes: response.modes)
                sequence = response.localSequence
            }
            configurationSequence = sequence ?? 0
            legacyModelSequence = sequence ?? 0
            legacyModeSequence = sequence ?? 0
            for update in pendingStateUpdates where update.sessionId == sessionID {
                applyStateUpdate(update)
            }
            pendingStateUpdates.removeAll()
            phase = .ready
            if case .remote = launch {
                runtimeIsRemote = true
                backlogThrough = 0
            }
            if case let .runtimeStarted(_, initialization) = result {
                agentName = initialization.agentInfo?.title ?? initialization.agentInfo?.name
                status = "Connected · \(agentName ?? "ACP agent")"
                acceptsImages = initialization.agentCapabilities.acceptsImages
            } else { status = "Connected" }
        } catch {
            _ = try? await client.execute(.stopRuntime(id: id))
            guard generation == token else { return }
            runtimeID = nil
            sessionID = nil
            clearConfiguration()
            phase = .disconnected
            status = resumingID == nil ? "Not connected" : "Saved · Resume failed"
            errorMessage = error.localizedDescription
            errorIsConnectionFailure = error is RemoteConnectionFailure
            if error is RemoteWorkspaceNotFound {
                errorAdvice = "A session keeps the folder it was started in. Start a new session in a folder that exists."
            } else if resumingID != nil {
                errorAdvice = "Your saved history is unchanged. Retry, or start a new session."
            }
        }
        onChange?()
    }

    private enum ResumeError: LocalizedError {
        case unsupported, invalidResponse
        var errorDescription: String? {
            switch self {
            case .unsupported: "This agent does not support resuming saved sessions."
            case .invalidResponse: "The agent returned an unexpected session response."
            }
        }
    }

    /// Only offered values may be sent, and one change must finish before another prompt or change.
    /// Keep the confirmed selection until the agent acknowledges; errors leave it unchanged.
    public func select(_ kind: SessionPicker.Kind, value: String) async {
        guard phase == .ready, !isChangingConfiguration, let id = runtimeID,
              let picker = configuration[kind], value != picker.currentValue,
              picker.choices.contains(where: { $0.value == value }) else { return }
        let token = generation
        isChangingConfiguration = true
        errorMessage = nil
        onChange?()
        do {
            switch picker.route {
            case let .config(configID):
                let result = try await client.execute(.setSessionConfigOption(runtimeID: id, configID: configID, value: value))
                guard generation == token else { return }
                if case let .sessionConfigOptionSet(_, response) = result,
                   response.localSequence.map({ $0 > configurationSequence }) ?? true {
                    configuration.apply(configOptions: response.configOptions)
                    configurationSequence = response.localSequence ?? configurationSequence
                }
            case .legacyModel:
                let result = try await client.execute(.setSessionModel(runtimeID: id, modelID: value))
                guard generation == token else { return }
                if case let .sessionModelSet(_, sequence) = result, sequence > legacyModelSequence,
                   configuration.model?.route == .legacyModel {
                    configuration.model?.currentValue = value
                    legacyModelSequence = sequence
                }
            case .legacyMode:
                let result = try await client.execute(.setSessionMode(runtimeID: id, modeID: value))
                guard generation == token else { return }
                if case let .sessionModeSet(_, sequence) = result, sequence > legacyModeSequence,
                   configuration.permissionMode?.route == .legacyMode {
                    configuration.permissionMode?.currentValue = value
                    legacyModeSequence = sequence
                }
            }
        } catch {
            guard generation == token else { return }
            if await handleAuthenticationFailure(error) { return }
            errorMessage = error.localizedDescription
        }
        isChangingConfiguration = false
        onChange?()
    }

    public func send(_ text: String, attachments: [PromptAttachment] = []) async {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard phase == .ready, !isChangingConfiguration, let id = runtimeID, hasText || !attachments.isEmpty else { return }
        // The composer takes these out before the draft leaves it, and says why; this only
        // makes sure a link to a file on this Mac never reaches a server.
        guard !attachments.contains(where: refusesRemotely) else { return }
        // Attachments first, then what the user wrote about them. A pasted image an agent cannot
        // take is written to a file here, before anything is recorded as sent.
        let blocks: [ACPPromptBlock]
        do {
            blocks = try attachments.map { try $0.block(acceptsImages: acceptsImages) } + (hasText ? [.text(text)] : [])
        } catch {
            errorMessage = error.localizedDescription
            errorAdvice = "An attachment could not be prepared. Remove it and send again."
            onChange?()
            return
        }
        let token = generation
        // A prompt is user-initiated work that must keep streaming while Latch is in the
        // background; App Nap would otherwise throttle the app that renders it. The Mac is
        // still allowed to sleep on its own schedule.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Agent prompt in flight")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        errorMessage = nil
        phase = .prompting
        promptStartedAt = now()
        lastActiveAt = promptStartedAt
        promptGeneration = UUID()
        let prompting = promptGeneration
        cancellationRequested = false
        let turn = UUID()
        turnID = turn
        // Not once a re-attach is following the same turn in its own right: when the link
        // failed under this prompt, its failure can reach here after Retry, or a fix in
        // Settings, has already attached again and taken the turn up.
        defer { if turnID == turn, promptGeneration == prompting { turnID = nil } }
        remember(turn)
        status = "Working…"
        history.appendUser(text, attachments: attachments.map(\.record))
        if runtimeIsRemote {
            turnBoundary = SavedSession.RemoteBinding(runtimeID: id.rawValue, cursor: appliedSequence,
                                                      boundaryMessageID: history.messages.last?.id, boundaryTurnID: turn)
        }
        publishHistory()
        onChange?()
        let end = await client.endOfTurn(runtimeID: id, turnID: turn, sending: blocks)
        keepIfInterrupted(turn, blocks: blocks, end.result, prompting: prompting)
        await finishTurn(turn, end, generation: token)
    }

    /// A prompt whose link failed under it may never have reached the server; see
    /// `interruptedPrompt`. Not once a re-attach has taken the turn up since.
    private func keepIfInterrupted(_ turn: UUID, blocks: [ACPPromptBlock], _ result: Result<LatchAgentResponse, any Error>,
                                   prompting: UUID) {
        guard case .failure(is RemoteTurnInterrupted) = result, promptGeneration == prompting else { return }
        interruptedPrompt = (turn, blocks)
    }

    private func noteTurnEnded(stopped: Bool = false) {
        turnsEnded += 1
        lastTurnEndedByStop = stopped
    }

    /// How a turn ends, whether `send` started it or an attach found it running. Nothing
    /// changes once the session has moved on to another runtime or another turn.
    ///
    /// The outcome travels apart from the turn's events and can overtake the last of them, so
    /// the turn goes on until those the outcome names are taken in, and is not shown ended, or
    /// announced, without them. The step that takes in the last one ends it, before anything
    /// after it. A failure from this Mac's service names none, and ends the turn at once.
    private func finishTurn(_ turn: UUID, _ end: TurnEnd, generation token: UUID) async {
        guard generation == token, turnID == turn else { return }
        switch end.result {
        case .failure(is RemoteTurnInterrupted):
            // The link failed under the turn, not the turn: the session ends next and keeps
            // the turn, where it stands, for a re-attach to follow.
            return
        case .failure(is RemoteAgentExited):
            // The runtime's exit follows on the same stream and says how it ended.
            return
        case let .failure(error) where Self.requiresAuthentication(error):
            // The runtime is stopped at once, and whatever else the turn said goes with it.
            noteTurnEnded()
            _ = await handleAuthenticationFailure(error)
            return
        default:
            break
        }
        if let through = eventsThrough(of: end), takenThrough < through {
            releaseEndingTurn()
            await withCheckedContinuation { endingTurn = (turn, end.result, through, $0) }
            return
        }
        completeTurn(end.result)
    }

    /// Where a turn's events end, counted as `takenThrough` counts them.
    private func eventsThrough(of end: TurnEnd) -> UInt64? {
        if runtimeIsRemote { return end.journaledThrough }
        guard case let .success(.promptCompleted(_, response)) = end.result else { return nil }
        return response.updatesThrough
    }

    /// How far this session has taken in events: a server's journal, or this Mac's connection
    /// to the agent.
    private var takenThrough: UInt64 { runtimeIsRemote ? appliedSequence : updatesTakenThrough }

    /// Ends the turn waiting for its last events once they are in.
    private func endTurnIfTakenIn() {
        guard let ending = endingTurn, takenThrough >= ending.through else { return }
        endingTurn = nil
        if ending.turn == turnID { completeTurn(ending.result) }
        ending.resume.resume()
    }

    private func releaseEndingTurn() {
        let ending = endingTurn
        endingTurn = nil
        ending?.resume.resume()
    }

    private func completeTurn(_ result: Result<LatchAgentResponse, any Error>) {
        noteTurnEnded()
        switch result {
        case let .success(.promptCompleted(_, response)):
            status = response.stopReason == "cancelled" ? "Cancelled" : "Ready · \(response.stopReason)"
        case .success:
            break
        case let .failure(error):
            errorMessage = error.localizedDescription
            status = "Prompt failed"
        }
        turnID = nil
        turnBoundary = nil
        phase = .ready
        lastActiveAt = now()
        cancellationRequested = false
        permissions.cancelAll()
        if let foreign = foreignTurn, runtimeIsRemote, let runtimeID {
            foreignTurn = nil
            followTurn(foreign.turn, runtimeID: runtimeID, boundary: foreign.boundary)
        }
        onChange?()
    }

    private static func requiresAuthentication(_ error: any Error) -> Bool {
        (error as? ACPJSONRPCErrorObject)?.code == -32000 || (error as? LatchAgentFailure)?.code == .authenticationRequired
    }

    /// An SDK can cache its account for the life of a session. Never keep a rejected
    /// authenticated session ready, or reselecting its harness would reuse that stale state.
    private func handleAuthenticationFailure(_ error: any Error) async -> Bool {
        guard Self.requiresAuthentication(error) else { return false }
        let token = UUID()
        generation = token
        let id = runtimeID
        runtimeID = nil
        forgetRemoteRuntime()
        sessionID = nil
        clearConfiguration()
        permissions.cancelAll()
        permissionTasks.values.forEach { $0.cancel() }
        permissionTasks.removeAll()
        cancellationRequested = false
        phase = .stopping
        status = "Sign-in required"
        errorMessage = error.localizedDescription
        errorAdvice = "Sign in with the agent, then try again."
        onChange?()
        let stoppingClient = client
        let stop = Task {
            if let id { _ = try? await stoppingClient.execute(.stopRuntime(id: id)) }
            guard generation == token else { return }
            phase = .disconnected
            onChange?()
        }
        authenticationStop = (token, stop)
        await stop.value
        if authenticationStop?.token == token { authenticationStop = nil }
        return true
    }

    public func cancel() async {
        // A turn waiting only for its last events is over where it ran; a cancel now could only
        // reach the next one, perhaps another client's.
        guard phase == .prompting, !cancellationRequested, endingTurn == nil, let id = runtimeID else { return }
        let token = generation
        cancellationRequested = true
        permissions.cancelAll()
        status = "Cancelling…"
        onChange?()
        do { _ = try await client.execute(.cancelPrompt(runtimeID: id)) }
        catch {
            guard generation == token, phase == .prompting else { return }
            cancellationRequested = false
            errorMessage = error.localizedDescription
            onChange?()
        }
    }

    public func disconnect() async {
        // Reselect/quit must drain authentication teardown before reconnecting or exiting.
        if let stop = authenticationStop { await stop.task.value }
        guard phase != .stopping else { return }
        generation = UUID()
        let id = runtimeID
        runtimeID = nil
        forgetRemoteRuntime()
        sessionID = nil
        clearConfiguration()
        permissions.cancelAll()
        interruptedPrompt = nil
        phase = .stopping
        status = "Stopping…"
        onChange?()
        // Stop only this session's runtime: the service is shared by every session in the app.
        if let id { _ = try? await client.execute(.stopRuntime(id: id)) }
        phase = .disconnected
        status = "Not connected"
        linkState = .connected
        cancellationRequested = false
        onChange?()
    }

    /// The service holds the agent's request until Latch answers; the decision travels back as a command.
    private func handlePermissionRequest(_ request: ACPPermissionRequest, runtimeID: AgentRuntimeID, requestID: UUID) {
        // A server raises a request again after a re-attach when it cannot tell whether this
        // session saw it; the sheet already showing answers it.
        guard permissionTasks[requestID] == nil else { return }
        // Every client of a server's runtime sees its requests. One raised while this session
        // runs no turn belongs to another client's, so it is theirs to answer, not to refuse.
        // Nor is one taken in while this session's ended turn waits for its last events.
        if client.isRemote, phase != .prompting || endingTurn != nil { return }
        let token = promptGeneration
        let task = Task { @MainActor [weak self] in
            var outcome = ACPPermissionOutcome.cancelled
            if let self, self.runtimeID == runtimeID, request.sessionId == self.sessionID,
               self.phase == .prompting, !self.cancellationRequested {
                let decided = await self.permissions.request(request)
                if self.runtimeID == runtimeID, self.promptGeneration == token,
                   self.phase == .prompting, !self.cancellationRequested { outcome = decided }
            }
            guard let self, !Task.isCancelled else { return }
            self.permissionTasks[requestID] = nil
            // The service may already have closed it (prompt ended); that failure is expected.
            _ = try? await self.client.execute(.resolvePermission(runtimeID: runtimeID, requestID: requestID, outcome: outcome))
        }
        permissionTasks[requestID] = task
    }

    private func closePermission(requestID: UUID) {
        permissionTasks.removeValue(forKey: requestID)?.cancel()
    }

    /// A session update from this Mac's service is in, shown or not: a local turn's end may be
    /// waiting for it.
    private func tookIn(_ notification: ACPSessionNotification) {
        guard !runtimeIsRemote, let sequence = notification.localSequence else { return }
        updatesTakenThrough = max(updatesTakenThrough, sequence)
        endTurnIfTakenIn()
    }

    private func receive(_ event: LatchAgentEvent) {
        switch event {
        case let .sessionUpdate(id, notification) where id == runtimeID:
            defer { tookIn(notification) }
            if phase == .connecting, isStateUpdate(notification) {
                // The event task may run before session/new's continuation. Keep a bounded
                // buffer, then replay only this session's snapshots newer than its reply.
                if pendingStateUpdates.count == 32 { pendingStateUpdates.removeFirst() }
                pendingStateUpdates.append(notification)
                return
            }
            guard notification.sessionId == sessionID else { return }
            applyStateUpdate(notification)
            // session/load replays old content. Keep the saved, bounded transcript (and
            // stable message IDs), rather than appending a second copy. The reply's trusted
            // ingress sequence also excludes replay delivered after its continuation.
            guard phase != .connecting,
                  !(loadedThroughSequence.map { boundary in
                      notification.localSequence.map { $0 <= boundary } ?? false
                  } ?? false) else { return }
            switch notification.event {
            case let .messageChunk(chunk) where chunk.role == .agent:
                if let text = chunk.text {
                    history.appendAssistant(text)
                    publishHistory()
                }
            case let .toolCall(tool, _):
                history.updateTool(tool)
                publishHistory()
            default: break
            }
        case .standardError:
            // Process diagnostics belong to service logging, not chat or its history budget.
            break
        case let .permissionRequested(id, requestID, request) where id == runtimeID:
            handlePermissionRequest(request, runtimeID: id, requestID: requestID)
        case let .permissionClosed(id, requestID) where id == runtimeID:
            closePermission(requestID: requestID)
        case let .processTerminated(id, status) where id == runtimeID:
            resetAfterLoss(status: "Agent exited (\(status))",
                           error: "The agent process ended. Select the agent again to reconnect.")
        default: break
        }
    }

    /// A server's journal: agent events as this Mac's service reports them, and what only a
    /// server knows. Each is taken in at most once, so its sequence can be recorded as applied.
    private func receive(_ event: RemoteServiceEvent) {
        if let limit = lostPast, let (id, sequence) = event.journalPosition, id == runtimeID {
            lostPast = nil
            if sequence > limit, sequence - limit > 1 {
                history.appendNotice(Self.outputLostNotice)
                publishHistory()
            }
        }
        if let notice = lostBeforeNext, let (id, _) = event.journalPosition, id == runtimeID {
            lostBeforeNext = nil
            // Replayed history is journaled before anything else of the runtime, all at once,
            // so what was lost before some of it was history too.
            if case .replayed = event {} else {
                history.appendNotice(notice)
                publishHistory()
            }
        }
        // Already in the transcript: a truncated attach's backlog can begin before what the
        // saved transcript shows.
        if let (id, sequence) = event.journalPosition, id == runtimeID, sequence <= appliedSequence { return }
        switch event {
        case let .link(state):
            guard state != linkState else { return }
            linkState = state
            onChange?()
        case let .attached(id, attachment, server):
            guard let attaching, attaching.id == id else { return }
            rebuild(from: attachment, binding: attaching.binding, id: id, server: server)
            return
        case let .stopped(id, server, sequence) where id == runtimeID:
            appliedSequence = max(appliedSequence, sequence)
            resetAfterStop(on: server)
        case .serverChanged:
            followAgainAfterServerChange()
            return
        case let .agent(event, sequence):
            receive(event)
            if let sequence, event.runtimeID == runtimeID { appliedSequence = max(appliedSequence, sequence) }
        case let .replayed(id, notification, sequence) where id == runtimeID:
            if showsReplayedHistory { showReplayed(notification) }
            appliedSequence = max(appliedSequence, sequence)
        case let .configurationSet(id, configuration, sequence) where id == runtimeID:
            apply(configuration)
            appliedSequence = max(appliedSequence, sequence)
        case let .outputLost(id, nil) where id == runtimeID && replaced.map { appliedSequence < $0.through } == true:
            // A gap in a replay of what the transcript had before the attach: that is shown
            // again, as saved, and only what may have been lost after it is reported.
            let replaced = replaced!
            self.replaced = nil
            let cut: Int? = if let boundary = replaced.boundary {
                history.messages.firstIndex { $0.id == boundary }.map { $0 + 1 }
            } else { 0 }
            if let cut {
                history.restore(Array(history.messages.prefix(cut)) + replaced.messages)
                appliedSequence = max(appliedSequence, replaced.through)
                lostPast = replaced.through
            } else {
                history.appendNotice(Self.outputLostNotice)
            }
            publishHistory()
        case let .outputLost(id, nil) where id == runtimeID && !showsReplayedHistory:
            // Evicted before this client read it: the next event says whether that matters.
            lostBeforeNext = Self.outputLostNotice
        case let .outputLost(id, sequence) where id == runtimeID:
            history.appendNotice(Self.outputLostNotice)
            publishHistory()
            if let sequence { appliedSequence = max(appliedSequence, sequence) }
        case let .turnStarted(id, turn, text, attachments, sequence) where id == runtimeID:
            appliedSequence = max(appliedSequence, sequence)
            if unsentTurn?.turn == turn { unsentTurn = nil }
            // A turn started elsewhere: by another client, or by one while Latch was closed.
            guard !knownTurns.contains(turn) else { break }
            remember(turn)
            history.appendUser(text, attachments: attachments)
            publishHistory()
            // The turn an attach is waiting for: its prompt is the boundary from here on.
            if turn == turnID, phase == .prompting, let runtimeID {
                turnBoundary = SavedSession.RemoteBinding(runtimeID: runtimeID.rawValue, cursor: appliedSequence,
                                                          boundaryMessageID: history.messages.last?.id, boundaryTurnID: turn)
            } else if runtimeIsRemote, sequence > backlogThrough, let runtimeID {
                // Another client prompted the runtime this session follows. The server runs
                // one turn at a time, so this session follows that one to its end, as an
                // attach follows the turn its record shows running, rather than offer a
                // prompt the server would refuse. While its own prompt is in flight, it
                // follows once that prompt is answered; see `foreignTurn`.
                let boundary = SavedSession.RemoteBinding(
                    runtimeID: runtimeID.rawValue, cursor: appliedSequence,
                    boundaryMessageID: history.messages.last?.id, boundaryTurnID: turn)
                if phase == .ready {
                    followTurn(turn, runtimeID: runtimeID, boundary: boundary)
                    onChange?()
                } else if phase == .prompting {
                    foreignTurn = (turn, boundary)
                }
            }
        case let .turnEnded(id, turn, sequence) where id == runtimeID:
            appliedSequence = max(appliedSequence, sequence)
            if foreignTurn?.turn == turn { foreignTurn = nil }
        case let .skipped(id, sequence) where id == runtimeID:
            appliedSequence = max(appliedSequence, sequence)
        default:
            break
        }
        if let replaced, appliedSequence >= replaced.through { self.replaced = nil }
        caughtUp()
    }

    /// A set-* another client made, or this one's own arriving after its reply. The same
    /// sequence guards as a reply's keep an older value from replacing a newer one.
    private func apply(_ change: LatchRemoteConfigurationSet) {
        guard sessionID != nil else { return }
        switch change.route {
        case .config:
            guard let options = change.configOptions,
                  change.acpSequence.map({ $0 > configurationSequence }) ?? true else { return }
            configuration.apply(configOptions: options)
            configurationSequence = change.acpSequence ?? configurationSequence
        case .model:
            guard change.acpSequence.map({ $0 > legacyModelSequence }) ?? true,
                  configuration.model?.route == .legacyModel else { return }
            configuration.model?.currentValue = change.value
            legacyModelSequence = change.acpSequence ?? legacyModelSequence
        case .mode:
            guard change.acpSequence.map({ $0 > legacyModeSequence }) ?? true,
                  configuration.permissionMode?.route == .legacyMode else { return }
            configuration.permissionMode?.currentValue = change.value
            legacyModeSequence = change.acpSequence ?? legacyModeSequence
        default:
            return
        }
        onChange?()
    }

    /// History another client's load replayed, shown as the conversation so far: the user's
    /// messages as well as the agent's, since this session sent none of them. State updates
    /// are left out; the record carried the latest of each.
    ///
    /// A user message arrives in chunks, as the agent's do. One that follows another user
    /// message with nothing between, such as a turn cancelled before any output, cannot be
    /// told apart from more of it unless the agent names its messages, and is shown as part of
    /// it; one that follows anything else, a thought or an image included, begins a message
    /// of its own.
    private func showReplayed(_ notification: ACPSessionNotification) {
        guard notification.sessionId == sessionID else { return }
        switch notification.event {
        case let .messageChunk(chunk) where chunk.role != .thought:
            guard let text = chunk.text else {
                replayEndedMessage = true
                return
            }
            // A chunk that names a message other than the last one's, or names one where that
            // did not, begins it.
            let named = chunk.messageID != replayedMessageID
            replayedMessageID = chunk.messageID
            if chunk.role == .user {
                history.appendUserChunk(text, newMessage: named || replayEndedMessage)
            } else {
                // As live, a thought between two chunks of the agent's does not part them.
                history.appendAssistant(text, newMessage: named)
            }
            replayEndedMessage = false
        case let .toolCall(tool, _):
            history.updateTool(tool)
        default:
            replayEndedMessage = true
            return
        }
        publishHistory()
    }

    private func clearConfiguration() {
        configuration = SessionConfiguration()
        configurationSequence = 0
        legacyModelSequence = 0
        legacyModeSequence = 0
        pendingStateUpdates.removeAll()
        isChangingConfiguration = false
        commands = []
        commandsSequence = 0
        acceptsImages = false
    }

    private func isStateUpdate(_ notification: ACPSessionNotification) -> Bool {
        guard case let .object(update) = notification.update else { return false }
        return update["sessionUpdate"] == .string("config_option_update") || update["sessionUpdate"] == .string("current_model_update") || update["sessionUpdate"] == .string("current_mode_update")
            || update["sessionUpdate"] == .string("available_commands_update")
    }

    private func applyStateUpdate(_ notification: ACPSessionNotification) {
        if case let .availableCommands(list) = notification.event {
            guard notification.localSequence.map({ $0 > commandsSequence }) ?? true else { return }
            commandsSequence = notification.localSequence ?? commandsSequence
            commands = list
            onChange?()
            return
        }
        guard case let .object(update) = notification.update else { return }
        let legacy = update["sessionUpdate"] == .string("current_model_update")
        let mode = update["sessionUpdate"] == .string("current_mode_update")
        let lastSequence = mode ? legacyModeSequence : (legacy ? legacyModelSequence : configurationSequence)
        guard notification.localSequence.map({ $0 > lastSequence }) ?? true,
              configuration.apply(update: notification.update) else { return }
        // Replies and notifications travel through different tasks. Compare their trusted
        // ingress positions so a late continuation cannot restore an older snapshot.
        // Legacy model updates are independent of effort-only modern config snapshots.
        if mode { legacyModeSequence = notification.localSequence ?? lastSequence }
        else if legacy { legacyModelSequence = notification.localSequence ?? lastSequence }
        else { configurationSequence = notification.localSequence ?? lastSequence }
        onChange?()
    }

    private func publishHistory() {
        onTranscriptChange?()
    }
}

private extension RemoteServiceEvent {
    /// The runtime and journal sequence of an event that has one.
    var journalPosition: (AgentRuntimeID, UInt64)? {
        switch self {
        case let .agent(event, sequence): sequence.map { (event.runtimeID, $0) }
        case let .replayed(id, _, sequence), let .configurationSet(id, _, sequence), let .turnStarted(id, _, _, _, sequence),
             let .turnEnded(id, _, sequence), let .skipped(id, sequence): (id, sequence)
        case let .outputLost(id, sequence): sequence.map { (id, $0) }
        case let .stopped(id, _, sequence): (id, sequence)
        case .attached, .link, .serverChanged: nil
        }
    }
}

private extension LatchAgentEvent {
    var runtimeID: AgentRuntimeID {
        switch self {
        case let .sessionUpdate(id, _), let .standardError(id, _), let .processTerminated(id, _),
             let .permissionRequested(id, _, _), let .permissionClosed(id, _): id
        }
    }
}
