import Foundation
import LatchServiceProtocol

public struct LatchRemoteRequest: Equatable, Sendable {
    public var id: UUID
    public var command: LatchRemoteCommand

    public init(id: UUID = UUID(), command: LatchRemoteCommand) {
        self.id = id
        self.command = command
    }
}

public enum LatchRemoteReplyResult: Equatable, Sendable {
    case success(LatchRemoteResponse)
    case failure(LatchRemoteError)
}

public struct LatchRemoteReply: Equatable, Sendable {
    public var id: UUID
    public var result: LatchRemoteReplyResult

    public init(id: UUID, result: LatchRemoteReplyResult) {
        self.id = id
        self.result = result
    }
}

public struct LatchRemoteEventFrame: Equatable, Sendable {
    public var runtimeID: AgentRuntimeID
    /// Per runtime, from 1, strictly increasing; a client may see gaps but never repeats.
    public var sequence: UInt64
    public var event: LatchRemoteEvent
    /// Events before this one were evicted before this connection could send them.
    public var gap: Bool

    public init(runtimeID: AgentRuntimeID, sequence: UInt64, event: LatchRemoteEvent, gap: Bool = false) {
        self.runtimeID = runtimeID
        self.sequence = sequence
        self.event = event
        self.gap = gap
    }

    /// The complete frame line for an event encoded once with `LatchRemoteCoding.encodeEvent`,
    /// byte for byte what encoding the frame would produce. The runtime ID must be valid for
    /// the network, so it needs no escaping.
    public static func encodedLine(
        runtimeID: AgentRuntimeID,
        sequence: UInt64,
        gap: Bool = false,
        encodedEvent: Data
    ) -> Data {
        precondition(LatchRemoteProtocol.isValidRuntimeID(runtimeID.rawValue))
        // Keys in the order `.sortedKeys` writes them.
        var line = Data()
        line.reserveCapacity(encodedEvent.count + 96)
        line.append(contentsOf: #"{"event":"#.utf8)
        line.append(encodedEvent)
        if gap {
            line.append(contentsOf: #","gap":true"#.utf8)
        }
        line.append(contentsOf: #","runtimeID":""#.utf8)
        line.append(contentsOf: runtimeID.rawValue.utf8)
        line.append(contentsOf: #"","sequence":"#.utf8)
        line.append(contentsOf: String(sequence).utf8)
        line.append(contentsOf: #","type":"event"}"#.utf8)
        line.append(0x0A)
        return line
    }
}

private enum FrameKeys: String, CodingKey {
    case type, id, command, result, error, ok, runtimeID, sequence, event, gap
}

/// A frame from client to server. After authentication the server decodes every line as one;
/// before it, only `LatchRemoteHello.decode(line:)` runs.
public enum LatchRemoteClientFrame: Equatable, Sendable {
    case hello(LatchRemoteHello)
    case request(LatchRemoteRequest)
    /// A request whose `id` decoded but whose command did not; answer `invalidRequest`.
    case invalidRequest(id: UUID)
    case ping
    /// Answer `unsupported` when it carried an `id`, else ignore it.
    case unknown(type: String, id: UUID?)
}

extension LatchRemoteClientFrame: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FrameKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(try LatchRemoteHello(from: decoder))
        case "request":
            let id = try container.decode(UUID.self, forKey: .id)
            if let command = try? container.decode(LatchRemoteCommand.self, forKey: .command) {
                self = .request(LatchRemoteRequest(id: id, command: command))
            } else {
                self = .invalidRequest(id: id)
            }
        case "ping":
            self = .ping
        default:
            self = .unknown(type: type, id: try? container.decodeIfPresent(UUID.self, forKey: .id))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FrameKeys.self)
        switch self {
        case let .hello(hello):
            try hello.encode(to: encoder)
        case let .request(request):
            try container.encode("request", forKey: .type)
            try container.encode(request.id, forKey: .id)
            try container.encode(request.command, forKey: .command)
        case let .invalidRequest(id):
            try container.encode("request", forKey: .type)
            try container.encode(id, forKey: .id)
        case .ping:
            try container.encode("ping", forKey: .type)
        case let .unknown(type, id):
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
        }
    }
}

/// A frame from server to client. Clients ignore unknown frame types.
public enum LatchRemoteServerFrame: Equatable, Sendable {
    case welcome(LatchRemoteWelcome)
    case rejected(LatchRemoteRejected)
    case reply(LatchRemoteReply)
    /// A reply whose `id` decoded but whose result or error did not; fail that request.
    case invalidReply(id: UUID)
    case event(LatchRemoteEventFrame)
    case pong
    case unknown(type: String)
}

extension LatchRemoteServerFrame: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FrameKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            self = .welcome(try LatchRemoteWelcome(from: decoder))
        case "rejected":
            self = .rejected(try LatchRemoteRejected(from: decoder))
        case "reply":
            let id = try container.decode(UUID.self, forKey: .id)
            if let result = try? Self.replyResult(in: container) {
                self = .reply(LatchRemoteReply(id: id, result: result))
            } else {
                self = .invalidReply(id: id)
            }
        case "event":
            self = .event(LatchRemoteEventFrame(
                runtimeID: try container.decodeRuntimeID(forKey: .runtimeID),
                sequence: try container.decode(UInt64.self, forKey: .sequence),
                // Even an event without a kind keeps its sequence, so the cursor moves past it.
                event: (try? container.decode(LatchRemoteEvent.self, forKey: .event)) ?? .unknown(kind: ""),
                gap: try container.decodeIfPresent(Bool.self, forKey: .gap) ?? false
            ))
        case "pong":
            self = .pong
        default:
            self = .unknown(type: type)
        }
    }

    private static func replyResult(in container: KeyedDecodingContainer<FrameKeys>) throws -> LatchRemoteReplyResult {
        if container.contains(.error) {
            return .failure(try container.decode(LatchRemoteError.self, forKey: .error))
        }
        let result = try container.nestedContainer(keyedBy: FrameKeys.self, forKey: .result)
        return .success(try result.decode(LatchRemoteResponse.self, forKey: .ok))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FrameKeys.self)
        switch self {
        case let .welcome(welcome):
            try welcome.encode(to: encoder)
        case let .rejected(rejected):
            try rejected.encode(to: encoder)
        case let .reply(reply):
            try container.encode("reply", forKey: .type)
            try container.encode(reply.id, forKey: .id)
            switch reply.result {
            case let .success(response):
                var result = container.nestedContainer(keyedBy: FrameKeys.self, forKey: .result)
                try result.encode(response, forKey: .ok)
            case let .failure(error):
                try container.encode(error, forKey: .error)
            }
        case let .invalidReply(id):
            try container.encode("reply", forKey: .type)
            try container.encode(id, forKey: .id)
        case let .event(frame):
            try container.encode("event", forKey: .type)
            try container.encodeRuntimeID(frame.runtimeID, forKey: .runtimeID)
            try container.encode(frame.sequence, forKey: .sequence)
            try container.encode(frame.event, forKey: .event)
            if frame.gap {
                try container.encode(true, forKey: .gap)
            }
        case .pong:
            try container.encode("pong", forKey: .type)
        case let .unknown(type):
            try container.encode(type, forKey: .type)
        }
    }
}
