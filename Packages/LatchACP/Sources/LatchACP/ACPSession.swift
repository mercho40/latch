import Foundation

/// One block of a prompt. Text and resource links are baseline ACP; an image block is only
/// for an agent whose prompt capabilities include `image`.
public enum ACPPromptBlock: Codable, Equatable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)
    /// A file or folder the agent reads for itself, by `file://` URI.
    case resourceLink(uri: String, name: String, mimeType: String?)

    public var content: ACPJSONValue {
        switch self {
        case let .text(text):
            return .object(["type": .string("text"), "text": .string(text)])
        case let .image(data, mimeType):
            return .object(["type": .string("image"), "data": .string(data.base64EncodedString()),
                            "mimeType": .string(mimeType)])
        case let .resourceLink(uri, name, mimeType):
            var block: [String: ACPJSONValue] = ["type": .string("resource_link"), "uri": .string(uri), "name": .string(name)]
            if let mimeType { block["mimeType"] = .string(mimeType) }
            return .object(block)
        }
    }
}

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
    /// Where the turn's session updates end, in the connection's ingress sequence: the last
    /// update `ACPClient` put on `sessionUpdates` before this reply came in, or zero if there
    /// was none; it is there by the time the reply is returned. The reply and the updates
    /// travel separately, so whoever relays both waits for this one before ending the turn.
    /// Set by `ACPClient`, which replaces any value on the wire; nil where no connection
    /// answered, such as a server's account of a turn.
    public let updatesThrough: UInt64?

    public init(stopReason: String, meta: ACPJSONValue? = nil, updatesThrough: UInt64? = nil) {
        self.stopReason = stopReason
        self.meta = meta
        self.updatesThrough = updatesThrough
    }

    private enum CodingKeys: String, CodingKey {
        case stopReason
        case updatesThrough
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
    /// The update's own `_meta`.
    public let meta: ACPJSONValue?

    /// A subagent's words: the tool call that runs the subagent, as Claude Code marks them.
    public var parentToolCallID: String? { ACPClaudeCodeMeta(meta).parentToolCallID }

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
    /// The update's own `_meta`.
    public let meta: ACPJSONValue?

    /// The tool call of the subagent that made this one, as Claude Code marks it.
    public var parentToolCallID: String? { ACPClaudeCodeMeta(meta).parentToolCallID }
    /// The agent's own name for the tool, such as `Bash` or `Agent`, where it gives one.
    public var toolName: String? { ACPClaudeCodeMeta(meta).string("toolName") }
    /// This call runs a subagent, whose own calls name it as their parent.
    public var runsSubagent: Bool { ACPClaudeCodeMeta(meta).bool("subagent") }
}

/// What Claude Code adds under `_meta.claudeCode`; other agents send none of it.
struct ACPClaudeCodeMeta {
    private let fields: [String: ACPJSONValue]

    init(_ meta: ACPJSONValue?) {
        guard case let .object(meta)? = meta, case let .object(fields)? = meta["claudeCode"] else {
            self.fields = [:]
            return
        }
        self.fields = fields
    }

    var parentToolCallID: String? { string("parentToolUseId") }

    func string(_ key: String) -> String? {
        guard case let .string(value)? = fields[key], !value.isEmpty else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool {
        guard case let .bool(value)? = fields[key] else { return false }
        return value
    }
}

/// One step of an agent's plan, as its `plan` update lists them.
public struct ACPPlanEntry: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable { case pending, inProgress = "in_progress", completed }

    public let content: String
    public let status: Status
    /// `high`, `medium` or `low`, as the agent ranks it.
    public let priority: String?

    public init(content: String, status: Status, priority: String? = nil) {
        self.content = content
        self.status = status
        self.priority = priority
    }
}

/// A slash command the agent accepts, invoked by starting a prompt with `/name`.
public struct ACPAvailableCommand: Equatable, Sendable {
    /// Without the leading slash.
    public let name: String
    public let description: String
    /// What to type after the name, when the command takes input.
    public let inputHint: String?

    public init(name: String, description: String, inputHint: String? = nil) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
}

/// A typed projection of stable ACP v1 update variants. Unknown variants retain their raw payload.
public enum ACPSessionEvent: Equatable, Sendable {
    case messageChunk(ACPMessageChunk)
    case toolCall(ACPToolCallEvent, initial: Bool)
    /// The whole plan; each update replaces the last, and an empty one clears it.
    case plan([ACPPlanEntry])
    case usage(ACPJSONValue)
    /// The whole current list; each update replaces the last.
    case availableCommands([ACPAvailableCommand])
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
                ACPMessageChunk(role: role, messageID: messageID, content: content, meta: object["_meta"])
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
                    rawOutput: object["rawOutput"],
                    meta: object["_meta"]
                ),
                initial: kind == "tool_call"
            )
        case "plan":
            guard let entries = object.array(forKey: "entries") else {
                return .other(kind: kind, payload: update)
            }
            // One malformed entry drops only itself; an unknown status reads as pending.
            return .plan(entries.compactMap { entry in
                guard case let .object(step) = entry, let content = step.string(forKey: "content") else { return nil }
                let status = step.string(forKey: "status").flatMap(ACPPlanEntry.Status.init(rawValue:)) ?? .pending
                return ACPPlanEntry(content: content, status: status, priority: step.string(forKey: "priority"))
            })
        case "usage_update":
            return .usage(update)
        case "available_commands_update":
            guard let entries = object.array(forKey: "availableCommands") else {
                return .other(kind: kind, payload: update)
            }
            // One malformed entry drops only itself, not the agent's whole list.
            return .availableCommands(entries.compactMap { entry in
                guard case let .object(command) = entry,
                      var name = command.string(forKey: "name") else { return nil }
                if name.hasPrefix("/") { name.removeFirst() }
                guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
                var hint: String?
                if case let .object(input)? = command["input"] { hint = input.string(forKey: "hint") }
                return ACPAvailableCommand(name: name, description: command.string(forKey: "description") ?? "",
                                           inputHint: hint?.isEmpty == true ? nil : hint)
            })
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

/// The agent asks the user something: ACP's `elicitation/create`. Claude Code asks its
/// AskUserQuestion questions this way. Latch answers forms; it does not offer URL mode.
public struct ACPElicitationRequest: Codable, Equatable, Sendable {
    public let sessionId: String
    /// `form`, or `url` for a page to open, which Latch does not advertise.
    public let mode: String
    public let message: String
    /// For a form, a JSON Schema object whose properties are its fields.
    public let requestedSchema: ACPJSONValue?
    /// The tool call that asks, when one does.
    public let toolCallId: String?
    public let meta: ACPJSONValue?

    public init(sessionId: String, mode: String = "form", message: String, requestedSchema: ACPJSONValue? = nil,
                toolCallId: String? = nil, meta: ACPJSONValue? = nil) {
        self.sessionId = sessionId
        self.mode = mode
        self.message = message
        self.requestedSchema = requestedSchema
        self.toolCallId = toolCallId
        self.meta = meta
    }

    /// A form may leave `mode` out, as MCP's do.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "form"
        message = try container.decode(String.self, forKey: .message)
        requestedSchema = try container.decodeIfPresent(ACPJSONValue.self, forKey: .requestedSchema)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        meta = try container.decodeIfPresent(ACPJSONValue.self, forKey: .meta)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, mode, message, requestedSchema, toolCallId
        case meta = "_meta"
    }
}

public struct ACPElicitationResponse: Codable, Equatable, Sendable {
    /// `accept` with the answers; `decline` to answer nothing, which Claude Code takes as
    /// skipped; `cancel` to refuse the question, which ends the call that asked.
    public enum Action: String, Codable, Equatable, Sendable { case accept, decline, cancel }

    public let action: Action
    /// The answers, by field, when accepted.
    public let content: [String: ACPJSONValue]?

    public init(action: Action, content: [String: ACPJSONValue]? = nil) {
        self.action = action
        self.content = action == .accept ? content : nil
    }

    public static let cancelled = ACPElicitationResponse(action: .cancel)
}

/// A saved session as the agent lists it.
public struct ACPSessionSummary: Codable, Equatable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let title: String?
    /// ISO 8601, as the agent wrote it.
    public let updatedAt: String?

    public init(sessionId: String, cwd: String, title: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
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
