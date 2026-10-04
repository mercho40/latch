import Foundation
import LatchACP

/// Presentation-only snapshots. No event, JSON tree, file access, or terminal state is retained.
public struct ToolCallDetails: Sendable {
    private var content = ""
    private var locations = ""
    private var input = ""
    private var output = ""

    public init() {}

    public mutating func apply(_ tool: ACPToolCallEvent) {
        if let values = tool.content {
            content = Self.collection(values, label: "Content", limit: 8_000, render: Self.block)
        }
        if let values = tool.locations {
            locations = Self.collection(values, label: "Locations", limit: 2_000, render: Self.location)
        }
        if let value = tool.rawInput { input = Self.raw(value, label: "rawInput", limit: 2_000) }
        if let value = tool.rawOutput { output = Self.raw(value, label: "rawOutput", limit: 4_000) }
    }

    public var text: String {
        [content, locations, input, output].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static let truncated = "\n[truncated]"

    /// Copies only a bounded UTF-8 prefix, never slicing through a scalar. Line limits
    /// are applied after the byte bound, so even a single enormous grapheme is cheap.
    private static func prefix(_ value: String, bytes: Int, lines: Int = 120) -> (text: String, cut: Bool) {
        var buffer = Array(value.utf8.prefix(bytes + 1))
        var cut = buffer.count > bytes
        if cut { buffer.removeLast() }
        while String(bytes: buffer, encoding: .utf8) == nil { buffer.removeLast(); cut = true }
        let bounded = String(decoding: buffer, as: UTF8.self)
        var result = ""
        var count = 0
        for character in bounded {
            if character.isNewline {
                count += 1
                if count >= lines { cut = true; break }
            }
            result.append(character)
        }
        return (result, cut)
    }

    private static func clipped(_ value: String, bytes: Int, lines: Int = 120) -> String {
        let part = prefix(value, bytes: bytes, lines: lines)
        guard part.cut else { return part.text }
        return prefix(part.text, bytes: bytes - truncated.utf8.count, lines: lines).text + truncated
    }

    private static func collection(
        _ values: [ACPJSONValue], label: String, limit: Int, render: (ACPJSONValue) -> String
    ) -> String {
        guard !values.isEmpty else { return "" }
        var result = label + ":\n"
        for (index, value) in values.prefix(24).enumerated() {
            if index > 0 { result += "\n\n" }
            result += render(value)
            if result.utf8.count > limit { return clipped(result, bytes: limit) }
        }
        if values.count > 24 { result += "\n[truncated: additional items omitted]" }
        return clipped(result, bytes: limit)
    }

    private static func string(_ value: ACPJSONValue?) -> String? {
        guard case let .string(text)? = value else { return nil }
        return text
    }

    private static func block(_ value: ACPJSONValue) -> String {
        guard case let .object(fields) = value, let type = string(fields["type"]) else {
            return "[Malformed content block]"
        }
        // SDK 1.4.0: ToolCallContent -> Content.content -> ContentBlock/TextContent.
        switch type {
        case "content":
            guard case let .object(nested)? = fields["content"], let kind = string(nested["type"]) else {
                return "[Malformed content block]"
            }
            switch kind {
            case "text":
                guard let text = string(nested["text"]) else { return "[Malformed content block]" }
                return clipped(unfenced(text), bytes: 8_000)
            case "image":
                // The pixels stay out of a text snapshot; what they were does not.
                let type = string(nested["mimeType"]).map { clipped($0, bytes: 64, lines: 1) } ?? "unknown type"
                let size = string(nested["data"]).map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0.utf8.count / 4 * 3), countStyle: .file) } ?? ""
                return "[Image: \(type)\(size)]"
            case "resource_link", "resource":
                let resource: [String: ACPJSONValue]
                if case let .object(inner)? = nested["resource"] { resource = inner } else { resource = nested }
                guard let uri = string(resource["uri"]) else { return "[Malformed resource]" }
                let name = string(nested["name"]).map { clipped($0, bytes: 256, lines: 1) + ": " } ?? ""
                return "[Resource: " + name + clipped(uri, bytes: 1_024, lines: 2) + "]"
            default:
                return "[Unsupported content block]"
            }
        case "diff":
            guard let path = string(fields["path"]), let newText = string(fields["newText"]) else {
                return "[Malformed diff block]"
            }
            return "Diff: " + clipped(path, bytes: 512, lines: 2) + "\n"
                + lineDiff(oldText: fields["oldText"], newText: newText)
        case "terminal":
            guard let id = string(fields["terminalId"]) else { return "[Malformed terminal reference]" }
            return "Terminal reference: " + clipped(id, bytes: 512, lines: 2)
                + "\n[Terminal output unavailable; not executed]"
        default:
            return "[Unsupported content block]"
        }
    }

    /// Output an agent fenced as one Markdown code block, such as Claude Code's Bash output in
    /// ```` ```console ````, without the fence: details are shown as plain text already.
    static func unfenced(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6,
              let open = trimmed.firstIndex(of: "\n") else { return text }
        let info = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<open]
        guard !info.contains("`") else { return text }
        let body = trimmed[trimmed.index(after: open)..<trimmed.index(trimmed.endIndex, offsetBy: -3)]
        // A fence inside means this was not one block.
        guard !body.contains("\n```") else { return text }
        return String(body.hasSuffix("\n") ? body.dropLast() : body)
    }

    private static func location(_ value: ACPJSONValue) -> String {
        guard case let .object(fields) = value, let path = string(fields["path"]) else {
            return "[Malformed location]"
        }
        let label = clipped(path, bytes: 1_024, lines: 2)
        switch fields["line"] {
        case nil, .null?: return label
        case let .integer(line)? where line >= 0 && line <= Int64(UInt32.max):
            return label + " (line \(line))"
        default: return label + " [Malformed line number]"
        }
    }

    private static func raw(_ value: ACPJSONValue, label: String, limit: Int) -> String {
        if case .null = value { return "" }
        if case let .string(text) = value {
            return clipped(label + " (text):\n" + clipped(text, bytes: limit), bytes: limit)
        }
        var nodes = 64
        let preview = jsonPreview(value, depth: 0, nodes: &nodes)
        return clipped(label + " (structural JSON preview):\n" + preview, bytes: limit)
    }

    /// Only bounded scalars are serialized; collections are visited with shared node,
    /// depth, and item budgets. Notices deliberately make this a preview, not JSON to execute.
    private static func jsonPreview(_ value: ACPJSONValue, depth: Int, nodes: inout Int) -> String {
        guard nodes > 0, depth < 5 else { return "[truncated: JSON depth/items]" }
        nodes -= 1
        switch value {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .integer(value): return String(value)
        case let .double(value): return value.isFinite ? String(value) : "[Unsupported non-finite number]"
        case let .string(value): return quoted(value)
        case let .array(values):
            var parts: [String] = []
            for item in values.prefix(16) {
                guard nodes > 0 else { break }
                parts.append(jsonPreview(item, depth: depth + 1, nodes: &nodes))
            }
            if parts.count < values.count { parts.append("[truncated: JSON items]") }
            return "[" + parts.joined(separator: ", ") + "]"
        case let .object(values):
            var parts: [String] = []
            // Do not sort or copy the full dictionary (or its potentially huge keys).
            for (key, item) in values.prefix(16) {
                guard nodes > 0 else { break }
                parts.append(quoted(key) + ": " + jsonPreview(item, depth: depth + 1, nodes: &nodes))
            }
            if parts.count < values.count { parts.append("[truncated: JSON items]") }
            return "{" + parts.joined(separator: ", ") + "}"
        }
    }

    private static func quoted(_ value: String) -> String {
        let bounded = clipped(value, bytes: 512, lines: 16)
        guard let data = try? JSONEncoder().encode(bounded) else { return "[Unsupported string]" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Line: Equatable {
        var body: String
        var ending: String

        static func == (lhs: Line, rhs: Line) -> Bool {
            // Swift String equality normalizes Unicode; file text must be byte-exact.
            lhs.body.utf8.elementsEqual(rhs.body.utf8) && lhs.ending.utf8.elementsEqual(rhs.ending.utf8)
        }
    }

    private static func lines(_ text: String) -> [Line] {
        var result: [Line] = []
        var body = ""
        for character in text {
            if character.isNewline {
                result.append(Line(body: body, ending: String(character)))
                body = ""
            } else {
                body.append(character)
            }
        }
        if !body.isEmpty { result.append(Line(body: body, ending: "")) }
        return result
    }

    private static func displayed(_ line: Line, marker: String) -> String {
        var result = marker + line.body + "\n"
        if line.ending.isEmpty { result += "\\ No newline at end of file\n" }
        else if line.ending != "\n" {
            let codes = line.ending.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }
            result += "\\ Line ending: " + codes.joined(separator: " ") + "\n"
        }
        return result
    }

    /// A minimal line diff of the bounded inputs, as unified hunks with three lines of context;
    /// what lies between hunks is counted, not shown. Inputs are bounded before splitting and
    /// comparison, so the quadratic search stays small. Truncated or unknown baselines never
    /// fabricate additions.
    static func lineDiff(oldText: ACPJSONValue?, newText: String) -> String {
        let new = prefix(newText, bytes: 8_192, lines: 160)
        let old: (text: String, cut: Bool)
        var heading = ""
        switch oldText {
        case let .string(value)?: old = prefix(value, bytes: 8_192, lines: 160)
        case .null?:
            old = ("", false)
            heading = "[New file: oldText is null]\n"
        case nil:
            return clipped("[Old text unavailable: oldText omitted; additions unknown]\nNew text preview:\n"
                + new.text + (new.cut ? truncated : ""), bytes: 7_000)
        default:
            return clipped("[Malformed oldText; additions unknown]\nNew text preview:\n"
                + new.text + (new.cut ? truncated : ""), bytes: 7_000)
        }
        if old.cut || new.cut {
            return clipped(heading + "[truncated: diff input; comparison unavailable]\nOld text preview:\n"
                + clipped(old.text, bytes: 3_000, lines: 60) + "\nNew text preview:\n"
                + clipped(new.text, bytes: 3_000, lines: 60), bytes: 7_000)
        }
        let before = lines(old.text)
        let after = lines(new.text)
        let edits = script(from: before, to: after)
        guard edits.contains(where: { $0.kind != .same }) else { return heading + "[No text changes]" }

        // Where each edit starts in the old and the new text, for the hunks' headers.
        var oldAt: [Int] = [], newAt: [Int] = []
        var oldLine = 0, newLine = 0
        for edit in edits {
            oldAt.append(oldLine)
            newAt.append(newLine)
            if edit.kind != .insert { oldLine += 1 }
            if edit.kind != .delete { newLine += 1 }
        }
        // Each change with its context; changes whose contexts meet share a hunk.
        let context = 3
        var hunks: [Range<Int>] = []
        for (index, edit) in edits.enumerated() where edit.kind != .same {
            let range = max(0, index - context)..<min(edits.count, index + context + 1)
            if let last = hunks.last, range.lowerBound <= last.upperBound {
                hunks[hunks.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                hunks.append(range)
            }
        }
        var result = heading
        var shown = 0
        for hunk in hunks {
            if hunk.lowerBound > shown { result += "[\(hunk.lowerBound - shown) unchanged lines omitted]\n" }
            let slice = edits[hunk]
            let oldCount = slice.count { $0.kind != .insert }
            let newCount = slice.count { $0.kind != .delete }
            let oldStart = oldAt[hunk.lowerBound], newStart = newAt[hunk.lowerBound]
            result += "@@ -\(oldCount == 0 ? oldStart : oldStart + 1),\(oldCount) +\(newCount == 0 ? newStart : newStart + 1),\(newCount) @@\n"
            for edit in slice {
                switch edit.kind {
                case .same: result += displayed(edit.line, marker: " ")
                case .delete: result += displayed(edit.line, marker: "-")
                case .insert: result += displayed(edit.line, marker: "+")
                }
            }
            shown = hunk.upperBound
        }
        if edits.count > shown { result += "[\(edits.count - shown) unchanged lines omitted]\n" }
        return clipped(result, bytes: 7_000)
    }

    private struct Edit {
        enum Kind { case same, delete, insert }
        let kind: Kind
        let line: Line
    }

    /// The shortest edit script by longest common subsequence: deletions before insertions
    /// where both are possible, as `diff` writes them.
    private static func script(from before: [Line], to after: [Line]) -> [Edit] {
        let n = before.count, m = after.count
        var common = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                common[i][j] = before[i] == after[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
            }
        }
        var edits: [Edit] = []
        var i = 0, j = 0
        while i < n, j < m {
            if before[i] == after[j] {
                edits.append(Edit(kind: .same, line: before[i]))
                i += 1
                j += 1
            } else if common[i + 1][j] >= common[i][j + 1] {
                edits.append(Edit(kind: .delete, line: before[i]))
                i += 1
            } else {
                edits.append(Edit(kind: .insert, line: after[j]))
                j += 1
            }
        }
        edits += before[i...].map { Edit(kind: .delete, line: $0) }
        edits += after[j...].map { Edit(kind: .insert, line: $0) }
        return edits
    }
}
