import Foundation
import LatchACP

/// What a turn's prompt carried besides its text. Image bytes are never sent back.
public struct LatchRemoteAttachmentSummary: Codable, Equatable, Sendable {
    /// The prompt block kind, such as `image` or `resourceLink`.
    public var kind: String
    public var mimeType: String?
    public var name: String?
    public var byteCount: Int

    public init(kind: String, mimeType: String? = nil, name: String? = nil, byteCount: Int) {
        self.kind = kind
        self.mimeType = mimeType
        self.name = name
        self.byteCount = byteCount
    }
}

/// Which set-* command produced a `configurationSet`. Open, like every server-chosen string.
public struct LatchRemoteConfigurationRoute: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let config = LatchRemoteConfigurationRoute(rawValue: "config")
    public static let model = LatchRemoteConfigurationRoute(rawValue: "model")
    public static let mode = LatchRemoteConfigurationRoute(rawValue: "mode")
}

/// A successful set-* command, published so other viewers and reattaching clients learn it.
public struct LatchRemoteConfigurationSet: Codable, Equatable, Sendable {
    public var route: LatchRemoteConfigurationRoute
    /// Only for the `config` route.
    public var configID: String?
    public var value: String
    /// The ACP `localSequence` of the reply, for ordering against session updates.
    public var acpSequence: UInt64?
    /// The agent's full option list after a `config` set.
    public var configOptions: [ACPJSONValue]?

    public init(
        route: LatchRemoteConfigurationRoute,
        configID: String? = nil,
        value: String,
        acpSequence: UInt64? = nil,
        configOptions: [ACPJSONValue]? = nil
    ) {
        self.route = route
        self.configID = configID
        self.value = value
        self.acpSequence = acpSequence
        self.configOptions = configOptions
    }
}

public struct LatchRemoteExit: Codable, Equatable, Sendable {
    /// Nil when the runtime ended without an exit status, such as a failed launch.
    public var status: Int32?
    /// Whether a client stopped it, rather than the agent exiting on its own.
    public var stopped: Bool

    public init(status: Int32?, stopped: Bool) {
        self.status = status
        self.stopped = stopped
    }
}

/// One journaled event of a runtime, keyed by `kind`. Decoding never fails on content: an
/// unknown kind, or a known kind whose body does not decode, becomes `.unknown` so a client
/// still advances its cursor past it.
public enum LatchRemoteEvent: Equatable, Sendable {
    /// `replay` marks history the agent replayed when a client loaded its session. The client
    /// that loaded it already shows it; one that takes up the runtime without a transcript,
    /// from the start of its journal, shows it as the conversation so far. Its `localSequence`
    /// is at or below the record's `loadedThrough`, which is how older clients skip it.
    case sessionUpdate(notification: ACPSessionNotification, replay: Bool = false)
    /// Clients answer with `resolvePermission`.
    case permissionRequested(requestID: UUID, request: ACPPermissionRequest)
    case permissionClosed(requestID: UUID)
    case turnStarted(turnID: UUID, text: String, attachments: [LatchRemoteAttachmentSummary])
    /// Can precede the turn's last few `sessionUpdate`s; clients keep appending after it.
    case turnEnded(turnID: UUID, stopReason: String?, error: LatchRemoteError?)
    case configurationSet(LatchRemoteConfigurationSet)
    /// The last event of a runtime.
    case exited(LatchRemoteExit)
    /// Stands in for an event too large for a frame.
    case omitted(originalKind: String, byteCount: Int)
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .sessionUpdate: "sessionUpdate"
        case .permissionRequested: "permissionRequested"
        case .permissionClosed: "permissionClosed"
        case .turnStarted: "turnStarted"
        case .turnEnded: "turnEnded"
        case .configurationSet: "configurationSet"
        case .exited: "exited"
        case .omitted: "omitted"
        case let .unknown(kind): kind
        }
    }
}

extension LatchRemoteEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, notification, replay, requestID, request, turnID, text, attachments, stopReason, error
        case originalKind, byteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        do {
            self = try Self.decodeBody(kind: kind, from: container, decoder: decoder)
        } catch {
            self = .unknown(kind: kind)
        }
    }

    private static func decodeBody(
        kind: String,
        from container: KeyedDecodingContainer<CodingKeys>,
        decoder: any Decoder
    ) throws -> LatchRemoteEvent {
        switch kind {
        case "sessionUpdate":
            return .sessionUpdate(
                notification: try container.decode(ACPSessionNotification.self, forKey: .notification),
                replay: try container.decodeIfPresent(Bool.self, forKey: .replay) ?? false
            )
        case "permissionRequested":
            return .permissionRequested(
                requestID: try container.decode(UUID.self, forKey: .requestID),
                request: try container.decode(ACPPermissionRequest.self, forKey: .request)
            )
        case "permissionClosed":
            return .permissionClosed(requestID: try container.decode(UUID.self, forKey: .requestID))
        case "turnStarted":
            return .turnStarted(
                turnID: try container.decode(UUID.self, forKey: .turnID),
                text: try container.decode(String.self, forKey: .text),
                attachments: try container.decode([LatchRemoteAttachmentSummary].self, forKey: .attachments)
            )
        case "turnEnded":
            return .turnEnded(
                turnID: try container.decode(UUID.self, forKey: .turnID),
                stopReason: try container.decodeIfPresent(String.self, forKey: .stopReason),
                error: try container.decodeIfPresent(LatchRemoteError.self, forKey: .error)
            )
        case "configurationSet":
            return .configurationSet(try LatchRemoteConfigurationSet(from: decoder))
        case "exited":
            return .exited(try LatchRemoteExit(from: decoder))
        case "omitted":
            return .omitted(
                originalKind: try container.decode(String.self, forKey: .originalKind),
                byteCount: try container.decode(Int.self, forKey: .byteCount)
            )
        default:
            return .unknown(kind: kind)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch self {
        case let .sessionUpdate(notification, replay):
            try container.encode(notification, forKey: .notification)
            // Left out unless set, so live updates keep the shape every client knows.
            if replay { try container.encode(true, forKey: .replay) }
        case let .permissionRequested(requestID, request):
            try container.encode(requestID, forKey: .requestID)
            try container.encode(request, forKey: .request)
        case let .permissionClosed(requestID):
            try container.encode(requestID, forKey: .requestID)
        case let .turnStarted(turnID, text, attachments):
            try container.encode(turnID, forKey: .turnID)
            try container.encode(text, forKey: .text)
            try container.encode(attachments, forKey: .attachments)
        case let .turnEnded(turnID, stopReason, error):
            try container.encode(turnID, forKey: .turnID)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
            try container.encodeIfPresent(error, forKey: .error)
        // These share the event object with `kind` rather than nesting.
        case let .configurationSet(configuration):
            try configuration.encode(to: encoder)
        case let .exited(exit):
            try exit.encode(to: encoder)
        case let .omitted(originalKind, byteCount):
            try container.encode(originalKind, forKey: .originalKind)
            try container.encode(byteCount, forKey: .byteCount)
        case .unknown:
            break
        }
    }
}
