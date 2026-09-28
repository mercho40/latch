import Foundation
import LatchAgentCore
import LatchRemoteProtocol
import LatchSessionKit

/// Every session on this device, saved with `SessionStore` as the Mac saves its window's, and
/// what the runtimes list found on each server. Backgrounding saves and changes nothing
/// else: the runtimes run on, and becoming active probes every channel so each re-attaches
/// from its cursor.
@MainActor
final class SessionLibrary {
    /// Why a session wants the user while it is not on screen.
    enum Attention: Equatable {
        case needsApproval, finished, stoppedOnServer
    }

    private(set) var sessions: [PhoneSession] = []
    /// The session last opened, saved so a relaunch shows it again.
    private(set) var selectedSessionID: UUID?
    private(set) var runtimes: [UUID: ServerRuntimes] = [:]
    private(set) var persistenceError: String?
    let servers: any ServerStore
    let connector: any RemoteSessionConnector

    /// The list's structure changed: sessions came or went, or a server's runtimes did.
    var onChange: (() -> Void)?
    /// One row's content changed.
    var onSessionChange: ((PhoneSession) -> Void)?
    /// A session off screen finished a turn or wants a decision, while the app is active.
    var onAttention: ((PhoneSession, Attention) -> Void)?
    /// The number of sessions waiting for a decision, whenever it changes.
    var onApprovalCountChange: ((Int) -> Void)?
    /// A server went from Servers, as it was just before.
    var onServerRemoved: ((ServerProfile) -> Void)?
    /// Whether the user can see this session now. The root answers.
    var isSessionVisible: (UUID) -> Bool = { _ in false }
    /// The scene is in the foreground; attention is only raised then.
    var isActive = true
    var now: () -> Date = Date.init

    private let store: SessionStore?
    private let listRuntimes: RuntimeListing
    private var persistenceReady: Bool
    private var restoreAttempted = false
    private var debounceSave: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var listings: [UUID: UUID] = [:]
    private var watched: [UUID: Watched] = [:]
    private var approvalCount = 0
    /// Servers the sessions' clients were made for. One that appears later, such as a server
    /// whose token was entered again, gets its sessions made anew, since a session's client
    /// is made once and one made for an unknown server never connects.
    private var knownServerIDs: Set<UUID>
    /// The servers as they were at the last change, so a removed one's address is known.
    private var knownServers: [UUID: ServerProfile]
    /// The runtimes sessions here follow or are adopting, as the list last showed them.
    private var followed: Set<String> = []

    /// What a session last showed, so only a new request or a new turn end is announced.
    private struct Watched {
        var permission: UUID?
        var turnsEnded: Int
    }

    /// `store` nil saves nothing, for tests and previews.
    init(servers: any ServerStore, connector: any RemoteSessionConnector, store: SessionStore?,
         listRuntimes: @escaping RuntimeListing = RemoteRuntimeList.live) {
        self.servers = servers
        self.connector = connector
        self.store = store
        self.listRuntimes = listRuntimes
        persistenceReady = store == nil
        knownServerIDs = Set(servers.servers.map(\.id))
        knownServers = Dictionary(servers.servers.map { ($0.id, $0) }) { first, _ in first }
        NotificationCenter.default.addObserver(self, selector: #selector(serversChanged),
                                               name: .serverStoreDidChange, object: servers)
    }

    // MARK: Reading

    /// The sessions on one server, most recently active first.
    func sessions(on serverID: UUID) -> [PhoneSession] {
        sessions.filter { $0.serverID == serverID }.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Sessions whose server is gone from Servers.
    var orphanedSessions: [PhoneSession] {
        let known = Set(servers.servers.map(\.id))
        return sessions.filter { !known.contains($0.serverID) }.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Every session in the order the list shows them, for ⌘[ and ⌘].
    var orderedSessions: [PhoneSession] {
        servers.servers.flatMap { sessions(on: $0.id) } + orphanedSessions
    }

    func session(id: UUID) -> PhoneSession? { sessions.first { $0.id == id } }

    /// Folders in use on a server, most recent first, for New Session to offer: this device's
    /// sessions there, then the folders of the runtimes the server listed.
    func recentFolders(on serverID: UUID, limit: Int = 8) -> [String] {
        var seen = Set<String>()
        let paths = sessions(on: serverID).map(\.path) + (runtimes[serverID]?.runtimes ?? []).map(\.workspace)
        return Array(paths.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit))
    }

    /// Runtimes on the server that no session here follows or is adopting, and that are up: a
    /// runtime still starting is most likely one this device is launching. None until the
    /// saved sessions are loaded, since until then this device's own would be among them.
    func adoptableRuntimes(on serverID: UUID) -> [LatchRemoteRuntimeSummary] {
        guard persistenceReady || persistenceError != nil else { return [] }
        let followed = followedRuntimeIDs
        return (runtimes[serverID]?.runtimes ?? []).filter {
            $0.lifecycle == .ready && !followed.contains($0.runtimeID.rawValue)
        }
    }

    private var followedRuntimeIDs: Set<String> {
        Set(sessions.compactMap { $0.pendingAdoption?.rawValue ?? $0.model.remoteBinding?.runtimeID })
    }

    /// The session here that follows or is adopting the runtime.
    func session(following runtimeID: String) -> PhoneSession? {
        sessions.first { ($0.pendingAdoption?.rawValue ?? $0.model.remoteBinding?.runtimeID) == runtimeID }
    }

    var approvalsNeeded: Int { sessions.filter(\.needsApproval).count }

    var savedLibrary: SavedSessionLibrary {
        // An adoption whose record never came has nothing to keep; the server lists it again.
        SavedSessionLibrary(sessions: sessions.filter { $0.pendingAdoption == nil }.map(\.savedSession),
                            selectedSessionID: sessions.contains { $0.id == selectedSessionID } ? selectedSessionID : nil)
    }

    // MARK: Sessions

    /// Adds a session and starts its agent in a new context.
    @discardableResult
    func create(serverID: UUID, path: String, agent: AgentPreset) -> PhoneSession {
        let command = agent == .custom ? servers.server(id: serverID)?.customCommand ?? "" : ""
        let session = PhoneSession(serverID: serverID, path: path, agent: agent, customCommand: command,
                                   connector: connector)
        add(session)
        session.connect(startNewSession: true)
        return session
    }

    /// Takes up a runtime another device started, replaying its journal from the start. A
    /// runtime a session here already follows opens that session instead.
    @discardableResult
    func adopt(_ runtime: LatchRemoteRuntimeSummary, serverID: UUID) -> PhoneSession {
        if let existing = session(following: runtime.runtimeID.rawValue) { return existing }
        let session = PhoneSession(serverID: serverID, path: runtime.workspace, agent: .custom, customCommand: "",
                                   connector: connector)
        session.adopt(runtime)
        add(session)
        return session
    }

    /// Adds a session made elsewhere, such as by a test.
    func add(_ session: PhoneSession) {
        sessions.append(session)
        watch(session)
        followed = followedRuntimeIDs
        onChange?()
        scheduleSave()
    }

    /// The session is on screen: its unread mark goes, and it connects the first time.
    func open(_ session: PhoneSession) {
        selectedSessionID = session.id
        session.hasUnseenReply = false
        session.startIfNeeded()
        scheduleSave()
    }

    /// No session is on screen, as when an iPhone goes back to the list.
    func deselect() {
        guard selectedSessionID != nil else { return }
        selectedSessionID = nil
        scheduleSave()
    }

    /// Removes the session from this device and leaves its agent running on the server, where
    /// the runtimes list offers it again.
    func remove(_ session: PhoneSession) async {
        guard sessions.contains(where: { $0 === session }) else { return }
        sessions.removeAll { $0 === session }
        watched[session.id] = nil
        onForget?(session)
        session.stopObserving(self)
        if selectedSessionID == session.id { selectedSessionID = nil }
        onChange?()
        publishApprovals()
        scheduleSave()
        await session.detach()
        await refreshRuntimes(for: [session.serverID])
    }

    /// Puts sessions left by a removed server on `serverID`, as when that server is added back:
    /// each is made anew from what it saved, and one that left a runtime there attaches to it.
    func move(_ moving: [PhoneSession], to serverID: UUID) {
        for old in moving {
            guard let index = sessions.firstIndex(where: { $0 === old }) else { continue }
            var saved = old.savedSession
            saved.serverID = serverID
            let session = PhoneSession(saved: saved, connector: connector)
            session.hasUnseenReply = old.hasUnseenReply
            old.stopObserving(self)
            old.model.onChange = nil
            old.model.onTranscriptChange = nil
            sessions[index] = session
            watch(session)
            if session.model.remoteBinding != nil { session.startIfNeeded() }
        }
        followed = followedRuntimeIDs
        onChange?()
        scheduleSave()
    }

    /// Forgets the images kept for a session's prompts. The library calls this as it goes.
    var onForget: ((PhoneSession) -> Void)?

    /// Stops the session's agent on its server. The session and its transcript stay.
    func stop(_ session: PhoneSession) async {
        await session.stop()
        scheduleSave()
        await refreshRuntimes(for: [session.serverID])
    }

    private func watch(_ session: PhoneSession) {
        watched[session.id] = Watched(permission: session.model.permissions.current?.id,
                                      turnsEnded: session.model.turnsEnded)
        session.observe(self, change: { [weak self, weak session] in
            guard let self, let session else { return }
            self.sessionChanged(session)
        }, transcript: { [weak self] in
            self?.scheduleSave()
        }, persist: { [weak self] in
            self?.scheduleSave()
        })
    }

    private func sessionChanged(_ session: PhoneSession) {
        let model = session.model
        let permission = model.permissions.current?.id
        let previous = watched[session.id] ?? Watched(permission: nil, turnsEnded: model.turnsEnded)
        watched[session.id] = Watched(permission: permission, turnsEnded: model.turnsEnded)
        let visible = isSessionVisible(session.id)
        if model.turnsEnded != previous.turnsEnded, !visible {
            // A failed turn leaves no unread mark: the row already shows the failure.
            if model.errorMessage == nil, !model.lastTurnEndedByStop { session.hasUnseenReply = true }
            if isActive { onAttention?(session, model.lastTurnEndedByStop ? .stoppedOnServer : .finished) }
        }
        if let permission, permission != previous.permission, !visible, isActive {
            onAttention?(session, .needsApproval)
        }
        // An adoption that took, or a runtime let go of, moves a row in or out of "On <server>".
        let nowFollowed = followedRuntimeIDs
        if nowFollowed != followed {
            followed = nowFollowed
            onChange?()
        } else {
            onSessionChange?(session)
        }
        publishApprovals()
        scheduleSave()
    }

    private func publishApprovals() {
        let count = approvalsNeeded
        guard count != approvalCount else { return }
        approvalCount = count
        onApprovalCountChange?(count)
    }

    /// A removed server's sessions let go of their runtimes, which run on; they stay here and
    /// say their server is gone. A renamed one's rows show the new name. A server that was not
    /// known before, such as one whose token was entered again, gets its sessions made anew
    /// from what they saved, and those that left a runtime there attach to it.
    @objc private func serversChanged() {
        let known = Set(servers.servers.map(\.id))
        for (id, server) in knownServers where !known.contains(id) { onServerRemoved?(server) }
        knownServers = Dictionary(servers.servers.map { ($0.id, $0) }) { first, _ in first }
        for session in sessions where !known.contains(session.serverID) && session.model.phase != .disconnected {
            Task { await session.detach() }
        }
        let appeared = known.subtracting(knownServerIDs)
        knownServerIDs = known
        for (index, old) in sessions.enumerated() where appeared.contains(old.serverID) {
            let session = PhoneSession(saved: old.savedSession, connector: connector)
            session.hasUnseenReply = old.hasUnseenReply
            old.stopObserving(self)
            old.model.onChange = nil
            old.model.onTranscriptChange = nil
            sessions[index] = session
            watch(session)
            if session.model.remoteBinding != nil { session.startIfNeeded() }
        }
        runtimes = runtimes.filter { known.contains($0.key) }
        onChange?()
        if !appeared.isEmpty { Task { await refreshRuntimes(for: Array(appeared)) } }
    }

    // MARK: Runtimes on servers

    /// Asks each server, all at once, which runtimes it has. Returns when every answer is in.
    func refreshRuntimes(for serverIDs: [UUID]? = nil) async {
        let targets = servers.servers.filter { serverIDs?.contains($0.id) ?? true }
        guard !targets.isEmpty else { return }
        var tokens: [UUID: UUID] = [:]
        for server in targets {
            let token = UUID()
            tokens[server.id] = token
            listings[server.id] = token
            runtimes[server.id, default: ServerRuntimes()].isLoading = true
        }
        onChange?()
        let listRuntimes = listRuntimes
        await withTaskGroup(of: (UUID, Result<[LatchRemoteRuntimeSummary], any Error>).self) { group in
            for server in targets {
                let options = server.connectionOptions
                group.addTask {
                    do { return (server.id, .success(try await listRuntimes(options))) }
                    catch { return (server.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                // A later refresh, or a removed server, supersedes this answer.
                guard listings[id] == tokens[id], servers.server(id: id) != nil else { continue }
                listings[id] = nil
                switch result {
                case let .success(list): runtimes[id] = ServerRuntimes(runtimes: list, answered: true)
                case let .failure(error):
                    runtimes[id] = ServerRuntimes(runtimes: runtimes[id]?.runtimes ?? [],
                                                  failure: Self.listingFailure(error, server: servers.server(id: id)?.name))
                }
                onChange?()
            }
        }
    }

    /// Why a server could not be listed. An error with no words of its own, such as a
    /// network framework's, reads as "The operation couldn't be completed", which says nothing.
    static func listingFailure(_ error: any Error, server: String?) -> String {
        if (error as? LocalizedError)?.errorDescription != nil { return ServerCheckText.failure(error) }
        return "\(server ?? "The server") did not answer."
    }

    // MARK: Scene

    /// Suspended, the app's sockets went quietly; each channel checks its link now and
    /// re-attaches from its cursor, rather than after a heartbeat.
    func didBecomeActive() {
        isActive = true
        // A token unreadable before the first unlock may be readable now.
        if let servers = servers as? any PhoneServerStore, !servers.missingTokens.isEmpty { servers.reload() }
        (connector as? ChannelRemoteSessionConnector)?.probeAll()
        Task { await refreshRuntimes() }
    }

    // MARK: Persistence

    /// Loads the saved sessions, then re-attaches those that left a runtime on a server, before
    /// any is opened, as the Mac does at launch: a turn that finished meanwhile, or a decision
    /// waiting, shows on its row now.
    func restore() async {
        guard let store, !restoreAttempted else { return }
        restoreAttempted = true
        do {
            let library = try await store.load()
            for saved in library.sessions where saved.serverID != nil {
                let session = PhoneSession(saved: saved, connector: connector)
                sessions.append(session)
                watch(session)
            }
            for session in sessions where session.model.remoteBinding != nil { session.startIfNeeded() }
            selectedSessionID = library.selectedSessionID.flatMap { id in sessions.contains { $0.id == id } ? id : nil }
            persistenceReady = true
            followed = followedRuntimeIDs
            onChange?()
            publishApprovals()
        } catch {
            // The file stays as it is; this run cannot overwrite what it could not read.
            persistenceError = "\(error.localizedDescription) Existing saved data has not been discarded."
            onChange?()
        }
    }

    /// Throttled rather than restarted on every chunk, so a long reply still reaches the disk.
    func scheduleSave() {
        guard store != nil, persistenceReady, debounceSave == nil else { return }
        debounceSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            self.debounceSave = nil
            await self.flush()
        }
    }

    /// Saves now. The scene calls this when it leaves the foreground.
    func flush() async {
        debounceSave?.cancel()
        debounceSave = nil
        guard let store, persistenceReady else { return }
        let snapshot = savedLibrary
        let previous = saveTask
        let task = Task { [weak self] in
            // A later snapshot is never overwritten by an earlier save still in flight.
            await previous?.value
            do {
                try await store.save(snapshot)
                self?.persistenceError = nil
            } catch {
                self?.persistenceError = "\(error.localizedDescription) Existing saved data has not been discarded."
            }
        }
        saveTask = task
        await task.value
    }
}
