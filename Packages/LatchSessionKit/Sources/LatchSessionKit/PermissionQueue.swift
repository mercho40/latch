import Foundation
import LatchACP

/// Session-local decisions only. The agent, not Latch, defines the scope of “always”.
@MainActor
public final class PermissionQueue {
    public struct Prompt {
        public let id: UUID
        public let request: ACPPermissionRequest
        public var options: [ACPPermissionOption] { request.options.filter { $0.permissionLabel != nil } }
    }

    private struct Entry {
        let prompt: Prompt
        let continuation: CheckedContinuation<ACPPermissionOutcome, Never>
    }

    private var entries: [Entry] = []
    public var current: Prompt? { entries.first?.prompt }
    /// Owned by the session's model, which passes each change on through its own `onChange`.
    var onChange: (() -> Void)?

    func request(_ request: ACPPermissionRequest) async -> ACPPermissionOutcome {
        let id = UUID()
        let outcome: ACPPermissionOutcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, entries.count < 16,
                      Set(request.options.map(\.optionId)).count == request.options.count else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                entries.append(Entry(prompt: Prompt(id: id, request: request), continuation: continuation))
                onChange?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
        // Cancellation may precede a click while its MainActor cleanup is still queued.
        return Task.isCancelled ? .cancelled : outcome
    }

    public func resolve(id: UUID, optionID: String?) {
        // Only the visible request can be decided; stale sheet callbacks cannot approve another.
        guard let first = entries.first, first.prompt.id == id else { return }
        if let optionID, !first.prompt.options.contains(where: { $0.optionId == optionID }) { return }
        entries.removeFirst()
        first.continuation.resume(returning: optionID.map { .selected(optionID: $0) } ?? .cancelled)
        onChange?()
    }

    public func cancelAll() {
        let pending = entries
        entries.removeAll()
        for entry in pending { entry.continuation.resume(returning: .cancelled) }
        onChange?()
    }

    private func cancel(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.prompt.id == id }) else { return }
        entries.remove(at: index).continuation.resume(returning: .cancelled)
        onChange?()
    }
}

extension PermissionQueue.Prompt {
    /// What the agent wants to do: its own heading for the request, such as Claude Code's
    /// "Ready to code?", else the tool call's title. One line, as a heading: a command's title
    /// can be a whole script, which the details show in full.
    public var heading: String? {
        guard let text = permissionMeta("title") ?? toolCall("title"),
              let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        let more = line.count > 160 || text.split(whereSeparator: \.isNewline).count > 1
        return more ? String(line.prefix(160)) + "…" : line
    }

    /// Why, when the agent says.
    public var reason: String? { permissionMeta("description") }

    /// The plan the agent asks to go ahead with, as Claude Code's ExitPlanMode sends it: the
    /// text of a mode switch's call.
    public var plan: String? {
        guard toolCall("kind") == "switch_mode", case let .object(call) = request.toolCall,
              case let .array(content)? = call["content"] else { return nil }
        let text = content.compactMap { item -> String? in
            guard case let .object(block) = item, case let .object(inner)? = block["content"],
                  case let .string(text)? = inner["text"] else { return nil }
            return text
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// The tool call's details the way the transcript shows a call's, or the JSON the agent sent
    /// when they cannot be described.
    public var toolDetails: String {
        var details = ""
        if case var .object(call) = request.toolCall {
            call["sessionUpdate"] = .string("tool_call")
            if call["toolCallId"] == nil { call["toolCallId"] = .string("permission") }
            if case let .toolCall(event, _) = ACPSessionNotification(sessionId: request.sessionId, update: .object(call)).event {
                var summary = ToolCallDetails()
                summary.apply(event)
                details = summary.text
            }
        }
        return details.isEmpty ? fullRequest : details
    }

    /// Everything the agent sent about the call, so what is approved can be read to its end:
    /// the details above are clipped for reading.
    public var fullRequest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(request.toolCall)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return text.count > 200_000 ? String(text.prefix(200_000)) + "\n[truncated]" : text
    }

    /// The agent's own words for an option, such as "Yes, and don't ask again for git
    /// commands", shown under Latch's label and never in its place; nil when they add nothing,
    /// as "Allow" under Allow Once does.
    public func detail(for option: ACPPermissionOption) -> String? {
        let name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        guard !name.isEmpty, !words(name).isSubset(of: words(option.permissionLabel ?? "")) else { return nil }
        // Words that say the opposite of the choice they sit under are not shown at all.
        let first = name.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "’" }.first.map(String.init) ?? ""
        let refusing: Set<String> = ["no", "reject", "deny", "decline", "cancel", "stop", "don't", "don’t", "never", "keep"]
        let agreeing: Set<String> = ["yes", "allow", "approve", "accept", "ok", "okay", "always", "proceed", "continue"]
        switch option.kind {
        case "allow_once", "allow_always": if refusing.contains(first) { return nil }
        case "reject_once", "reject_always": if agreeing.contains(first) { return nil }
        default: break
        }
        return name
    }

    private func permissionMeta(_ key: String) -> String? {
        guard case let .object(meta)? = request.meta, case let .object(permission)? = meta["permission"],
              case let .string(value)? = permission[key], !value.isEmpty else { return nil }
        return value
    }

    private func toolCall(_ key: String) -> String? {
        guard case let .object(call) = request.toolCall, case let .string(value)? = call[key], !value.isEmpty else { return nil }
        return value
    }
}

extension ACPPermissionOption {
    /// Trusted labels prevent an agent-provided name from disguising an allow option as a rejection.
    /// Who keeps an "Always" is said beside the buttons, not in them.
    public var permissionLabel: String? {
        switch kind {
        case "allow_once": "Allow Once"
        case "allow_always": "Always Allow"
        case "reject_once": "Reject Once"
        case "reject_always": "Always Reject"
        default: nil
        }
    }
}
