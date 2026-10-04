import LatchSessionKit
import UIKit

/// A tool message as the transcript shows it. The history keeps a tool call as
/// "title · status", a blank line, then the details `ToolCallDetails` wrote; this reads it back.
/// A row saved since the history kept a summary of the call beside it also has the call's
/// kind, and whether it runs a subagent; one saved before has only its text.
struct ToolCallPresentation: Equatable {
    let title: String
    /// As the agent reported it, such as `in_progress`.
    private(set) var status: String
    let details: String
    /// ACP's kind of tool, such as `read` or `execute`, when the row has a summary.
    var kind: String?
    /// The call runs a subagent, whose rows are nested under this one.
    var runsSubagent = false

    init(text: String) {
        let line = Self.firstLine(of: text)
        title = line.title
        status = line.status
        if let lineEnd = text.firstIndex(where: \.isNewline) {
            details = String(text[lineEnd...].drop(while: \.isNewline))
        } else {
            details = ""
        }
    }

    /// The row's text, with what its summary says where it has one.
    init(_ message: ChatMessage) {
        self.init(text: message.text)
        guard let tool = message.tool else { return }
        if let status = tool.status, !status.isEmpty { self.status = status }
        kind = tool.kind
        runsSubagent = tool.runsSubagent
    }

    private init(title: String, status: String, details: String) {
        self.title = title
        self.status = status
        self.details = details
    }

    private static func firstLine(of text: String) -> (title: String, status: String) {
        let firstLine = text.prefix { !$0.isNewline }
        guard let separator = firstLine.range(of: " · ", options: .backwards) else { return (String(firstLine), "") }
        return (String(firstLine[..<separator.lowerBound]), String(firstLine[separator.upperBound...]))
    }

    /// The title as shown, read from the first line alone, without copying the details.
    static func displayTitle(of text: String) -> String {
        ToolCallPresentation(title: firstLine(of: text).title, status: "", details: "").displayTitle
    }

    /// A command the agent ran: the history writes it in backticks, as Markdown code.
    var isCommand: Bool { title.count > 2 && title.hasPrefix("`") && title.hasSuffix("`") }

    /// The title as shown and spoken: a command without its backticks.
    var displayTitle: String {
        if title.isEmpty { return "Tool activity" }
        return isCommand ? String(title.dropFirst().dropLast()) : title
    }

    enum State { case pending, running, done, failed, cancelled, other }

    var state: State {
        switch status.lowercased() {
        case "pending": .pending
        case "in_progress", "running": .running
        case "completed", "done": .done
        case "failed", "error": .failed
        case "cancelled", "canceled": .cancelled
        default: .other
        }
    }

    /// The status in words. An unknown one is shown as the agent wrote it.
    var statusText: String {
        switch state {
        case .pending: "Pending"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .other: status == "updated" ? "" : status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Colour backs up the word, never replaces it. A running call is as quiet as a finished
    /// one, so it never outweighs the reply under it; its spinner says it is live.
    var statusColor: UIColor {
        switch state {
        case .failed, .cancelled: .systemRed
        default: .secondaryLabel
        }
    }

    /// From the call's kind, as the Mac picks it, or for a row saved without one, or of kind
    /// `other`, guessed from the title's first word.
    var symbolName: String {
        if runsSubagent { return "person.2" }
        switch kind {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.left.arrow.right"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "think": return "lightbulb"
        case "fetch": return "globe"
        case "switch_mode": return "arrow.triangle.branch"
        default: return guessedSymbolName
        }
    }

    private var guessedSymbolName: String {
        let word = title.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        switch word {
        case "read", "view", "open", "cat": return "doc.text"
        case "edit", "write", "update", "create", "patch", "replace", "insert": return "pencil"
        case "run", "bash", "exec", "execute", "terminal", "shell", "command": return "terminal"
        case "search", "grep", "find", "glob", "list", "ls": return "magnifyingglass"
        case "fetch", "web", "browse", "download", "http", "https": return "globe"
        case "delete", "remove", "rm": return "trash"
        case "move", "rename", "mv": return "arrow.right.doc.on.clipboard"
        case "think", "plan", "todo", "todos": return "list.bullet"
        default: return title.hasPrefix("`") ? "terminal" : "wrench.and.screwdriver"
        }
    }

    /// The details as plain monospaced text: section headings in semibold, and a diff's added
    /// and removed lines in green and red on a faint wash, as on the Mac. Nothing in them is
    /// interpreted as Markdown or made a link.
    static func styledDetails(_ text: String, font: UIFont, boldFont: UIFont) -> NSAttributedString {
        let text = displayedDetails(text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
        ])
        let source = text as NSString
        var position = 0
        var diffSection = false
        var diffHunk = false
        while position < source.length {
            var end = 0
            var contentEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: position, length: 0))
            let range = NSRange(location: position, length: end - position)
            let line = source.substring(with: NSRange(location: position, length: contentEnd - position))
            if line.isEmpty { diffSection = false; diffHunk = false }
            if line.hasPrefix("Diff: ") { diffSection = true; diffHunk = false }
            if diffSection && line.hasPrefix("@@ ") {
                diffHunk = true
                result.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
            } else if diffHunk && (line.hasPrefix("+") || line.hasPrefix("-")) {
                let color: UIColor = line.hasPrefix("+") ? .systemGreen : .systemRed
                result.addAttributes([.foregroundColor: color, .backgroundColor: color.withAlphaComponent(0.1)], range: range)
            } else if ["Content:", "Locations:", "Input:", "Output:"].contains(line) || line.hasPrefix("Diff: ") {
                result.addAttribute(.font, value: boldFont, range: range)
            }
            position = end
        }
        return result
    }
}

extension ToolCallPresentation {
    /// The details as shown here: the shared history's headings for the agent's raw input and
    /// output, such as "rawInput (structural JSON preview):", read "Input:" and "Output:".
    /// The history itself, and what the Mac shows, keep theirs.
    static func displayedDetails(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            for (prefix, heading) in [("rawInput (", "Input:"), ("rawOutput (", "Output:")]
            where line.hasPrefix(prefix) && line.hasSuffix("):") {
                return heading
            }
            return line
        }.joined(separator: "\n")
    }
}

/// What the agent thought on the way, as its folded row shows it.
enum ThoughtPresentation {
    /// The thought on one line, to show beside "Thinking" while it is folded: its first words,
    /// with each run of white space as one space and without Markdown's bold markers, which a
    /// line of plain text would show as they are. Only the start is read, as it streams.
    static func preview(_ text: String, limit: Int = 160) -> String {
        var result = ""
        var count = 0
        var space = false
        for character in text.prefix(limit * 2).replacingOccurrences(of: "**", with: "") {
            if character.isWhitespace {
                space = !result.isEmpty
                continue
            }
            guard count + (space ? 2 : 1) <= limit else { return result + "…" }
            if space {
                result.append(" ")
                count += 1
                space = false
            }
            result.append(character)
            count += 1
        }
        return text.dropFirst(limit * 2).isEmpty ? result : result + "…"
    }
}

/// How the transcript draws a message.
enum ChatMessageKind: Equatable {
    case user, assistant, tool, thought, notice
}

extension ChatMessageKind {
    /// A line of Latch's own, such as for output that could not be shown. The history writes
    /// it as one italic assistant line, so only the model's own notices count: an agent's
    /// reply that happens to be one italic line stays the agent's.
    @MainActor
    static func isNotice(_ text: String) -> Bool {
        guard text.count > 2, text.hasPrefix("_"), text.hasSuffix("_") else { return false }
        return notices.contains(String(text.dropFirst().dropLast()))
    }

    @MainActor
    private static let notices: Set<String> = [
        SessionModel.outputLostWhileClosed, SessionModel.outputLostWhileUnreachable,
        SessionModel.promptNotSent, SessionModel.promptNotSentOverLink, SessionModel.outputLostNotice,
    ]
}
