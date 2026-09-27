#if canImport(Network)
import Foundation
import LatchRemoteProtocol
import Network

/// Decides, once TCP is up and before anything is written, whether the token may go to the peer.
public enum LatchRemoteDestinationPolicy {
    /// The bytes of an IP endpoint's address, or nil for anything else.
    public static func address(of endpoint: NWEndpoint?) -> [UInt8]? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        switch host {
        case let .ipv4(address): return Array(address.rawValue)
        case let .ipv6(address): return Array(address.rawValue)
        case .name: return nil
        @unknown default: return nil
        }
    }

    /// The interface a connected path runs over. A connection's path lists only the one it uses.
    public static func interfaceName(of path: NWPath?) -> String? {
        path?.availableInterfaces.first?.name
    }

    /// Loopback peers always qualify, and tailnet peers when the path runs through a tunnel;
    /// any other peer, or one whose address is unknown, only when the user allowed an
    /// unencrypted network for this server.
    ///
    /// A tailnet address alone proves nothing: with Tailscale down, traffic to `100.64.0.0/10`
    /// follows the default route, and whoever answers there would read the token. Tailscale
    /// on macOS and iOS runs over a `utun` interface, the same rule the server applies to
    /// its own tailnet address.
    public static func mayAuthenticate(peerAddress: [UInt8]?, interfaceName: String?, allowUnencryptedNetwork: Bool) -> Bool {
        if allowUnencryptedNetwork { return true }
        guard let peerAddress, let classification = LatchRemoteAddressPolicy.classify(peerAddress) else { return false }
        switch classification {
        case .loopback: return true
        case .tailnet: return interfaceName?.hasPrefix("utun") == true
        case .unspecified, .other: return false
        }
    }

    /// A numeric form of the address for messages; IPv4-mapped IPv6 prints as IPv4.
    public static func describe(_ address: [UInt8]?) -> String {
        guard let address, let bytes = LatchRemoteAddressPolicy.unmapped(address) else { return "an unknown address" }
        if bytes.count == 4, let ipv4 = IPv4Address(Data(bytes)) { return "\(ipv4)" }
        if let ipv6 = IPv6Address(Data(bytes)) { return "\(ipv6)" }
        return "an unknown address"
    }
}

/// The wait before each reconnect: `initial`, doubling after every failed attempt, capped at `maximum`.
public struct LatchRemoteBackoff: Equatable, Sendable {
    public var initial: Duration
    public var maximum: Duration

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) {
        precondition(initial > .zero && maximum >= initial)
        self.initial = initial
        self.maximum = maximum
    }

    /// The delay after `failures` attempts that did not get connected; 0 is the first retry.
    public func delay(afterFailures failures: Int) -> Duration {
        var delay = initial
        for _ in 0..<max(0, failures) {
            delay *= 2
            if delay >= maximum { return maximum }
        }
        return delay
    }
}

/// Admits each runtime event once: sequences only move forward, and gaps are allowed because
/// the server may drop replayed history or evict what a slow client never read.
struct LatchRemoteSequenceCursor: Equatable, Sendable {
    /// The last admitted sequence; 0 before the first event.
    private(set) var last: UInt64

    init(after last: UInt64 = 0) {
        self.last = last
    }

    mutating func admit(_ sequence: UInt64) -> Bool {
        guard sequence > last else { return false }
        last = sequence
        return true
    }
}
#endif
