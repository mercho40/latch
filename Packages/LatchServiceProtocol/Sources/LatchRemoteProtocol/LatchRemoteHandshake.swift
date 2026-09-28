import Foundation

// The handshake shapes are frozen across protocol versions, so any server can at least tell any
// client why it will not talk to it. Unknown keys are ignored.

public struct LatchRemoteVersionRange: Codable, Equatable, Sendable {
    public var min: Int
    public var max: Int

    public init(min: Int, max: Int) {
        self.min = min
        self.max = max
    }

    public static let supported = LatchRemoteVersionRange(
        min: LatchRemoteProtocol.minimumSupported,
        max: LatchRemoteProtocol.version
    )
}

public struct LatchRemoteClientInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var platform: String

    public init(name: String, version: String, platform: String) {
        self.name = name
        self.version = version
        self.platform = platform
    }
}

public struct LatchRemoteServerInfo: Codable, Equatable, Sendable {
    public var version: String
    public var hostname: String
    public var os: String
    public var arch: String
    /// The server user's home directory, the default for a new remote workspace.
    public var home: String

    public init(version: String, hostname: String, os: String, arch: String, home: String) {
        self.version = version
        self.hostname = hostname
        self.os = os
        self.arch = arch
        self.home = home
    }
}

/// The first frame a client sends. Never log it: it carries the token.
public struct LatchRemoteHello: Codable, Equatable, Sendable {
    public var protocolRange: LatchRemoteVersionRange
    public var token: String
    public var client: LatchRemoteClientInfo

    public init(
        protocolRange: LatchRemoteVersionRange = .supported,
        token: String,
        client: LatchRemoteClientInfo
    ) {
        self.protocolRange = protocolRange
        self.token = token
        self.client = client
    }

    /// The server's only decoder before authentication; it never reaches the general frame decoder.
    public static func decode(line: Data) throws -> LatchRemoteHello {
        try LatchRemoteCoding.decode(LatchRemoteHello.self, fromLine: line)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolRange = "protocol"
        case token
        case client
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.expectFrameType("hello", forKey: .type)
        protocolRange = try container.decode(LatchRemoteVersionRange.self, forKey: .protocolRange)
        token = try container.decode(String.self, forKey: .token)
        client = try container.decode(LatchRemoteClientInfo.self, forKey: .client)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("hello", forKey: .type)
        try container.encode(protocolRange, forKey: .protocolRange)
        try container.encode(token, forKey: .token)
        try container.encode(client, forKey: .client)
    }
}

extension LatchRemoteHello: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "LatchRemoteHello(protocol: \(protocolRange.min)...\(protocolRange.max), client: \(client.name) \(client.version))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["protocolRange": protocolRange, "client": client], displayStyle: .struct)
    }
}

public struct LatchRemoteWelcome: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var server: LatchRemoteServerInfo
    public var heartbeatSeconds: Int
    public var maxFrameBytes: Int

    public init(
        protocolVersion: Int,
        server: LatchRemoteServerInfo,
        heartbeatSeconds: Int = LatchRemoteProtocol.heartbeatSeconds,
        maxFrameBytes: Int = LatchRemoteProtocol.maxFrameBytes
    ) {
        self.protocolVersion = protocolVersion
        self.server = server
        self.heartbeatSeconds = heartbeatSeconds
        self.maxFrameBytes = maxFrameBytes
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case server
        case heartbeatSeconds
        case maxFrameBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.expectFrameType("welcome", forKey: .type)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        server = try container.decode(LatchRemoteServerInfo.self, forKey: .server)
        heartbeatSeconds = try container.decode(Int.self, forKey: .heartbeatSeconds)
        maxFrameBytes = try container.decode(Int.self, forKey: .maxFrameBytes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("welcome", forKey: .type)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(server, forKey: .server)
        try container.encode(heartbeatSeconds, forKey: .heartbeatSeconds)
        try container.encode(maxFrameBytes, forKey: .maxFrameBytes)
    }
}

/// Why the server refused a hello. Open: a newer server may send reasons this client does not know.
public struct LatchRemoteRejectReason: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let unauthorized = LatchRemoteRejectReason(rawValue: "unauthorized")
    public static let protocolMismatch = LatchRemoteRejectReason(rawValue: "protocolMismatch")
    public static let busy = LatchRemoteRejectReason(rawValue: "busy")
}

/// Sent instead of a welcome, then the server closes. `supported` is only sent after the
/// token checked out, so version ranges are never revealed before authentication.
public struct LatchRemoteRejected: Codable, Equatable, Sendable {
    public var reason: LatchRemoteRejectReason
    public var message: String
    public var supported: LatchRemoteVersionRange?

    public init(reason: LatchRemoteRejectReason, message: String, supported: LatchRemoteVersionRange? = nil) {
        self.reason = reason
        self.message = message
        self.supported = supported
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case reason
        case message
        case supported
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.expectFrameType("rejected", forKey: .type)
        reason = try container.decode(LatchRemoteRejectReason.self, forKey: .reason)
        message = try container.decode(String.self, forKey: .message)
        supported = try container.decodeIfPresent(LatchRemoteVersionRange.self, forKey: .supported)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("rejected", forKey: .type)
        try container.encode(reason, forKey: .reason)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(supported, forKey: .supported)
    }
}

extension KeyedDecodingContainer {
    func expectFrameType(_ expected: String, forKey key: Key) throws {
        let type = try decode(String.self, forKey: key)
        guard type == expected else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected a \(expected) frame, not \(type)")
        }
    }
}
