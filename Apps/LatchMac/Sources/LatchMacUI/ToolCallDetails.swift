import Foundation
import LatchACP

/// Presentation-only snapshots. No event, JSON tree, file access, or terminal state is retained.
struct ToolCallDetails: Sendable {
    private var content = ""
    private var locations = ""
    private var input = ""
    private var output = ""

    init() {}

    mutating func apply(_ tool: ACPToolCallEvent) {
        if let values = tool.content {
            content = Self.collection(values, label: "Content", limit: 8_000, render: Self.block)
        }
        if let values = tool.locations {
            locations = Self.collection(values, label: "Locations", limit: 2_000, render: Self.location)
        }
        if let value = tool.rawInput { input = Self.raw(value, label: "rawInput", limit: 2_000) }
        if let value = tool.rawOutput { output = Self.raw(value, label: "rawOutput", limit: 4_000) }
    }

    var text: String {
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
            guard case let .object(nested)? = fields["content"],
                  string(nested["type"]) == "text", let text = string(nested["text"]) else {
                return "[Unsupported or malformed content block]"
            }
            return clipped(text, bytes: 8_000)
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

    /// O(n) prefix/suffix preview, not a minimal patch. Inputs are bounded before
    /// splitting/comparison. Truncated or unknown baselines never fabricate additions.
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
        var common = 0
        while common < min(before.count, after.count), before[common] == after[common] { common += 1 }
        if common == before.count && common == after.count {
            return heading + "[No text changes]"
        }
        var suffix = 0
        while suffix < min(before.count, after.count) - common,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let start = max(0, common - 3)
        let tail = min(3, suffix)
        let oldEnd = before.count - suffix
        let newEnd = after.count - suffix
        let oldCount = oldEnd + tail - start
        let newCount = newEnd + tail - start
        var result = heading + "[Prefix/suffix diff preview; not a minimal patch]\n"
        if start > 0 { result += "[\(start) unchanged lines omitted]\n" }
        result += "@@ -\(oldCount == 0 ? start : start + 1),\(oldCount) +\(newCount == 0 ? start : start + 1),\(newCount) @@\n"
        for line in before[start..<common] { result += displayed(line, marker: " ") }
        for line in before[common..<oldEnd] { result += displayed(line, marker: "-") }
        for line in after[common..<newEnd] { result += displayed(line, marker: "+") }
        for line in after[newEnd..<(newEnd + tail)] { result += displayed(line, marker: " ") }
        if suffix > tail { result += "[\(suffix - tail) unchanged lines omitted]\n" }
        return clipped(result, bytes: 7_000)
    }
}
