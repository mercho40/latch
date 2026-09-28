import Foundation
import LatchServiceProtocol

/// The network protocol between `latch-server` and its clients. Separate from the XPC
/// protocol, whose `LatchServiceProtocolVersion` it never changes.
public enum LatchRemoteProtocol {
    public static let version = 1
    public static let minimumSupported = 1

    /// The longest line after authentication, excluding its newline. An event whose encoding
    /// exceeds `maxEncodedEventBytes` is sent as `omitted` so its frame always fits.
    public static let maxFrameBytes = 8 * 1024 * 1024 + 64 * 1024
    public static let maxEncodedEventBytes = maxFrameBytes - 64 * 1024
    /// The longest line before authentication: room for a hello, nothing more.
    public static let preAuthMaxLineBytes = 16 * 1024

    public static let defaultPort: UInt16 = 7428
    public static let heartbeatSeconds = 15

    /// The highest version both sides speak, or nil when the client's range misses ours.
    public static func negotiate(clientMin: Int, clientMax: Int) -> Int? {
        let highest = min(clientMax, version)
        guard clientMin <= clientMax, highest >= max(clientMin, minimumSupported) else { return nil }
        return highest
    }

    /// `[A-Za-z0-9._-]{1,64}`. Runtime IDs on the network are restricted so they can be
    /// logged and spliced into frames without escaping.
    public static func isValidRuntimeID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }
}

public enum LatchRemoteCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// One frame and its terminating newline, ready to write.
    public static func encodeLine<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    /// Decodes a line returned by `LatchRemoteLineDecoder`, without its newline.
    public static func decode<Value: Decodable>(_ type: Value.Type, fromLine line: Data) throws -> Value {
        try makeDecoder().decode(type, from: line)
    }

    /// The bytes the server journals once per event and later splices into every frame
    /// that carries it; see `LatchRemoteEventFrame.encodedLine`.
    public static func encodeEvent(_ event: LatchRemoteEvent) throws -> Data {
        try makeEncoder().encode(event)
    }
}

extension KeyedDecodingContainer {
    func decodeRuntimeID(forKey key: Key) throws -> AgentRuntimeID {
        try decode(LatchRemoteRuntimeIDCoding.self, forKey: key).wrappedValue
    }
}

extension KeyedEncodingContainer {
    mutating func encodeRuntimeID(_ id: AgentRuntimeID, forKey key: Key) throws {
        try encode(LatchRemoteRuntimeIDCoding(wrappedValue: id), forKey: key)
    }
}

/// Codes a runtime ID as a validated bare string rather than `AgentRuntimeID`'s XPC shape.
@propertyWrapper
public struct LatchRemoteRuntimeIDCoding: Codable, Hashable, Sendable {
    public var wrappedValue: AgentRuntimeID

    public init(wrappedValue: AgentRuntimeID) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard LatchRemoteProtocol.isValidRuntimeID(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid runtime ID"))
        }
        wrappedValue = AgentRuntimeID(value)
    }

    public func encode(to encoder: any Encoder) throws {
        guard LatchRemoteProtocol.isValidRuntimeID(wrappedValue.rawValue) else {
            throw EncodingError.invalidValue(wrappedValue, .init(codingPath: encoder.codingPath, debugDescription: "Invalid runtime ID"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.rawValue)
    }
}
