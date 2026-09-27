import Foundation
import LatchRemoteClient
import LatchRemoteProtocol

/// A `latch-server` this Mac can run sessions on. The token is a shell on that server as its
/// user, so nothing that describes, dumps or logs a profile shows it; only the Add sheet's
/// secure field ever holds it on screen.
struct ServerProfile: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var token: LatchRemoteToken
    /// Lets the token go to an address that is neither this Mac nor on a tailnet.
    var allowUnencryptedNetwork: Bool
    /// The command a Custom agent runs on this server. Empty offers no Custom agent there.
    var customCommand: String

    init(id: UUID = UUID(), name: String, host: String, port: UInt16 = LatchRemoteProtocol.defaultPort,
         token: LatchRemoteToken, allowUnencryptedNetwork: Bool = false, customCommand: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.token = token
        self.allowUnencryptedNetwork = allowUnencryptedNetwork
        self.customCommand = customCommand
    }

    /// `host:port`, with an IPv6 literal bracketed.
    var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    var connectionOptions: LatchRemoteConnectionOptions {
        LatchRemoteConnectionOptions(host: host, port: port, token: token,
                                     allowUnencryptedNetwork: allowUnencryptedNetwork, client: .latchMac)
    }
}

extension ServerProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, token, allowUnencryptedNetwork, customCommand
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let token = LatchRemoteToken(try container.decode(String.self, forKey: .token)) else {
            // Never repeat the value: it may be most of a real token.
            throw DecodingError.dataCorruptedError(forKey: .token, in: container, debugDescription: "Not a Latch token")
        }
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: try container.decode(String.self, forKey: .name),
                  host: try container.decode(String.self, forKey: .host),
                  port: try container.decode(UInt16.self, forKey: .port),
                  token: token,
                  allowUnencryptedNetwork: try container.decodeIfPresent(Bool.self, forKey: .allowUnencryptedNetwork) ?? false,
                  customCommand: try container.decodeIfPresent(String.self, forKey: .customCommand) ?? "")
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(token.rawValue, forKey: .token)
        try container.encode(allowUnencryptedNetwork, forKey: .allowUnencryptedNetwork)
        try container.encode(customCommand, forKey: .customCommand)
    }
}

extension ServerProfile: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ServerProfile(\(name), \(address))" }
    var debugDescription: String { description }
    /// Without this, `dump` would walk into the token.
    var customMirror: Mirror {
        Mirror(self, children: ["id": id, "name": name, "host": host, "port": port,
                                "allowUnencryptedNetwork": allowUnencryptedNetwork, "customCommand": customCommand],
               displayStyle: .struct)
    }
}

extension LatchRemoteClientInfo {
    /// How this app introduces itself to a server.
    static var latchMac: LatchRemoteClientInfo {
        LatchRemoteClientInfo(name: "Latch",
                              version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                              platform: "macOS")
    }
}

/// One handshake with a server and a clean close. Settings' Test Connection and the new
/// remote session's default path both go through this, so tests substitute one stub.
typealias ServerCheck = @Sendable (LatchRemoteConnectionOptions) async throws -> LatchRemoteServerInfo

enum ServerCheckText {
    static let live: ServerCheck = { try await LatchRemoteServerCheck.run($0) }

    /// "hostname · OS · Latch x.y.z"
    static func summary(_ info: LatchRemoteServerInfo) -> String {
        "\(info.hostname) · \(info.os) · Latch \(info.version)"
    }

    /// The failure in plain words. The destination refusal is the one a user can act on
    /// here, so it names the checkbox that changes it.
    static func failure(_ error: any Error) -> String {
        if case let .destinationNotAllowed(address) = error as? LatchRemoteClientError {
            return "Latch did not send the token: \(address) is neither this Mac nor on a Tailscale network. "
                + "Turn on “Allow unencrypted network” for this server to connect anyway."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Where server profiles live. Injected the way `AgentSettings` is: the app uses a private
/// file, tests and smoke runs an in-memory store, so no check reads or writes real servers.
@MainActor
protocol ServerStore: AnyObject {
    var servers: [ServerProfile] { get }
    /// Why saved servers could not be read. While set, nothing is saved over the file.
    var problem: String? { get }
    /// Adds the profile, or replaces the one with its ID.
    func save(_ profile: ServerProfile) throws
    func remove(id: UUID) throws
    /// Reads saved servers again, so a file that could not be read is retried.
    func reload()
}

extension ServerStore {
    func server(id: UUID) -> ServerProfile? { servers.first { $0.id == id } }

    /// Posts `serverStoreDidChange` with this store as the object.
    func broadcast() { NotificationCenter.default.post(name: .serverStoreDidChange, object: self) }
}

extension Notification.Name {
    /// A server was added, changed or removed, so its name, command or existence may differ.
    static let serverStoreDidChange = Notification.Name("LatchServerStoreDidChange")
}

enum ServerStoreError: Error, LocalizedError, Equatable {
    case unreadable, saveBlocked, writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "Saved servers could not be read."
        case .saveBlocked: "Servers cannot be changed until the saved list can be read."
        case .writeFailed: "Servers could not be saved."
        }
    }
}

/// For tests and smoke runs.
@MainActor
final class InMemoryServerStore: ServerStore {
    private(set) var servers: [ServerProfile]
    var problem: String? { nil }

    init(_ servers: [ServerProfile] = []) { self.servers = servers }

    func save(_ profile: ServerProfile) throws {
        if let index = servers.firstIndex(where: { $0.id == profile.id }) { servers[index] = profile }
        else { servers.append(profile) }
        broadcast()
    }

    func remove(id: UUID) throws {
        servers.removeAll { $0.id == id }
        broadcast()
    }

    func reload() {}
}

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
