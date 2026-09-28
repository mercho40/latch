import Foundation

/// A server's bearer token: `latch_` and 32 random bytes in unpadded base64url. Holding it is
/// a shell as the server's user, so it is never logged; `description` is redacted.
public struct LatchRemoteToken: Sendable {
    public static let prefix = "latch_"
    static let byteCount = 32

    public let rawValue: String

    /// Accepts only the canonical form `generate()` produces.
    public init?(_ string: String) {
        guard string.hasPrefix(Self.prefix),
              let bytes = Self.base64URLDecode(String(string.dropFirst(Self.prefix.count))),
              bytes.count == Self.byteCount,
              Self.prefix + Self.base64URLEncode(bytes) == string
        else { return nil }
        rawValue = string
    }

    public static func generate() -> LatchRemoteToken {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return LatchRemoteToken(prefix + base64URLEncode(bytes))!
    }

    /// Compares in time that depends only on the lengths, never on where the strings differ.
    public func matches(_ presented: String) -> Bool {
        Self.constantTimeEquals(Array(rawValue.utf8), Array(presented.utf8))
    }

    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    static func base64URLEncode(_ bytes: [UInt8]) -> String {
        var encoded = Data(bytes).base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while encoded.hasSuffix("=") { encoded.removeLast() }
        return encoded
    }

    static func base64URLDecode(_ string: String) -> [UInt8]? {
        guard string.utf8.allSatisfy({ byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }) else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64).map(Array.init)
    }
}

extension LatchRemoteToken: Equatable {
    public static func == (lhs: LatchRemoteToken, rhs: LatchRemoteToken) -> Bool {
        lhs.matches(rhs.rawValue)
    }
}

extension LatchRemoteToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { Self.prefix + "…" }
    public var debugDescription: String { description }
    /// Without this, `dump` and anything else that reflects would print `rawValue`.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
