import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Where a token may be sent without the user opting into an unencrypted network: to this
/// machine, or across a tailnet, whose traffic WireGuard encrypts. The server uses the same
/// classes to decide which addresses it may listen on.
public enum LatchRemoteAddressPolicy {
    public enum Classification: Equatable, Sendable {
        case loopback
        /// Tailscale's ranges, `100.64.0.0/10` and `fd7a:115c:a1e0::/48`.
        case tailnet
        /// `0.0.0.0` or `::`, which is never a destination and never a safe listen address.
        case unspecified
        case other
    }

    /// Classifies an IPv4 (4 bytes) or IPv6 (16 bytes) address in network byte order; nil for
    /// any other length. An IPv4-mapped IPv6 address is classified as its IPv4 address.
    public static func classify<Bytes: Collection<UInt8>>(_ address: Bytes) -> Classification? {
        guard let bytes = unmapped(Array(address)) else { return nil }
        if bytes.count == 4 {
            if bytes == [0, 0, 0, 0] { return .unspecified }
            if bytes[0] == 127 { return .loopback }
            if bytes[0] == 100, bytes[1] & 0xC0 == 64 { return .tailnet }
            return .other
        }
        if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return .loopback }
        if bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) { return .tailnet }
        return .other
    }

    /// The address as 4 bytes when it is IPv4 or IPv4-mapped IPv6, else unchanged.
    public static func unmapped(_ address: [UInt8]) -> [UInt8]? {
        switch address.count {
        case 4:
            return address
        case 16:
            let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
            return address.starts(with: mappedPrefix) ? Array(address[12...]) : address
        default:
            return nil
        }
    }

    /// Parses a numeric IPv4 or IPv6 literal (without brackets or a zone) into its bytes.
    /// Host names are rejected, never resolved.
    public static func numericAddress(_ string: String) -> [UInt8]? {
        // Darwin's inet_pton accepts a `%zone` suffix and folds it into the address bytes.
        guard string.utf8.allSatisfy({ $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: ".") || $0.isHexDigit }) else {
            return nil
        }
        // Darwin's inet_pton reads `010` as decimal where glibc rejects it and inet_aton reads
        // octal, so the same string could name different hosts; accept no leading zeros.
        if let dotted = string.split(separator: ":", omittingEmptySubsequences: false).last, dotted.contains(".") {
            guard dotted.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ $0.count < 2 || $0.first != "0" }) else {
                return nil
            }
        }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, string, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { Array($0) }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, string, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { Array($0) }
        }
        return nil
    }

    /// Classifies a numeric literal; nil for anything that is not one, including host names.
    public static func classify(numericHost: String) -> Classification? {
        numericAddress(numericHost).flatMap(classify)
    }
}

private extension UInt8 {
    var isHexDigit: Bool {
        switch self {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"), UInt8(ascii: "A")...UInt8(ascii: "F"):
            true
        default:
            false
        }
    }
}
