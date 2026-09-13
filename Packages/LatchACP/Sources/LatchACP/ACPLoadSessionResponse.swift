import Foundation

/// A load result has no session ID: the caller already supplied it in `session/load`.
/// Replay notifications can precede this snapshot; `localSequence` is its trusted
/// wire position, not a boundary for discarding replay transcript content.
public struct ACPLoadSessionResponse: Codable, Equatable, Sendable {
    public let modes: ACPJSONValue?
    public let models: ACPJSONValue?
    public let configOptions: [ACPJSONValue]?
    public let meta: ACPJSONValue?
    public let localSequence: UInt64?

    public init(
        modes: ACPJSONValue? = nil,
        models: ACPJSONValue? = nil,
        configOptions: [ACPJSONValue]? = nil,
        meta: ACPJSONValue? = nil,
        localSequence: UInt64? = nil
    ) {
        self.modes = modes
        self.models = models
        self.configOptions = configOptions
        self.meta = meta
        self.localSequence = localSequence
    }

    private enum CodingKeys: String, CodingKey {
        case modes, models, configOptions, localSequence
        case meta = "_meta"
    }
}
