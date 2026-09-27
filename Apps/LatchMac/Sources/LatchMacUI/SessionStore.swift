import Foundation
import LatchAgentCore

/// Stored as plaintext JSON, including commands, drafts, and transcripts. No credentials,
/// environment, login state, or permission decisions are stored by this model.
struct SavedSession: Codable, Equatable, Sendable {
    var id: UUID
    var workspacePath: String
    var title: String
    var agentID: String
    var customCommand: String
    var draft: String
    var messages: [ChatMessage]
    var agentSessionID: String?
    /// When the conversation last moved: a prompt sent or a turn finished. Absent in sessions
    /// saved before it was kept, which then show no time.
    var lastActiveAt: Date? = nil
    /// The server the session runs on, or nil for this Mac. For a remote session
    /// `workspacePath` is a path on that server, never one on this Mac.
    var serverID: UUID? = nil
}

struct SavedSessionLibrary: Codable, Equatable, Sendable {
    /// Version 2 marks a library holding a remote session. A build that predates remote
    /// sessions ignores `serverID`, so it would reopen a server's path as a folder on this
    /// Mac; the bump makes it refuse the file instead. A library without one stays at 1,
    /// so it remains readable by that build.
    static let supportedVersions = 1...2

    var version: Int
    var sessions: [SavedSession]
    var selectedSessionID: UUID?

    init(version: Int? = nil, sessions: [SavedSession], selectedSessionID: UUID?) {
        self.version = version ?? Self.requiredVersion(for: sessions)
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID
    }

    /// The oldest version able to hold these sessions.
    static func requiredVersion(for sessions: [SavedSession]) -> Int {
        sessions.contains { $0.serverID != nil } ? 2 : 1
    }
}

/// Private, local plaintext storage; filesystem permissions are not encryption.
/// A failed load locks out saves until a subsequent explicit load succeeds. Saves also
/// validate the current file, even on a fresh store, to preserve unreadable/future data.
/// One application owner is expected; this is not a cross-process transaction system.
actor SessionStore {
    static let defaultDirectory = URL.applicationSupportDirectory.appendingPathComponent("Latch", isDirectory: true)
    static let maximumFileSize = 128 * 1024 * 1024
    static let fileName = "sessions.json"

    enum StoreError: Error, LocalizedError, Equatable {
        case unreadable, corrupt, unsupportedVersion, invalidLibrary, tooLarge
        case saveBlocked, writeFailed

        var errorDescription: String? {
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

    init(directory: URL) {
        self.directory = directory
    }

    func load() throws -> SavedSessionLibrary {
        do {
            let library = try readLibrary()
            failedLoad = false
            return library
        } catch {
            failedLoad = true
            throw error
        }
    }

    func save(_ library: SavedSessionLibrary) throws {
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
        // Quitting must not land between the temporary file and its rename.
        ProcessInfo.processInfo.disableSuddenTermination()
        defer { ProcessInfo.processInfo.enableSuddenTermination() }
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
                  session.messages.count <= ChatHistory.maximumMessageCount else {
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
