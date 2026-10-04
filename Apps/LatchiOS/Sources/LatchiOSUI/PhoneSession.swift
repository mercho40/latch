import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit

/// One session on this device: its model, and what the library saves beside the model's
/// transcript. Every session runs on a server; its folder is a path there.
@MainActor
final class PhoneSession {
    static let untitled = "New Session"

    let id: UUID
    let model: SessionModel
    let serverID: UUID
    /// The folder on the server. An adopted runtime's record may correct it.
    private(set) var path: String
    private(set) var agent: AgentPreset
    /// The command a Custom agent runs, fixed when the session was made.
    private(set) var customCommand: String
    /// From the first prompt, as on the Mac, then the agent's own title for the conversation
    /// once it gives one, unless the user named it; until then "New Session".
    private(set) var title: String
    /// The agent's title this session last took, so a later one from the agent replaces it.
    private var adoptedAgentTitle: String?
    /// The composer's text, saved with the session.
    var draft: String {
        didSet { if draft != oldValue { notify(transcript: false, persistOnly: true) } }
    }
    /// A turn ended while the session was not on screen. Opening it clears this.
    var hasUnseenReply = false {
        didSet { if hasUnseenReply != oldValue { notify(transcript: false) } }
    }
    /// Stop Agent was chosen, and nothing has connected since.
    private(set) var stoppedHere = false
    /// The name the agent gave itself when it last connected, saved so a relaunch shows it
    /// before connecting again.
    private var agentName: String?
    /// The agent's name from the server's list, for an adopted runtime whose record has not
    /// arrived yet.
    private var listedAgentTitle: String?
    /// Connected or re-attached once already, so opening it again does not reconnect a
    /// session the user stopped or one that failed.
    private(set) var hasStarted = false
    /// Tests and snapshots state a row's status directly instead of driving a model there.
    var stubbedStatus: SessionRowStatus.Input?
    /// The screen showing the session takes back the messages Stop gives back, into its
    /// composer; false when there is none. See `queueReturned(_:)`.
    var takesBackQueue: (([QueuedPrompt]) -> Bool)?
    /// Photos of messages given back while no screen showed the session, for the next one.
    private(set) var returnedAttachments: [PromptAttachment] = []

    private var observers: [Observer] = []
    private var connectTask: Task<Void, Never>?

    private struct Observer {
        weak var owner: AnyObject?
        let change: @MainActor () -> Void
        let transcript: (@MainActor () -> Void)?
        let persist: (@MainActor () -> Void)?
    }

    /// A session restored from the library, or a new one when `saved` is nil.
    init(id: UUID = UUID(), serverID: UUID, path: String, agent: AgentPreset, customCommand: String,
         saved: SavedSession? = nil, connector: any RemoteSessionConnector) {
        self.id = saved?.id ?? id
        self.serverID = serverID
        self.path = path
        self.agent = agent
        self.customCommand = customCommand
        title = saved?.title ?? Self.untitled
        draft = saved?.draft ?? ""
        agentName = saved?.agentName
        adoptedAgentTitle = saved?.adoptedAgentTitle
        model = SessionModel(makeClient: { connector.makeClient(serverID: serverID) })
        model.sendsAttachmentsRemotely = true
        if let saved {
            model.restore(messages: saved.messages, agentSessionID: saved.agentSessionID,
                          lastActiveAt: saved.lastActiveAt, remote: saved.remote)
        } else {
            // A new session was last active when it was made, so it sorts and reads as "now".
            model.restore(messages: [], agentSessionID: nil, lastActiveAt: model.now())
        }
        model.onChange = { [weak self] in self?.modelChanged() }
        model.onTranscriptChange = { [weak self] in self?.transcriptChanged() }
        model.onQueueReturned = { [weak self] in self?.queueReturned($0) }
    }

    convenience init(saved: SavedSession, connector: any RemoteSessionConnector) {
        self.init(serverID: saved.serverID ?? UUID(), path: saved.workspacePath,
                  agent: AgentPreset(rawValue: saved.agentID) ?? .custom, customCommand: saved.customCommand,
                  saved: saved, connector: connector)
    }

    /// Exactly what the Mac's session saves, so a library means the same on both. Messages
    /// waiting for the turn to end are saved in the draft, before it: should iOS end the app
    /// while it is suspended, they come back in the composer rather than being lost. Until
    /// then they wait, and go, as before.
    var savedSession: SavedSession {
        SavedSession(id: id, workspacePath: path, title: title, agentID: agent.rawValue, customCommand: customCommand,
                     draft: SessionQueueView.draft(returning: model.queuedPrompts.map(\.text), before: draft), messages: model.messages,
                     agentSessionID: model.savedAgentSessionID, lastActiveAt: model.lastActiveAt,
                     serverID: serverID, remote: model.remoteBinding, agentName: agentName,
                     adoptedAgentTitle: adoptedAgentTitle == title ? adoptedAgentTitle : nil)
    }

    var location: WorkspaceLocation { .remote(serverID: serverID, path: path) }

    /// "Claude Code"; for a custom agent, the name it gave itself once it has connected, and
    /// until then its command's name.
    var agentTitle: String {
        if agent != .custom { return agent.title }
        if let agentName, !agentName.isEmpty { return agentName }
        if let listedAgentTitle, customCommand.isEmpty { return listedAgentTitle }
        let command = customCommand.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }
        return command.flatMap { $0.isEmpty ? nil : $0 } ?? "Custom"
    }

    /// The row's second line. The space before the dot does not break, so a line that wraps
    /// ends with the dot rather than starts with it.
    var subtitle: String { "\(agentTitle)\u{00A0}· \(location.folderName)" }

    /// What the agent is asking, for the banner that says a decision waits: its heading for
    /// the request, such as "Ready to code?", or the tool call's title.
    var pendingRequestTitle: String? {
        guard let title = model.permissions.current?.heading?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return title.isEmpty ? nil : title
    }

    /// The agent's question waiting for an answer, for the banner that says so.
    var pendingQuestion: String? {
        guard let message = model.questions.current?.form.message.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return message.isEmpty ? nil : message
    }

    /// Names the session as the user chose. A blank name changes nothing.
    func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else { return }
        title = String(trimmed.prefix(120))
        // A name the user chose is never replaced by the agent's.
        adoptedAgentTitle = nil
        notify(transcript: false)
    }

    /// When the conversation last moved, for sorting.
    var lastActiveAt: Date { stubbedStatus?.lastActiveAt ?? model.lastActiveAt ?? .distantPast }

    var needsApproval: Bool { stubbedStatus?.needsApproval ?? (model.permissions.current != nil) }

    var asksQuestion: Bool { stubbedStatus?.asksQuestion ?? (model.questions.current != nil) }

    /// A decision or an answer holds the agent up: what the badge counts.
    var waitsForUser: Bool { needsApproval || asksQuestion }

    var statusInput: SessionRowStatus.Input {
        if let stubbedStatus { return stubbedStatus }
        return SessionRowStatus.Input(
            phase: model.phase, status: model.status, needsApproval: model.permissions.current != nil,
            asksQuestion: model.questions.current != nil,
            linkState: model.linkState, hasError: model.errorMessage != nil,
            connectionFailure: model.errorIsConnectionFailure, stoppedOnServer: model.stoppedOnServer,
            stoppedHere: stoppedHere, stopping: model.cancellationRequested, promptStartedAt: model.promptStartedAt,
            lastActiveAt: model.lastActiveAt, hasUnseenReply: hasUnseenReply)
    }

    func rowStatus(now: Date) -> SessionRowStatus { SessionRowStatus.make(statusInput, now: now) }

    // MARK: Waiting messages

    /// Messages written while the agent worked, given back by Stop or by losing the session,
    /// go back in the composer of the screen showing it; with none, their text goes before the
    /// saved draft, and their photos wait for the next screen. Nothing written is lost.
    private func queueReturned(_ prompts: [QueuedPrompt]) {
        guard !prompts.isEmpty else { return }
        if takesBackQueue?(prompts) == true { return }
        draft = SessionQueueView.draft(returning: prompts.map(\.text), before: draft)
        returnedAttachments = Array((prompts.flatMap(\.attachments) + returnedAttachments).prefix(ComposerImage.maximumCount))
    }

    /// The photos given back while no screen showed the session, for the screen now showing it.
    func takeReturnedAttachments() -> [PromptAttachment] {
        defer { returnedAttachments = [] }
        return returnedAttachments
    }

    // MARK: Observing

    /// Everything that shows the session hears of it here, since the model has one callback
    /// of each kind: the library, the list and the open session screen. `change` follows the
    /// model's `onChange`, `transcript` its `onTranscriptChange`; `persist` hears of edits
    /// that only need saving, such as the draft. Held weakly by `owner`.
    func observe(_ owner: AnyObject, change: @escaping @MainActor () -> Void,
                 transcript: (@MainActor () -> Void)? = nil, persist: (@MainActor () -> Void)? = nil) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
        observers.append(Observer(owner: owner, change: change, transcript: transcript, persist: persist))
    }

    func stopObserving(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    private func modelChanged() {
        if model.phase != .disconnected { stoppedHere = false }
        adoptAgentTitle()
        if let name = model.agentName, name != agentName {
            agentName = name
            notify(transcript: false, persistOnly: true)
        }
        notify(transcript: false)
    }

    private func transcriptChanged() {
        if title == Self.untitled, let first = model.messages.first(where: { $0.role == .user }),
           let derived = Self.title(fromPrompt: first) {
            title = derived
            notify(transcript: false)
        }
        notify(transcript: true)
    }

    private func notify(transcript: Bool, persistOnly: Bool = false) {
        for observer in observers where observer.owner != nil {
            if persistOnly { observer.persist?() }
            else if transcript { observer.transcript?() }
            else { observer.change() }
        }
    }

    private func adoptAgentTitle() {
        guard let adopted = Self.adoptedTitle(current: title, agentTitle: model.agentTitle,
                                              firstPrompt: model.messages.first { $0.role == .user },
                                              adoptedBefore: adoptedAgentTitle) else { return }
        title = adopted
        adoptedAgentTitle = adopted
        notify(transcript: false)
    }

    /// The Mac's rule for the agent's own title, such as the one Claude Code writes after a
    /// turn: it replaces "New Session", the title the first prompt gave, or one the agent gave
    /// before; never a name the user chose. Nil when the title stays as it is.
    static func adoptedTitle(current: String, agentTitle: String?, firstPrompt: ChatMessage?, adoptedBefore: String?) -> String? {
        guard let agentTitle else { return nil }
        let title = String(agentTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !title.isEmpty, title != current else { return nil }
        let fromPrompt = firstPrompt.flatMap(Self.title(fromPrompt:))
        return current == untitled || current == fromPrompt || current == adoptedBefore ? title : nil
    }

    /// The Mac's rule: the prompt's first line, or the first attachment's name when it has no
    /// text, at most 60 characters.
    static func title(fromPrompt message: ChatMessage) -> String? {
        let firstLine = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? message.text
        let text = firstLine.trimmingCharacters(in: .whitespaces)
        let title = text.isEmpty ? message.attachments.first?.name ?? "" : text
        return title.isEmpty ? nil : String(title.prefix(60))
    }

    // MARK: Connecting

    /// The runtime an adoption is taking up, until its record arrives and says which agent
    /// it is. Until then the session has nothing it could launch, so connecting adopts again,
    /// and it is not saved: after a relaunch the server lists the runtime again.
    private(set) var pendingAdoption: AgentRuntimeID?

    /// What connecting launches should the runtime be gone: nil for a session made by adopting
    /// an agent this device cannot name, which is never launched blind.
    var launchAgent: LatchRemoteAgent? {
        if let resolvedAgent { return resolvedAgent }
        guard agent == .custom else { return .preset(agent.rawValue) }
        return customCommand.isEmpty ? nil : .custom(customCommand)
    }

    /// An adopted runtime's agent that `AgentPreset` does not know, for this run only: the
    /// library saves only agents it can name.
    private var resolvedAgent: LatchRemoteAgent?

    /// Connects on first opening, and re-attaches a runtime a saved binding names: the Mac
    /// does this when a session's view first loads. Later openings leave it as it is.
    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        guard model.phase == .disconnected else { return }
        connect()
    }

    /// Connects, or re-attaches when the session left a runtime on its server. Retry.
    func connect(startNewSession: Bool = false) {
        hasStarted = true
        if let pendingAdoption { return adopt(pendingAdoption) }
        // A session that can name no agent can only follow the runtime it has. `.unknown`
        // is refused by the server, so a runtime found gone launches nothing.
        let agent = launchAgent ?? .unknown
        guard launchAgent != nil || model.remoteBinding != nil else { return }
        let previous = connectTask
        connectTask = Task { [model, path] in
            await previous?.value
            await model.connect(remote: agent, path: path, startNewSession: startNewSession)
        }
    }

    /// Takes up a runtime this device did not start, then keeps the agent and folder its
    /// record names, so the session saves and relaunches as that agent.
    func adopt(_ runtime: LatchRemoteRuntimeSummary) {
        listedAgentTitle = runtime.agentTitle
        adopt(runtime.runtimeID)
    }

    private func adopt(_ id: AgentRuntimeID) {
        hasStarted = true
        pendingAdoption = id
        let previous = connectTask
        connectTask = Task { [weak self, model] in
            await previous?.value
            await model.adopt(runtimeID: id)
            self?.takeAgentFromRecord()
        }
    }

    private func takeAgentFromRecord() {
        guard let remote = model.remoteAgent else { return }
        pendingAdoption = nil
        if let workspace = model.remoteWorkspace, !workspace.isEmpty { path = workspace }
        switch remote {
        case let .preset(raw):
            if let preset = AgentPreset(rawValue: raw) { agent = preset } else { resolvedAgent = remote }
        case let .custom(command):
            agent = .custom
            customCommand = command
        case .unknown:
            break
        }
        notify(transcript: false)
    }

    /// Whether Stop Agent has a runtime to stop: one this session runs or is starting, or one
    /// a saved binding says it left on the server. Not an adoption still attaching, whose
    /// runtime is not this session's until its record arrives.
    var canStop: Bool {
        guard pendingAdoption == nil else { return false }
        switch model.phase {
        case .connecting, .ready, .prompting: return true
        case .stopping: return false
        case .disconnected: return model.remoteBinding != nil
        }
    }

    /// Stop Agent: stops the runtime on the server, including one a saved binding names that
    /// nothing is attached to, as closing a session on the Mac does. The transcript stays.
    func stop() async {
        let running = canStop
        await model.disconnect()
        await model.discardRemoteBinding()
        if running { stoppedHere = true }
        notify(transcript: false)
    }

    /// Leaves the runtime running on the server, as backgrounding and removing do.
    func detach() async {
        await model.detach()
    }

    /// Takes up one of the agent's saved conversations in this session, which holds none yet:
    /// the same agent starts again on it and shows its history. Titled as the agent titled it,
    /// and the agent's own later title replaces that, as one it gave.
    func resume(_ conversation: ACPSessionSummary) {
        guard model.phase == .ready, model.messages.isEmpty else { return }
        title = Self.title(resuming: conversation)
        adoptedAgentTitle = title
        notify(transcript: false)
        let previous = connectTask
        connectTask = Task { [model] in
            await previous?.value
            await model.switchToAgentSession(conversation.sessionId)
        }
    }

    /// The conversation's title, on one line and at most 60 characters, or "Resumed Conversation".
    static func title(resuming conversation: ACPSessionSummary) -> String {
        let line = conversation.title?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? "Resumed Conversation" : String(line.prefix(60))
    }

    /// Waits for a connect or adopt in flight, for tests.
    func settled() async { await connectTask?.value }
}
