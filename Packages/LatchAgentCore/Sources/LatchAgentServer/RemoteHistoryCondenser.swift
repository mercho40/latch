import Foundation
import LatchACP
import LatchRemoteProtocol

/// Condenses a block of journaled events, oldest first, into fewer that a client which has
/// seen none of them shows the same way: text chunks of one message that came one after
/// another become one chunk, and each tool call's updates fold into the call's first event
/// in the block. Everything else stays as it was journaled, bytes and all.
///
/// Each event keeps the sequence of the first it stands for, and the last takes the block's
/// last sequence, so a client that read all of it is caught up to where the block ends. A
/// client that read part of the block before it was condensed would see some of it twice,
/// which is why the journal gives condensed history only to a client attaching from the start.
enum RemoteHistoryCondenser {
    struct Event: Equatable {
        var sequence: UInt64
        var encodedEvent: Data
        /// The journal's publish order, so its global budget still evicts the oldest first.
        var order: UInt64
    }

    /// Joined text past this many bytes starts another chunk.
    static let maxChunkBytes = 256 * 1024

    static func condense(_ block: [Event], maxEncodedEventBytes: Int) -> [Event] {
        guard let last = block.last?.sequence else { return [] }
        var items: [Item] = []
        // The item each tool call's updates fold into, and the bytes folded into it so far.
        var anchors: [ToolKey: (index: Int, bytes: Int)] = [:]
        for event in block {
            var item = Item(event)
            guard let (notification, replay) = sessionUpdate(event.encodedEvent) else {
                items.append(item)
                continue
            }
            item.replay = replay
            if let chunk = CoalescingChunk(notification, token: 0) {
                // Only onto the chunk right before it: anything between two chunks parts them.
                if let index = items.indices.last, var held = items[index].chunk, held.shape == chunk.shape,
                   items[index].replay == replay, held.text.utf8.count + chunk.text.utf8.count <= maxChunkBytes {
                    held.text += chunk.text
                    held.latest = notification
                    items[index].chunk = held
                    items[index].changed = true
                } else {
                    item.chunk = chunk
                    items.append(item)
                }
                continue
            }
            guard case let .object(update) = notification.update,
                  case let .string(kind)? = update["sessionUpdate"], kind == "tool_call" || kind == "tool_call_update",
                  case let .string(toolCallID)? = update["toolCallId"] else {
                items.append(item)
                continue
            }
            let key = ToolKey(sessionID: notification.sessionId, toolCallID: toolCallID, replay: replay)
            if let anchor = anchors[key], anchor.bytes + event.encodedEvent.count <= maxEncodedEventBytes,
               var tool = items[anchor.index].tool {
                fold(update, into: &tool.update)
                items[anchor.index].tool = tool
                items[anchor.index].changed = true
                anchors[key]!.bytes += event.encodedEvent.count
                // A tool update parts the chunks around it into two messages; an empty one in
                // its place still does.
                if items.last?.chunk != nil {
                    let stub = ACPSessionNotification(sessionId: notification.sessionId, update: .object([
                        "sessionUpdate": .string("tool_call_update"), "toolCallId": .string(toolCallID),
                    ]))
                    if let encoded = try? LatchRemoteCoding.encodeEvent(.sessionUpdate(notification: stub, replay: replay)) {
                        items.append(Item(Event(sequence: event.sequence, encodedEvent: encoded, order: event.order)))
                    }
                }
            } else {
                item.tool = (notification, update)
                items.append(item)
                anchors[key] = (items.count - 1, event.encodedEvent.count)
            }
        }
        return items.enumerated().map { index, item in
            Event(sequence: index == items.count - 1 ? last : item.sequence, encodedEvent: item.encoded, order: item.order)
        }
    }

    /// An update's fields over the call's, as a client applies them: a blank title or status,
    /// or a null, changes nothing, and `_meta` merges key by key.
    static func fold(_ update: [String: ACPJSONValue], into call: inout [String: ACPJSONValue]) {
        for (key, value) in update where key != "sessionUpdate" && key != "toolCallId" && value != .null {
            switch key {
            case "title", "status":
                guard case let .string(text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                call[key] = value
            case "_meta":
                call[key] = merged(call[key], value)
            default:
                call[key] = value
            }
        }
    }

    private static func merged(_ base: ACPJSONValue?, _ update: ACPJSONValue) -> ACPJSONValue {
        guard case var .object(result)? = base, case let .object(fields) = update else { return update }
        for (key, value) in fields where value != .null {
            result[key] = merged(result[key], value)
        }
        return .object(result)
    }

    /// The notification in a journaled session update; nil for any other event. The encoder
    /// sorts keys, so `kind` comes first and other events are passed over undecoded.
    private static func sessionUpdate(_ encoded: Data) -> (ACPSessionNotification, replay: Bool)? {
        guard encoded.starts(with: sessionUpdatePrefix),
              case let .sessionUpdate(notification, replay)? = try? LatchRemoteCoding.makeDecoder().decode(LatchRemoteEvent.self, from: encoded)
        else { return nil }
        return (notification, replay)
    }

    private static let sessionUpdatePrefix = Data(#"{"kind":"sessionUpdate""#.utf8)

    private struct ToolKey: Hashable {
        let sessionID: String
        let toolCallID: String
        let replay: Bool
    }

    private struct Item {
        let sequence: UInt64
        let order: UInt64
        /// As journaled, which is what goes out unless `changed`.
        let original: Data
        var replay = false
        var chunk: CoalescingChunk?
        var tool: (notification: ACPSessionNotification, update: [String: ACPJSONValue])?
        var changed = false

        init(_ event: Event) {
            sequence = event.sequence
            order = event.order
            original = event.encodedEvent
        }

        var encoded: Data {
            guard changed else { return original }
            let notification: ACPSessionNotification
            if let chunk {
                notification = chunk.joined
            } else if let tool {
                notification = ACPSessionNotification(sessionId: tool.notification.sessionId, update: .object(tool.update),
                                                      meta: tool.notification.meta, localSequence: tool.notification.localSequence)
            } else {
                return original
            }
            return (try? LatchRemoteCoding.encodeEvent(.sessionUpdate(notification: notification, replay: replay))) ?? original
        }
    }
}
