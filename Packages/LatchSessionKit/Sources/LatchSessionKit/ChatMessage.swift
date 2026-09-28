import Foundation
import LatchACP

/// What a sent message carried besides its text. Only the name and, for a file, its path are
/// kept: an image's bytes went to the agent and are not saved with the transcript.
public struct ChatAttachment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable { case image, file }
    public let kind: Kind
    public let name: String
    public let path: String?

    public init(kind: Kind, name: String, path: String?) {
        self.kind = kind
        self.name = name
        self.path = path
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable {
        case user, assistant, tool
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var attachments: [ChatAttachment]

    public init(id: UUID = UUID(), role: Role, text: String, attachments: [ChatAttachment] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, attachments }

    // Sessions saved before attachments existed have no key; most messages still have none,
    // so an empty list is left out rather than written into every saved message.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        if !attachments.isEmpty { try container.encode(attachments, forKey: .attachments) }
    }
}

/// Bounded structured history. Restoring starts a new stream boundary, never merging
/// a future response or tool update into an archived message.
public struct ChatHistory: Sendable {
    private(set) var messages: [ChatMessage] = []
    public static let maximumMessageCount = 400
    public static let maximumTextCount = 200_000

    private struct Tool: Sendable {
        let messageID: UUID
        var title: String
        var status: String
        var details = ToolCallDetails()
    }
    private var tools: [String: Tool] = [:]
    private var adjacentRole: ChatMessage.Role?
    private var adjacentMessageID: UUID?
    private(set) var pendingWhitespace = ""
    // Parallel counts avoid walking retained strings on each streaming chunk.
    private var textCounts: [Int] = []
    private var visibleTextCount = 0
    private var pendingTextCount = 0

    private mutating func clearPendingWhitespace() {
        pendingWhitespace = ""
        pendingTextCount = 0
    }

    /// A chunk can extend the last grapheme (CR/LF, combining marks, ZWJ,
    /// regional indicators, etc.). Re-segment that grapheme with the new chunk,
    /// not the whole accumulated response. Mutate the stored String in place:
    /// retaining a local copy of it would force a full COW copy on every token.
    private static func appendChunk(_ chunk: String, to text: inout String) -> Int {
        let delta: Int
        if let last = text.last {
            delta = (String(last) + chunk).count - 1
        } else {
            delta = chunk.count
        }
        text.append(contentsOf: chunk)
        return delta
    }

    private mutating func addMessage(_ message: ChatMessage) {
        let count = message.text.count
        messages.append(message)
        textCounts.append(count)
        visibleTextCount += count
    }

    var transcript: String {
        messages.map { message in
            let label: String
            switch message.role {
            case .user: label = "You"
            case .assistant: label = "Agent"
            case .tool: label = "Tool"
            }
            return "\(label)\n\(message.text)"
        }.joined(separator: "\n\n")
    }

    mutating func reset() {
        self = ChatHistory()
    }

    mutating func restore(_ messages: [ChatMessage]) {
        reset()
        self.messages = messages
        textCounts = messages.map { $0.text.count }
        visibleTextCount = textCounts.reduce(0, +)
        enforceBounds()
        // The old implementation applies bounds BEFORE dropping restored empty
        // rows, which can affect which nonempty rows survive.
        for index in self.messages.indices.reversed() {
            if self.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               self.messages[index].attachments.isEmpty {
                visibleTextCount -= textCounts.remove(at: index)
                self.messages.remove(at: index)
            }
        }
    }

    /// Keeps the messages up to and including `id` and drops the rest, as a journal is about
    /// to replay them. A boundary no longer held was evicted, so it is older than every message
    /// left, and none of them is kept; neither is any when there was no message at the boundary.
    mutating func removeMessages(after id: UUID?) {
        let kept = id.flatMap { id in messages.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        restore(Array(messages.prefix(kept)))
    }

    mutating func appendUser(_ text: String, attachments: [ChatAttachment] = []) {
        guard !attachments.isEmpty else {
            append(text, role: .user, newMessage: true)
            return
        }
        // The text may be empty: the attachments alone make it a message.
        clearPendingWhitespace()
        adjacentMessageID = nil
        adjacentRole = .user
        addMessage(ChatMessage(role: .user, text: text, attachments: attachments))
        enforceBounds()
    }

    /// A chunk of a user message the agent streams, as when it replays a loaded session;
    /// prompts sent from here go whole through `appendUser`.
    /// `newMessage` when the chunk begins a message even after one of the same role.
    mutating func appendUserChunk(_ text: String, newMessage: Bool = false) {
        append(text, role: .user, newMessage: newMessage)
    }

    mutating func appendAssistant(_ text: String, newMessage: Bool = false) {
        append(text, role: .assistant, newMessage: newMessage)
    }

    /// A line of Latch's own in the agent's column, such as for output that could not be
    /// shown. It stands alone, so the agent's next chunk starts a message of its own, and the
    /// same notice twice in a row is written once.
    mutating func appendNotice(_ text: String) {
        let line = "_\(text)_"
        guard messages.last?.text != line else { return }
        append(line, role: .assistant, newMessage: true)
        adjacentRole = nil
        adjacentMessageID = nil
    }

    mutating func updateTool(_ event: ACPToolCallEvent) {
        updateTool(toolCallID: event.toolCallID, title: event.title, status: event.status, event: event)
    }

    mutating func updateTool(toolCallID: String, title: String?, status: String?, event: ACPToolCallEvent? = nil) {
        var tool = tools[toolCallID] ?? Tool(messageID: UUID(), title: toolCallID, status: "updated")
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tool.title = String(title.suffix(Self.maximumTextCount))
        }
        if let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tool.status = String(status.suffix(Self.maximumTextCount))
        }
        if let event { tool.details.apply(event) }
        let details = tool.details.text
        // Persist only the bounded display snapshot in the existing text budget,
        // not arbitrary agent payloads or a second structured archive.
        let text = "\(tool.title) · \(tool.status)" + (details.isEmpty ? "" : "\n\n" + details)
        if let index = messages.firstIndex(where: { $0.id == tool.messageID }) {
            let count = text.count
            visibleTextCount += count - textCounts[index]
            textCounts[index] = count
            messages[index].text = text
        } else {
            addMessage(ChatMessage(id: tool.messageID, role: .tool, text: text))
        }
        tools[toolCallID] = tool
        // Even an in-place tool update interrupts adjacent assistant chunks.
        adjacentRole = .tool
        adjacentMessageID = nil
        clearPendingWhitespace()
        enforceBounds()
    }

    private mutating func append(_ text: String, role: ChatMessage.Role, newMessage: Bool = false) {
        if newMessage || adjacentRole != role {
            clearPendingWhitespace()
            adjacentMessageID = nil
        }
        adjacentRole = role
        guard !text.isEmpty else { return }
        if let adjacentMessageID, messages.last?.id == adjacentMessageID {
            let index = messages.count - 1
            let delta = Self.appendChunk(text, to: &messages[index].text)
            textCounts[index] += delta
            visibleTextCount += delta
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A stream may begin with indentation. Retain it invisibly until content
            // arrives, within the same total text budget as visible messages.
            if !newMessage {
                pendingTextCount += Self.appendChunk(text, to: &pendingWhitespace)
                if pendingTextCount > Self.maximumTextCount {
                    pendingWhitespace = String(pendingWhitespace.suffix(Self.maximumTextCount))
                    pendingTextCount = Self.maximumTextCount
                }
            }
        } else {
            let message = ChatMessage(role: role, text: pendingWhitespace + text)
            clearPendingWhitespace()
            addMessage(message)
            adjacentMessageID = message.id
        }
        enforceBounds()
    }

    private mutating func enforceBounds() {
        var removalCount = max(0, messages.count - Self.maximumMessageCount)
        for index in 0..<removalCount {
            visibleTextCount -= textCounts[index]
        }
        let minimumVisibleCount = pendingWhitespace.isEmpty ? 1 : 0
        while visibleTextCount + pendingTextCount > Self.maximumTextCount,
              messages.count - removalCount > minimumVisibleCount {
            visibleTextCount -= textCounts[removalCount]
            removalCount += 1
        }
        var removedMessages = removalCount > 0
        if removedMessages {
            messages.removeFirst(removalCount)
            textCounts.removeFirst(removalCount)
        }
        if visibleTextCount + pendingTextCount > Self.maximumTextCount {
            messages[0].text = String(messages[0].text.suffix(Self.maximumTextCount))
            textCounts[0] = messages[0].text.count
            visibleTextCount = textCounts[0]
            // Only truncation can turn an existing nonempty row into whitespace.
            if messages[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, messages[0].attachments.isEmpty {
                messages.removeAll()
                textCounts.removeAll()
                visibleTextCount = 0
                removedMessages = true
            }
        }
        // Metadata pruning is necessary only after eviction, never per token.
        if removedMessages, !tools.isEmpty {
            let retainedIDs = Set(messages.map(\.id))
            tools = tools.filter { retainedIDs.contains($0.value.messageID) }
        }
    }
}
