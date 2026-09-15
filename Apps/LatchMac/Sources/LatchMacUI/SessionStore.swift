import Darwin
import Foundation

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
}

struct SavedSessionLibrary: Codable, Equatable, Sendable {
    var version: Int = 1
    var sessions: [SavedSession]
    var selectedSessionID: UUID?
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
        guard library.version == 1 else { throw StoreError.unsupportedVersion }
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
        guard directory.isFileURL else { throw StoreError.unreadable }
        let file = directory.appendingPathComponent(Self.fileName)
        // Refuse symlinks and special files; O_NONBLOCK avoids hanging on a FIFO.
        let descriptor = file.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return SavedSessionLibrary(sessions: [], selectedSessionID: nil) }
            throw StoreError.unreadable
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.unreadable
        }
        guard info.st_size >= 0, info.st_size <= Self.maximumFileSize else { throw StoreError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Read at most one byte beyond the limit if the file grows after fstat.
            let count = min(buffer.count, Self.maximumFileSize - data.count + 1)
            let received = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
            if received < 0 {
                if errno == EINTR { continue }
                throw StoreError.unreadable
            }
            if received == 0 { break }
            guard received <= Self.maximumFileSize - data.count else { throw StoreError.tooLarge }
            data.append(contentsOf: buffer.prefix(received))
        }
        do {
            // Check the schema before decoding its payload: future payloads may differ.
            struct Header: Decodable { let version: Int }
            let decoder = JSONDecoder()
            guard try decoder.decode(Header.self, from: data).version == 1 else {
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
        guard directory.isFileURL else { throw StoreError.writeFailed }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StoreError.writeFailed
        }
        let dirFD = directory.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dirFD >= 0 else { throw StoreError.writeFailed }
        defer { Darwin.close(dirFD) }
        guard fchmod(dirFD, 0o700) == 0 else { throw StoreError.writeFailed }

        // Exclusive creation keeps the staging file private from its first byte.
        // A same-directory rename is atomic; errors before rename leave the old file intact.
        let temporaryName = ".sessions-\(UUID().uuidString).tmp"
        let fd = openat(dirFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw StoreError.writeFailed }
        defer {
            Darwin.close(fd)
            unlinkat(dirFD, temporaryName, 0)
        }
        guard fchmod(fd, 0o600) == 0 else { throw StoreError.writeFailed }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw StoreError.writeFailed }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw StoreError.writeFailed }
        guard renameat(dirFD, temporaryName, dirFD, Self.fileName) == 0 else { throw StoreError.writeFailed }
    }
}
