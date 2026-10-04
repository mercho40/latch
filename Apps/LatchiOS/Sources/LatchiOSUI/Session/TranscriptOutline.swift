import Foundation
import LatchSessionKit

/// Where a row sits among subagents, and for a row with others under it, what happened there.
struct TranscriptRowInfo: Equatable {
    /// How many subagents' rows it is under.
    var depth = 0
    /// Whether any row is under it.
    var hasChildren = false
    /// Tool rows under it, at any depth.
    var steps = 0
    /// The title of the last of those to arrive.
    var latestStep: String?
}

/// The conversation's rows in the order they are shown. Each message stands where it arrived,
/// except what a subagent did: its calls, words and thinking follow its own row, depth-first in
/// the order they arrived, however they interleaved with the rest, and are left out while any
/// row above them is collapsed. A message whose parent is not in the list, or is not a tool row,
/// stands at the top level; so does one whose parent would make a loop, and a prompt always does.
struct TranscriptOutline: Equatable {
    /// The rows shown, in order.
    private(set) var rows: [UUID] = []
    /// For every row shown.
    private(set) var info: [UUID: TranscriptRowInfo] = [:]

    init(_ messages: [ChatMessage], expanded: Set<UUID>) {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents: [UUID: UUID] = [:]
        var children: [UUID: [UUID]] = [:]
        var roots: [UUID] = []
        var seen = Set<UUID>()
        var tools: [UUID] = []
        // A parent is looked up in the whole list, not only in what came before: an update can
        // give a row its parent after a later row has arrived.
        for message in messages where seen.insert(message.id).inserted {
            if message.role != .user, let parent = message.parentID, parent != message.id, byID[parent]?.role == .tool,
               !Self.isAncestor(message.id, of: parent, in: parents) {
                parents[message.id] = parent
                children[parent, default: []].append(message.id)
                if message.role == .tool { tools.append(message.id) }
            } else {
                roots.append(message.id)
            }
        }
        // Each tool row counts, and is the latest so far, for every row above it. Only the
        // latest one's title is read, once, since this runs on every streamed frame.
        var steps: [UUID: Int] = [:]
        var latest: [UUID: UUID] = [:]
        for tool in tools {
            var ancestor = parents[tool]
            while let current = ancestor {
                steps[current, default: 0] += 1
                latest[current] = tool
                ancestor = parents[current]
            }
        }
        // Depth-first with a stack of its own, so a long chain of nested subagents never recurses.
        var stack: [(id: UUID, depth: Int)] = roots.reversed().map { ($0, 0) }
        while let next = stack.popLast() {
            let under = children[next.id]
            rows.append(next.id)
            info[next.id] = TranscriptRowInfo(
                depth: next.depth, hasChildren: under != nil, steps: steps[next.id] ?? 0,
                latestStep: latest[next.id].flatMap { byID[$0] }.map { ToolCallPresentation.displayTitle(of: $0.text) })
            if expanded.contains(next.id), let under {
                stack.append(contentsOf: under.reversed().map { ($0, next.depth + 1) })
            }
        }
    }

    /// Whether `id` is `other` or above it in `parents`, which never loops.
    private static func isAncestor(_ id: UUID, of other: UUID, in parents: [UUID: UUID]) -> Bool {
        var current: UUID? = other
        while let next = current {
            if next == id { return true }
            current = parents[next]
        }
        return false
    }
}
