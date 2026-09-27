import Foundation
import LatchSessionKit

/// `servers.json` beside the saved sessions, 0600 from the moment it exists. Not the
/// Keychain: an ad-hoc signed app is a new identity after every update, and each would
/// prompt for every token again.
@MainActor
final class FileServerStore: ServerStore {
    static let shared = FileServerStore(directory: SessionStore.defaultDirectory)
    static let fileName = "servers.json"
    static let maximumFileSize = 1024 * 1024

    private struct Library: Codable {
        var version = 1
        var servers: [ServerProfile]
    }

    private let directory: URL
    /// Read on first use, so a window that never asks never touches the file.
    private var loaded: [ServerProfile]?
    private(set) var problem: String?

    init(directory: URL) { self.directory = directory }

    var servers: [ServerProfile] {
        if loaded == nil { load() }
        return loaded ?? []
    }

    func save(_ profile: ServerProfile) throws {
        // Retried before the list is built from it, so a file readable again is kept whole.
        reload()
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        try write(updated)
    }

    func remove(id: UUID) throws {
        reload()
        try write(servers.filter { $0.id != id })
    }

    /// Only a failed read is worth repeating: a list that was read is already current, since
    /// nothing but this store writes the file.
    func reload() {
        guard problem != nil else { return }
        loaded = nil
        load()
        if problem == nil { broadcast() }
    }

    private func load() {
        do {
            guard let data = try PrivateFile.read(Self.fileName, in: directory, maximumSize: Self.maximumFileSize) else {
                loaded = []
                return
            }
            let library = try JSONDecoder().decode(Library.self, from: data)
            guard library.version == 1 else { throw ServerStoreError.unreadable }
            loaded = library.servers
            problem = nil
        } catch {
            // Never expose decoder diagnostics: they can quote the file, token included.
            loaded = []
            let path = directory.appendingPathComponent(Self.fileName).path
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            problem = "Saved servers in \(path) could not be read."
        }
    }

    private func write(_ servers: [ServerProfile]) throws {
        _ = self.servers
        guard problem == nil else { throw ServerStoreError.saveBlocked }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            data = try encoder.encode(Library(servers: servers))
        } catch {
            throw ServerStoreError.writeFailed
        }
        do {
            try PrivateFile.write(data, as: Self.fileName, in: directory)
        } catch {
            throw ServerStoreError.writeFailed
        }
        loaded = servers
        broadcast()
    }
}
