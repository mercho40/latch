import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user, assistant, tool
    }

    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Bounded, session-local structured history. No transcript parsing or persistence.
struct ChatHistory: Sendable {
    private(set) var messages: [ChatMessage] = []
    static let maximumMessageCount = 400
    static let maximumTextCount = 200_000

    private struct Tool: Sendable {
        let messageID: UUID
        var title: String
        var status: String
    }
    private var tools: [String: Tool] = [:]
    private var adjacentRole: ChatMessage.Role?
    private var adjacentMessageID: UUID?
    private(set) var pendingWhitespace = ""

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

    mutating func appendUser(_ text: String) {
        append(text, role: .user, newMessage: true)
    }

    mutating func appendAssistant(_ text: String) {
        append(text, role: .assistant)
    }

    mutating func updateTool(toolCallID: String, title: String?, status: String?) {
        var tool = tools[toolCallID] ?? Tool(messageID: UUID(), title: toolCallID, status: "updated")
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tool.title = String(title.suffix(Self.maximumTextCount))
        }
        if let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tool.status = String(status.suffix(Self.maximumTextCount))
        }
        let text = "\(tool.title) · \(tool.status)"
        if let index = messages.firstIndex(where: { $0.id == tool.messageID }) {
            messages[index].text = text
        } else {
            messages.append(ChatMessage(id: tool.messageID, role: .tool, text: text))
        }
        tools[toolCallID] = tool
        // Even an in-place tool update interrupts adjacent assistant chunks.
        adjacentRole = .tool
        adjacentMessageID = nil
        pendingWhitespace = ""
        enforceBounds()
    }

    private mutating func append(_ text: String, role: ChatMessage.Role, newMessage: Bool = false) {
        if newMessage || adjacentRole != role {
            pendingWhitespace = ""
            adjacentMessageID = nil
        }
        adjacentRole = role
        guard !text.isEmpty else { return }
        if let adjacentMessageID, messages.last?.id == adjacentMessageID {
            messages[messages.count - 1].text += text
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A stream may begin with indentation. Retain it invisibly until content
            // arrives, within the same total text budget as visible messages.
            if !newMessage {
                pendingWhitespace = String((pendingWhitespace + text).suffix(Self.maximumTextCount))
            }
        } else {
            let message = ChatMessage(role: role, text: pendingWhitespace + text)
            pendingWhitespace = ""
            messages.append(message)
            adjacentMessageID = message.id
        }
        enforceBounds()
    }

    private mutating func enforceBounds() {
        if messages.count > Self.maximumMessageCount {
            messages.removeFirst(messages.count - Self.maximumMessageCount)
        }
        var count = messages.reduce(pendingWhitespace.count) { $0 + $1.text.count }
        let minimumVisibleCount = pendingWhitespace.isEmpty ? 1 : 0
        while count > Self.maximumTextCount, messages.count > minimumVisibleCount {
            count -= messages.removeFirst().text.count
        }
        if count > Self.maximumTextCount {
            messages[0].text = String(messages[0].text.suffix(Self.maximumTextCount))
        }
        messages.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let retainedIDs = Set(messages.map(\.id))
        tools = tools.filter { retainedIDs.contains($0.value.messageID) }
    }
}
