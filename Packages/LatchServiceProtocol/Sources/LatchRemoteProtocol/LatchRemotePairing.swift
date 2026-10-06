import Foundation

public enum LatchRemotePairingError: Error, Equatable, Sendable {
    case invalidScheme
    case invalidHost
    case invalidPort
    case missingToken
    case invalidToken
    /// A `transport` this version of Latch does not know, or one given twice.
    case unsupportedTransport
}

/// How a client reaches a server.
public enum LatchRemoteTransport: String, Codable, Hashable, Sendable, CaseIterable {
    /// The stream over TCP, straight to the server; encryption comes from the network path,
    /// such as a tailnet or an SSH tunnel.
    case tcp
    /// The same stream inside a WebSocket over TLS, to a proxy that forwards it to the
    /// server's loopback address, such as a Cloudflare Tunnel. The system's trust store checks
    /// the proxy's certificate before the token is sent.
    case webSocket = "wss"

    public var defaultPort: UInt16 {
        switch self {
        case .tcp: LatchRemoteProtocol.defaultPort
        case .webSocket: 443
        }
    }
}

/// The `latch://host:port?token=…` string `latch-server pair` prints for pasting into the app,
/// with `transport=wss` before the token for a server behind a TLS proxy.
public struct LatchRemotePairing: Equatable, Sendable {
    static let scheme = "latch://"

    /// A host name or a numeric address; IPv6 without brackets.
    public let host: String
    public let port: UInt16
    public let transport: LatchRemoteTransport
    public let token: LatchRemoteToken

    public init(host: String, port: UInt16? = nil, transport: LatchRemoteTransport = .tcp, token: LatchRemoteToken) throws {
        guard Self.isValidHost(host) else { throw LatchRemotePairingError.invalidHost }
        let port = port ?? transport.defaultPort
        guard port > 0 else { throw LatchRemotePairingError.invalidPort }
        self.host = host
        self.port = port
        self.transport = transport
        self.token = token
    }

    /// Parses a pasted string; surrounding whitespace is ignored and a missing port means
    /// the transport's default one.
    public init(parsing input: String) throws {
        let string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard string.prefix(Self.scheme.count).lowercased() == Self.scheme else { throw LatchRemotePairingError.invalidScheme }
        let remainder = string.dropFirst(Self.scheme.count)
        let queryStart = remainder.firstIndex(of: "?")
        var authority = remainder[..<(queryStart ?? remainder.endIndex)]
        if authority.hasSuffix("/") { authority = authority.dropLast() }

        let host: Substring
        let portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw LatchRemotePairingError.invalidHost }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let rest = authority[authority.index(after: close)...]
            guard host.contains(":") else { throw LatchRemotePairingError.invalidHost }
            if rest.isEmpty {
                portText = nil
            } else {
                guard rest.hasPrefix(":") else { throw LatchRemotePairingError.invalidHost }
                portText = rest.dropFirst()
            }
        } else if let colon = authority.firstIndex(of: ":") {
            // An unbracketed IPv6 literal cannot be told apart from its port.
            guard authority.lastIndex(of: ":") == colon else { throw LatchRemotePairingError.invalidHost }
            host = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        } else {
            host = authority
            portText = nil
        }

        guard Self.isValidHost(String(host)) else { throw LatchRemotePairingError.invalidHost }
        var port: UInt16?
        if let portText {
            guard (1...5).contains(portText.count), portText.allSatisfy(\.isASCIIDigit),
                  let value = UInt16(portText) else { throw LatchRemotePairingError.invalidPort }
            port = value
        }

        var token: LatchRemoteToken?
        var transport: LatchRemoteTransport?
        if let queryStart {
            for parameter in remainder[remainder.index(after: queryStart)...].split(separator: "&") {
                if parameter.hasPrefix("transport=") {
                    guard transport == nil,
                          let parsed = LatchRemoteTransport(rawValue: String(parameter.dropFirst("transport=".count)).lowercased()) else {
                        throw LatchRemotePairingError.unsupportedTransport
                    }
                    transport = parsed
                }
                guard parameter.hasPrefix("token=") else { continue }
                guard token == nil else { throw LatchRemotePairingError.invalidToken }
                guard let parsed = LatchRemoteToken(String(parameter.dropFirst("token=".count))) else {
                    throw LatchRemotePairingError.invalidToken
                }
                token = parsed
            }
        }
        guard let token else { throw LatchRemotePairingError.missingToken }
        try self.init(host: String(host), port: port, transport: transport ?? .tcp, token: token)
    }

    public var string: String {
        let authority = host.contains(":") ? "[\(host)]" : host
        let transport = transport == .tcp ? "" : "transport=\(self.transport.rawValue)&"
        return "\(Self.scheme)\(authority):\(port)?\(transport)token=\(token.rawValue)"
    }

    /// A DNS name of letters, digits and hyphens, or a numeric IPv4 or IPv6 address.
    static func isValidHost(_ host: String) -> Bool {
        if host.contains(":") {
            return LatchRemoteAddressPolicy.numericAddress(host)?.count == 16
        }
        guard (1...253).contains(host.utf8.count) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count)
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
