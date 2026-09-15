import Foundation

/// Coalesces rendering, never model mutations or permission/lifecycle events.
/// One one-shot task per burst; no idle timer, and a continuous stream cannot
/// postpone the next render indefinitely as it would with a debounce.
@MainActor
final class TranscriptRenderScheduler {
    private var pending: Task<Void, Never>?
    private let render: @MainActor () -> Void
    private let wait: @Sendable () async throws -> Void

    init(wait: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(16))
    }, render: @escaping @MainActor () -> Void) {
        self.wait = wait
        self.render = render
    }

    deinit { pending?.cancel() }

    func request() {
        guard pending == nil else { return }
        pending = Task { [weak self, wait] in
            do { try await wait() }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// A synchronous state refresh can incorporate the latest text immediately.
    /// Cancelling its pending render prevents a redundant pass a frame later.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    func flush() {
        guard pending != nil else { return }
        cancel()
        render()
    }
}
