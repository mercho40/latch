import Foundation
import LatchAgentCore

/// Stored as plaintext JSON, including commands, drafts, and transcripts. No credentials,
/// environment, login state, or permission decisions are stored by this model.
public struct SavedSession: Codable, Equatable, Sendable {
    public var id: UUID
    public var workspacePath: String
    public var title: String
    public var agentID: String
    public var customCommand: String
    public var draft: String
    public var messages: [ChatMessage]
    public var agentSessionID: String?
    /// When the conversation last moved: a prompt sent or a turn finished. Absent in sessions
    /// saved before it was kept, which then show no time.
    public var lastActiveAt: Date? = nil
    /// The server the session runs on, or nil for this Mac. For a remote session
    /// `workspacePath` is a path on that server, never one on this Mac.
    public var serverID: UUID? = nil
    /// The runtime a remote session left running on its server when Latch quit, and how far
    /// `messages` has followed its journal, so a relaunch attaches to it again. Saved in the
    /// same snapshot as the messages, so the two always agree. Nil for a session on this Mac,
    /// and for one that was closed: closing stops the runtime.
    public var remote: RemoteBinding? = nil
    /// The name the agent gave itself when it last connected, such as "Mock Agent", for a
    /// custom command whose own name says little. The iPhone and iPad keep it; the Mac saves nil.
    public var agentName: String? = nil
    /// `title` when it is one the agent gave the conversation, so a later one from the agent may
    /// replace it; nil when the title is the user's own, or the first prompt's.
    public var adoptedAgentTitle: String? = nil

    public init(id: UUID, workspacePath: String, title: String, agentID: String, customCommand: String, draft: String,
                messages: [ChatMessage], agentSessionID: String? = nil, lastActiveAt: Date? = nil, serverID: UUID? = nil,
                remote: RemoteBinding? = nil, agentName: String? = nil, adoptedAgentTitle: String? = nil) {
        self.id = id
        self.workspacePath = workspacePath
        self.title = title
        self.agentID = agentID
        self.customCommand = customCommand
        self.draft = draft
        self.messages = messages
        self.agentSessionID = agentSessionID
        self.lastActiveAt = lastActiveAt
        self.serverID = serverID
        self.remote = remote
        self.agentName = agentName
        self.adoptedAgentTitle = adoptedAgentTitle
    }

    public struct RemoteBinding: Codable, Equatable, Sendable {
        public var runtimeID: String
        /// The last journal sequence `messages` reflects: the one before the running turn's
        /// start, or the last one applied when no turn was running.
        public var cursor: UInt64
        /// The last message that `cursor` accounts for. Anything after it is output of the
        /// running turn, replayed from the journal on attach. IDs, not a count, because the
        /// history evicts its oldest messages.
        public var boundaryMessageID: UUID?
        /// The turn running at `cursor`, whose prompt is already the boundary message.
        public var boundaryTurnID: UUID?
        /// The last journal sequence applied at all, past `cursor` while a turn runs. A journal
        /// evicted past `cursor` cannot replay the turn from its prompt, so the relaunch keeps
        /// the saved transcript and takes up only what comes after this.
        public var applied: UInt64
        /// The transcript is what the runtime's journal replayed from its start, history an
        /// agent replayed on another client's load included, as for a runtime adopted from
        /// another device. Nil rather than false, so most bindings are saved without it.
        public var showsReplayedHistory: Bool?

        public init(runtimeID: String, cursor: UInt64, boundaryMessageID: UUID? = nil, boundaryTurnID: UUID? = nil,
                    applied: UInt64? = nil, showsReplayedHistory: Bool? = nil) {
            self.runtimeID = runtimeID
            self.cursor = cursor
            self.boundaryMessageID = boundaryMessageID
            self.boundaryTurnID = boundaryTurnID
            self.applied = max(applied ?? cursor, cursor)
            self.showsReplayedHistory = showsReplayedHistory
        }
    }
}

public struct SavedSessionLibrary: Codable, Equatable, Sendable {
    /// Version 2 marks a library holding a remote session. A build that predates remote
    /// sessions ignores `serverID`, so it would reopen a server's path as a folder on this
    /// Mac; the bump makes it refuse the file instead. A library without one stays at 1,
    /// so it remains readable by that build. Version 3 marks one holding the agent's thinking,
    /// a kind of message no earlier build can read: it then says the version is unsupported
    /// rather than that the file is corrupt.
    public static let supportedVersions = 1...3

    public var version: Int
    public var sessions: [SavedSession]
    public var selectedSessionID: UUID?

    public init(version: Int? = nil, sessions: [SavedSession], selectedSessionID: UUID?) {
        self.version = version ?? Self.requiredVersion(for: sessions)
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID
    }

    /// The oldest version able to hold these sessions.
    public static func requiredVersion(for sessions: [SavedSession]) -> Int {
        if sessions.contains(where: { $0.messages.contains { $0.role == .thought } }) { return 3 }
        return sessions.contains { $0.serverID != nil } ? 2 : 1
    }
}

/// Private, local plaintext storage; filesystem permissions are not encryption.
/// A failed load locks out saves until a subsequent explicit load succeeds. Saves also
/// validate the current file, even on a fresh store, to preserve unreadable/future data.
/// One application owner is expected; this is not a cross-process transaction system.
public actor SessionStore {
    public static let defaultDirectory = URL.applicationSupportDirectory.appendingPathComponent("Latch", isDirectory: true)
    public static let maximumFileSize = 128 * 1024 * 1024
    public static let fileName = "sessions.json"

    public enum StoreError: Error, LocalizedError, Equatable {
        case unreadable, corrupt, unsupportedVersion, invalidLibrary, tooLarge
        case saveBlocked, writeFailed

        public var errorDescription: String? {
            switch self {
            case .unreadable: "Saved sessions could not be read."
            case .corrupt: "Saved sessions are not valid session data."
            case .unsupportedVersion: "Saved sessions use an unsupported version."
            case .invalidLibrary: "Saved sessions contain invalid or duplicate identifiers, an unknown agent, or excessive history."
            case .tooLarge: "Saved sessions exceed the storage size limit."
            case .saveBlocked: "Saving is disabled until saved sessions are successfully loaded."
            case .writeFailed: "Saved sessions could not be written."
            }
        }
    }

    private let directory: URL
    private var failedLoad = false

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() throws -> SavedSessionLibrary {
        do {
            let library = try readLibrary()
            failedLoad = false
            return library
        } catch {
            failedLoad = true
            throw error
        }
    }

    public func save(_ library: SavedSessionLibrary) throws {
        guard !failedLoad else { throw StoreError.saveBlocked }
        var library = library
        // Written at the lowest version that holds its sessions: closing the last remote
        // session hands the file back to builds that predate them.
        if SavedSessionLibrary.supportedVersions.contains(library.version) {
            library.version = SavedSessionLibrary.requiredVersion(for: library.sessions)
        }
        try Self.validate(library)
        // Never replace corrupt or unsupported data, including when load was not called.
        do {
            _ = try readLibrary()
        } catch {
            failedLoad = true
            throw error
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(library)
        } catch {
            throw StoreError.invalidLibrary
        }
        guard data.count <= Self.maximumFileSize else { throw StoreError.tooLarge }
        #if os(macOS)
        // Quitting must not land between the temporary file and its rename.
        ProcessInfo.processInfo.disableSuddenTermination()
        defer { ProcessInfo.processInfo.enableSuddenTermination() }
        #endif
        try writeAtomically(data)
    }

    private static func validate(_ library: SavedSessionLibrary) throws {
        guard SavedSessionLibrary.supportedVersions.contains(library.version) else { throw StoreError.unsupportedVersion }
        guard library.version >= SavedSessionLibrary.requiredVersion(for: library.sessions) else {
            throw StoreError.invalidLibrary
        }
        var sessionIDs = Set<UUID>()
        var messageIDs = Set<UUID>()
        for session in library.sessions {
            guard sessionIDs.insert(session.id).inserted,
                  AgentPreset(rawValue: session.agentID) != nil,
                  session.messages.count <= ChatHistory.maximumMessageCount,
                  // Only a session on a server can have left a runtime running there.
                  session.remote.map({ !$0.runtimeID.isEmpty && session.serverID != nil }) ?? true else {
                throw StoreError.invalidLibrary
            }
            var remaining = ChatHistory.maximumTextCount
            for message in session.messages {
                guard messageIDs.insert(message.id).inserted else { throw StoreError.invalidLibrary }
                let count = message.text.count
                guard count <= remaining else { throw StoreError.invalidLibrary }
                remaining -= count
            }
        }
        if let selected = library.selectedSessionID, !sessionIDs.contains(selected) {
            throw StoreError.invalidLibrary
        }
    }

    private func readLibrary() throws -> SavedSessionLibrary {
        let data: Data
        do {
            guard let contents = try PrivateFile.read(Self.fileName, in: directory, maximumSize: Self.maximumFileSize) else {
                return SavedSessionLibrary(sessions: [], selectedSessionID: nil)
            }
            data = contents
        } catch .tooLarge {
            throw StoreError.tooLarge
        } catch {
            throw StoreError.unreadable
        }
        do {
            // Check the schema before decoding its payload: future payloads may differ.
            struct Header: Decodable { let version: Int }
            let decoder = JSONDecoder()
            guard SavedSessionLibrary.supportedVersions.contains(try decoder.decode(Header.self, from: data).version) else {
                throw StoreError.unsupportedVersion
            }
            let library = try decoder.decode(SavedSessionLibrary.self, from: data)
            try Self.validate(library)
            return library
        } catch let error as StoreError {
            throw error
        } catch {
            // Never expose decoder diagnostics, filesystem paths, or saved contents.
            throw StoreError.corrupt
        }
    }

    private func writeAtomically(_ data: Data) throws {
        do {
            try PrivateFile.write(data, as: Self.fileName, in: directory)
        } catch {
            throw StoreError.writeFailed
        }
    }
}
