#if canImport(Network)
import Synchronization

/// A value delivered at most once to at most one waiter. `finish` may come before the wait
/// starts, after it, or race with cancellation; every later `finish` is ignored.
final class LatchRemoteOneShot<Value: Sendable>: Sendable {
    private enum Slot {
        case empty
        case waiting(CheckedContinuation<Value, any Error>)
        case finished(Result<Value, any Error>)
        case consumed
    }

    private let slot = Mutex(Slot.empty)

    func finish(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = slot.withLock { slot in
            switch slot {
            case .empty:
                slot = .finished(result)
                return nil
            case let .waiting(continuation):
                slot = .consumed
                return continuation
            case .finished, .consumed:
                return nil
            }
        }
        continuation?.resume(with: result)
    }

    /// Waits for `finish`. Cancelling the task finishes with `CancellationError` and then runs
    /// `onCancel`, so the producer can forget the waiter.
    func wait(onCancel: @escaping @Sendable () -> Void = {}) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Value, any Error>? = slot.withLock { slot in
                    switch slot {
                    case .empty:
                        slot = .waiting(continuation)
                        return nil
                    case let .finished(result):
                        slot = .consumed
                        return result
                    case .waiting, .consumed:
                        preconditionFailure("A one-shot is awaited once")
                    }
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
            onCancel()
        }
    }
}
#endif
