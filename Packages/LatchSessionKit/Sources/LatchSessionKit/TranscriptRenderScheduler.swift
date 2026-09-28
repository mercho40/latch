import Foundation

/// Coalesces rendering, never model mutations or permission/lifecycle events.
/// One one-shot task per burst; no idle timer, and a continuous stream cannot
/// postpone the next render indefinitely as it would with a debounce.
@MainActor
public final class TranscriptRenderScheduler {
    private var pending: Task<Void, Never>?
    private let render: @MainActor () -> Void
    private let wait: @Sendable () async throws -> Void

    public init(wait: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(16))
    }, render: @escaping @MainActor () -> Void) {
        self.wait = wait
        self.render = render
    }

    deinit { pending?.cancel() }

    public func request() {
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
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    public func flush() {
        guard pending != nil else { return }
        cancel()
        render()
    }
}
