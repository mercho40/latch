import Foundation
import LatchRemoteClient
import LatchRemoteProtocol

/// A `latch-server` this Mac can run sessions on. The token is a shell on that server as its
/// user, so nothing that describes, dumps or logs a profile shows it; only the server sheet's
/// secure fields ever hold it on screen.
public struct ServerProfile: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    /// Straight to the server, or through a TLS proxy such as a Cloudflare Tunnel.
    public var transport: LatchRemoteTransport {
        didSet { if transport != .tcp { allowUnencryptedNetwork = false } }
    }
    public var token: LatchRemoteToken
    /// Lets the token go to an address that is neither this Mac nor on a tailnet. Only TCP
    /// needs it, and only TCP keeps it: a WebSocket is always over TLS, and an older Latch
    /// that reads the profile as TCP must not send the token in the clear.
    public var allowUnencryptedNetwork: Bool {
        didSet { if transport != .tcp { allowUnencryptedNetwork = false } }
    }
    /// The command a Custom agent runs on this server. Empty offers no Custom agent there.
    public var customCommand: String

    public init(id: UUID = UUID(), name: String, host: String, port: UInt16? = nil, transport: LatchRemoteTransport = .tcp,
                token: LatchRemoteToken, allowUnencryptedNetwork: Bool = false, customCommand: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.port = port ?? transport.defaultPort
        self.transport = transport
        self.token = token
        self.allowUnencryptedNetwork = transport == .tcp && allowUnencryptedNetwork
        self.customCommand = customCommand
    }

    /// `host:port`, with an IPv6 literal bracketed; through a TLS proxy, `wss://host`, and
    /// the port only when it is not 443.
    public var address: String {
        Self.address(host: host, port: port, transport: transport)
    }

    public static func address(host: String, port: UInt16, transport: LatchRemoteTransport) -> String {
        let host = host.contains(":") ? "[\(host)]" : host
        switch transport {
        case .tcp: return "\(host):\(port)"
        case .webSocket: return port == transport.defaultPort ? "wss://\(host)" : "wss://\(host):\(port)"
        }
    }

    public var connectionOptions: LatchRemoteConnectionOptions {
        LatchRemoteConnectionOptions(host: host, port: port, transport: transport, token: token,
                                     allowUnencryptedNetwork: allowUnencryptedNetwork, client: .latchApp)
    }

    /// Whether a connection made with `other` would go to the same place the same way. A new
    /// name or custom command changes nothing about a connection already made.
    public func connects(like other: ServerProfile) -> Bool {
        host == other.host && port == other.port && transport == other.transport && token == other.token
            && allowUnencryptedNetwork == other.allowUnencryptedNetwork
    }
}

extension ServerProfile: Codable {
    private enum TokenKey: String, CodingKey {
        case token
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TokenKey.self)
        guard let token = LatchRemoteToken(try container.decode(String.self, forKey: .token)) else {
            // Never repeat the value: it may be most of a real token.
            throw DecodingError.dataCorruptedError(forKey: .token, in: container, debugDescription: "Not a Latch token")
        }
        self = try Stored(from: decoder).profile(token: token)
    }

    public func encode(to encoder: any Encoder) throws {
        try Stored(self).encode(to: encoder)
        var container = encoder.container(keyedBy: TokenKey.self)
        try container.encode(token.rawValue, forKey: .token)
    }

    /// Everything but the token, for a store that keeps tokens apart, as in a keychain. The
    /// whole profile's form is this one's with a `token` key, so both read the same files alike.
    public struct Stored: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var host: String
        public var port: UInt16
        public var transport: LatchRemoteTransport
        public var allowUnencryptedNetwork: Bool
        public var customCommand: String

        public init(_ profile: ServerProfile) {
            id = profile.id
            name = profile.name
            host = profile.host
            port = profile.port
            transport = profile.transport
            allowUnencryptedNetwork = profile.allowUnencryptedNetwork
            customCommand = profile.customCommand
        }

        public func profile(token: LatchRemoteToken) -> ServerProfile {
            ServerProfile(id: id, name: name, host: host, port: port, transport: transport, token: token,
                          allowUnencryptedNetwork: allowUnencryptedNetwork, customCommand: customCommand)
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, host, port, transport, allowUnencryptedNetwork, customCommand
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            host = try container.decode(String.self, forKey: .host)
            port = try container.decode(UInt16.self, forKey: .port)
            // A transport from a newer Latch reads as TCP, which then sends the token nowhere the
            // destination check refuses, rather than leaving the whole list unreadable.
            transport = (try? container.decodeIfPresent(LatchRemoteTransport.self, forKey: .transport)) ?? .tcp
            allowUnencryptedNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowUnencryptedNetwork) ?? false
            customCommand = try container.decodeIfPresent(String.self, forKey: .customCommand) ?? ""
        }
    }
}

extension ServerProfile: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ServerProfile(\(name), \(address))" }
    public var debugDescription: String { description }
    /// Without this, `dump` would walk into the token.
    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "name": name, "host": host, "port": port, "transport": transport,
                                "allowUnencryptedNetwork": allowUnencryptedNetwork, "customCommand": customCommand],
               displayStyle: .struct)
    }
}

extension LatchRemoteClientInfo {
    /// How this app introduces itself to a server.
    static var latchApp: LatchRemoteClientInfo {
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        return LatchRemoteClientInfo(name: "Latch",
                                     version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                                     platform: platform)
    }
}

/// How Latch's messages name the device it runs on, where its servers are edited, and the
/// list that holds them.
#if os(iOS)
let thisDevice = "this device"
let serversPlace = "Servers"
let serversList = "Servers"
#else
let thisDevice = "this Mac"
let serversPlace = "Settings → Servers"
let serversList = "Settings"
#endif

/// One handshake with a server and a clean close. Settings' Test Connection and the new
/// remote session's default path both go through this, so tests substitute one stub.
public typealias ServerCheck = @Sendable (LatchRemoteConnectionOptions) async throws -> LatchRemoteServerInfo

public enum ServerCheckText {
    public static let live: ServerCheck = { try await LatchRemoteServerCheck.run($0) }

    /// "hostname · OS · Latch x.y.z"
    public static func summary(_ info: LatchRemoteServerInfo) -> String {
        "\(info.hostname) · \(info.os) · Latch \(info.version)"
    }

    /// The failure in plain words. The destination refusal is the one a user can act on
    /// here, so it names the checkbox that changes it, unless the server came from a link,
    /// which anyone can make: then it asks for the host and Tailscale to be checked instead.
    public static func failure(_ error: any Error, offeringUnencryptedNetwork: Bool = true) -> String {
        if case let .destinationNotAllowed(address) = error as? LatchRemoteClientError {
            return "Latch did not send the token: \(address) is neither \(thisDevice) nor on a Tailscale network. "
                + (offeringUnencryptedNetwork
                    ? "Turn on “Allow unencrypted network” for this server to connect anyway."
                    : "Check the host, and that Tailscale is connected.")
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Where server profiles live. Injected the way `AgentSettings` is: the app uses a private
/// file, tests and smoke runs an in-memory store, so no check reads or writes real servers.
@MainActor
public protocol ServerStore: AnyObject {
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
    public func server(id: UUID) -> ServerProfile? { servers.first { $0.id == id } }

    /// Posts `serverStoreDidChange` with this store as the object.
    public func broadcast() { NotificationCenter.default.post(name: .serverStoreDidChange, object: self) }
}

extension Notification.Name {
    /// A server was added, changed or removed, so its name, command or existence may differ.
    public static let serverStoreDidChange = Notification.Name("LatchServerStoreDidChange")
}

public enum ServerStoreError: Error, LocalizedError, Equatable {
    case unreadable, saveBlocked, writeFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: "Saved servers could not be read."
        case .saveBlocked: "Servers cannot be changed until the saved list can be read."
        case .writeFailed: "Servers could not be saved."
        }
    }
}

/// For tests and smoke runs.
@MainActor
public final class InMemoryServerStore: ServerStore {
    public private(set) var servers: [ServerProfile]
    public var problem: String? { nil }

    public init(_ servers: [ServerProfile] = []) { self.servers = servers }

    public func save(_ profile: ServerProfile) throws {
        if let index = servers.firstIndex(where: { $0.id == profile.id }) { servers[index] = profile }
        else { servers.append(profile) }
        broadcast()
    }

    public func remove(id: UUID) throws {
        servers.removeAll { $0.id == id }
        broadcast()
    }

    public func reload() {}
}
