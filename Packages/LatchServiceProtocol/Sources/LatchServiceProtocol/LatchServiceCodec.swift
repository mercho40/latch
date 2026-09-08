import Foundation

public enum LatchServiceCodecError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge(maximumBytes: Int, actualBytes: Int)
    case malformedPayload
}

/// JSON encoding with a payload byte limit for service messages carried as `Data`.
///
/// Decoding checks size before parsing; encoding checks after JSON allocation.
/// This codec does not provide socket framing or validate protocol versions.
public struct LatchServiceCodec: Sendable {
    public static let defaultMaximumPayloadSize = 1_048_576

    public let maximumPayloadSize: Int

    public init(maximumPayloadSize: Int = Self.defaultMaximumPayloadSize) {
        precondition(maximumPayloadSize > 0)
        self.maximumPayloadSize = maximumPayloadSize
    }

    public func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try validateSize(data)
        return data
    }

    public func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        guard !data.isEmpty else {
            throw LatchServiceCodecError.emptyPayload
        }
        try validateSize(data)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LatchServiceCodecError.malformedPayload
        }
    }

    private func validateSize(_ data: Data) throws {
        guard data.count <= maximumPayloadSize else {
            throw LatchServiceCodecError.payloadTooLarge(
                maximumBytes: maximumPayloadSize,
                actualBytes: data.count
            )
        }
    }
}
