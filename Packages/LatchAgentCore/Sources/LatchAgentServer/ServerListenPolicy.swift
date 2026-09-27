import Foundation
import LatchRemoteProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One address a network interface carries, as `getifaddrs` reports it.
public struct ServerInterfaceAddress: Equatable, Sendable {
    public var name: String
    /// 4 or 16 bytes, network byte order.
    public var address: [UInt8]

    public init(name: String, address: [UInt8]) {
        self.name = name
        self.address = address
    }
}

public enum ServerListenError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)
    case hostName(String)
    case invalidPort(String)

    public var description: String {
        switch self {
        case let .invalid(value): "--listen \(value): expected host:port, such as 127.0.0.1:7428 or [::1]:7428"
        case let .hostName(value): "--listen \(value): use a numeric address; host names are not resolved"
        case let .invalidPort(value): "--listen \(value): the port must be a number from 0 to 65535"
        }
    }
}

/// Which addresses the server may listen on (spec §4.4). The token and everything after it
/// travel in the clear, so by default only this machine and a tailnet, whose traffic
/// WireGuard encrypts, may reach the server.
public enum ServerListenPolicy {
    public static let defaultListen = "127.0.0.1:\(LatchRemoteProtocol.defaultPort)"

    public enum Decision: Equatable, Sendable {
        case allowed
        /// Allowed only because the operator passed `--allow-unencrypted-network`; warn.
        case allowedUnencrypted(String)
        /// A tailnet address that no tunnel interface carries yet; try again shortly.
        case tailnetNotUp(String)
        case refused(String)
    }

    /// Parses `host:port`, `[v6]:port` or `localhost:port`. Only numeric literals are accepted,
    /// through `getaddrinfo` with `AI_NUMERICHOST`, and an IPv4-mapped address becomes IPv4.
    public static func parse(_ value: String) throws(ServerListenError) -> ServerSocketAddress {
        let host: Substring
        let portText: Substring
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"), value[value.index(after: close)...].hasPrefix(":") else {
                throw .invalid(value)
            }
            host = value[value.index(after: value.startIndex)..<close]
            portText = value[value.index(close, offsetBy: 2)...]
            guard host.contains(":") else { throw .invalid(value) }
        } else {
            guard let colon = value.lastIndex(of: ":") else { throw .invalid(value) }
            host = value[..<colon]
            portText = value[value.index(after: colon)...]
            // An unbracketed IPv6 literal cannot be told apart from its port.
            guard !host.contains(":") else { throw .invalid(value) }
        }
        guard (1...5).contains(portText.count), portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = UInt16(portText) else { throw .invalidPort(value) }
        guard !host.isEmpty else { throw .invalid(value) }

        let literal = host == "localhost" ? "127.0.0.1" : String(host)
        // Rejects zones, and dotted forms such as `010.1` that libcs read differently.
        guard let strict = LatchRemoteAddressPolicy.numericAddress(literal),
              let resolved = numericHost(literal), resolved == strict,
              let bytes = LatchRemoteAddressPolicy.unmapped(resolved) else {
            throw literal.contains(where: \.isLetter) && !literal.contains(":") ? .hostName(value) : .invalid(value)
        }
        return ServerSocketAddress(bytes: bytes, port: port)
    }

    /// Decides whether the server may listen on `address`, given the interfaces up now.
    public static func evaluate(
        _ address: ServerSocketAddress,
        allowUnencryptedNetwork: Bool,
        interfaces: [ServerInterfaceAddress],
        tunnelPrefixes: [String] = defaultTunnelPrefixes
    ) -> Decision {
        switch LatchRemoteAddressPolicy.classify(address.bytes) {
        case .loopback:
            return .allowed
        case .tailnet:
            let onTunnel = interfaces.contains { interface in
                LatchRemoteAddressPolicy.unmapped(interface.address) == LatchRemoteAddressPolicy.unmapped(address.bytes)
                    && tunnelPrefixes.contains { interface.name.hasPrefix($0) }
            }
            if onTunnel { return .allowed }
            if allowUnencryptedNetwork {
                return .allowedUnencrypted("\(address) is in a tailnet range but not on a Tailscale interface; traffic to it may not be encrypted")
            }
            return .tailnetNotUp("\(address) is not on a Tailscale interface yet")
        case .unspecified:
            guard allowUnencryptedNetwork else {
                return .refused("\(address) listens on every interface; pass --allow-unencrypted-network to allow it")
            }
            return .allowedUnencrypted("\(address) listens on every interface; the token and all traffic can cross the network unencrypted")
        case .other, nil:
            guard allowUnencryptedNetwork else {
                return .refused("\(address) is neither loopback nor a Tailscale address; pass --allow-unencrypted-network to allow it")
            }
            return .allowedUnencrypted("\(address) is neither loopback nor a Tailscale address; the token and all traffic cross the network unencrypted")
        }
    }

    /// Tailscale's interfaces: `tailscale0` on Linux, a `utun` device on macOS.
    #if os(macOS)
    public static let defaultTunnelPrefixes = ["utun"]
    #else
    public static let defaultTunnelPrefixes = ["tailscale"]
    #endif

    /// Every IPv4 and IPv6 address on this machine's interfaces.
    public static func systemInterfaces() -> [ServerInterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [ServerInterfaceAddress] = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, let name = entry.pointee.ifa_name else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                result.append(ServerInterfaceAddress(name: String(cString: name), address: withUnsafeBytes(of: ip) { Array($0) }))
            case AF_INET6:
                let ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                result.append(ServerInterfaceAddress(name: String(cString: name), address: withUnsafeBytes(of: ip) { Array($0) }))
            default:
                continue
            }
        }
        return result
    }

    private static func numericHost(_ literal: String) -> [UInt8]? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_PASSIVE
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = ServerSocket.streamType
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(literal, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let address = info.pointee.ai_addr else { return nil }
        switch info.pointee.ai_family {
        case AF_INET:
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            return withUnsafeBytes(of: ip) { Array($0) }
        case AF_INET6:
            let ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            return withUnsafeBytes(of: ip) { Array($0) }
        default:
            return nil
        }
    }
}
