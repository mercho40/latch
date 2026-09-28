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
