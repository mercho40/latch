import Foundation

public struct ACPTextContent: Codable, Equatable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "text"
        self.text = text
    }
}

public struct ACPPromptResponse: Codable, Equatable, Sendable {
    public let stopReason: String
    public let meta: ACPJSONValue?

    public init(stopReason: String, meta: ACPJSONValue? = nil) {
        self.stopReason = stopReason
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case stopReason
        case meta = "_meta"
    }
}

/// A forward-compatible session update. Interpret `update` by its `sessionUpdate` field.
public struct ACPSessionNotification: Codable, Equatable, Sendable {
    public let sessionId: String
    public let update: ACPJSONValue
    public let meta: ACPJSONValue?

    public let localSequence: UInt64?

    public init(
        sessionId: String,
        update: ACPJSONValue,
        meta: ACPJSONValue? = nil,
        localSequence: UInt64? = nil
    ) {
        self.sessionId = sessionId
        self.update = update
        self.meta = meta
        self.localSequence = localSequence
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case update
        case localSequence
        case meta = "_meta"
    }
}

public enum ACPMessageRole: String, Equatable, Sendable {
    case user
    case agent
    case thought
}

public struct ACPMessageChunk: Equatable, Sendable {
    public let role: ACPMessageRole
    public let messageID: String?
    public let content: ACPJSONValue

    public var text: String? {
        guard
            case let .object(object) = content,
            case let .string(text)? = object["text"]
        else {
            return nil
        }
        return text
    }
}

public struct ACPToolCallEvent: Equatable, Sendable {
    public let toolCallID: String
    public let title: String?
    public let kind: String?
    public let status: String?
    public let content: [ACPJSONValue]?
    public let locations: [ACPJSONValue]?
    public let rawInput: ACPJSONValue?
    public let rawOutput: ACPJSONValue?
}

/// A typed projection of stable ACP v1 update variants. Unknown variants retain their raw payload.
public enum ACPSessionEvent: Equatable, Sendable {
    case messageChunk(ACPMessageChunk)
    case toolCall(ACPToolCallEvent, initial: Bool)
    case plan(ACPJSONValue)
    case usage(ACPJSONValue)
    case other(kind: String?, payload: ACPJSONValue)
}

extension ACPSessionNotification {
    public var event: ACPSessionEvent {
        guard case let .object(object) = update else {
            return .other(kind: nil, payload: update)
        }
        guard case let .string(kind)? = object["sessionUpdate"] else {
            return .other(kind: nil, payload: update)
        }

        switch kind {
        case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
            guard let content = object["content"] else {
                return .other(kind: kind, payload: update)
            }
            let role: ACPMessageRole
            switch kind {
            case "user_message_chunk": role = .user
            case "agent_thought_chunk": role = .thought
            default: role = .agent
            }
            let messageID: String?
            if case let .string(value)? = object["messageId"] {
                messageID = value
            } else {
                messageID = nil
            }
            return .messageChunk(
                ACPMessageChunk(role: role, messageID: messageID, content: content)
            )
        case "tool_call", "tool_call_update":
            guard case let .string(toolCallID)? = object["toolCallId"] else {
                return .other(kind: kind, payload: update)
            }
            return .toolCall(
                ACPToolCallEvent(
                    toolCallID: toolCallID,
                    title: object.string(forKey: "title"),
                    kind: object.string(forKey: "kind"),
                    status: object.string(forKey: "status"),
                    content: object.array(forKey: "content"),
                    locations: object.array(forKey: "locations"),
                    rawInput: object["rawInput"],
                    rawOutput: object["rawOutput"]
                ),
                initial: kind == "tool_call"
            )
        case "plan":
            return .plan(update)
        case "usage_update":
            return .usage(update)
        default:
            return .other(kind: kind, payload: update)
        }
    }
}

private extension Dictionary where Key == String, Value == ACPJSONValue {
    func string(forKey key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }

    func array(forKey key: String) -> [ACPJSONValue]? {
        guard case let .array(value)? = self[key] else { return nil }
        return value
    }
}

public struct ACPPermissionOption: Codable, Equatable, Sendable {
    public let optionId: String
    public let name: String
    public let kind: String

    public init(optionId: String, name: String, kind: String) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}

public struct ACPPermissionRequest: Codable, Equatable, Sendable {
    public let sessionId: String
    public let toolCall: ACPJSONValue
    public let options: [ACPPermissionOption]
    public let meta: ACPJSONValue?

    public init(
        sessionId: String,
        toolCall: ACPJSONValue,
        options: [ACPPermissionOption],
        meta: ACPJSONValue? = nil
    ) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case toolCall
        case options
        case meta = "_meta"
    }
}

public enum ACPPermissionOutcome: Equatable, Sendable {
    case selected(optionID: String)
    case cancelled
}

extension ACPPermissionOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome
        case optionId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .outcome) {
        case "selected":
            self = .selected(optionID: try container.decode(String.self, forKey: .optionId))
        case "cancelled":
            self = .cancelled
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Unknown permission outcome"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .selected(optionID):
            try container.encode("selected", forKey: .outcome)
            try container.encode(optionID, forKey: .optionId)
        case .cancelled:
            try container.encode("cancelled", forKey: .outcome)
        }
    }
}
