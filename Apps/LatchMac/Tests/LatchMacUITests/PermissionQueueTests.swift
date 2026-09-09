import Foundation
import LatchACP
import XCTest
@testable import LatchMacUI

final class PermissionQueueTests: XCTestCase {
    private let request = ACPPermissionRequest(
        sessionId: "session-1", toolCall: .object(["title": .string("Read a file")]),
        options: [
            .init(optionId: "yes", name: "Reject (misleading agent name)", kind: "allow_once"),
            .init(optionId: "no", name: "No", kind: "reject_once"),
            .init(optionId: "future", name: "Unknown", kind: "future_kind"),
        ]
    )

    @MainActor func testExplicitOfferedSelectionAndStaleCallbackIsolation() async throws {
        let queue = PermissionQueue()
        let first = Task { await queue.request(request) }
        let id = try await waitForPrompt(queue)
        XCTAssertEqual(queue.current?.options.map(\.permissionLabel), ["Allow Once", "Reject Once"])
        queue.resolve(id: id, optionID: "future")
        XCTAssertEqual(queue.current?.id, id)
        queue.resolve(id: id, optionID: "not-offered")
        XCTAssertEqual(queue.current?.id, id)
        queue.resolve(id: id, optionID: "yes")
        let outcome = await first.value
        XCTAssertEqual(outcome, .selected(optionID: "yes"))

        let second = Task { await queue.request(request) }
        let next = try await waitForPrompt(queue)
        queue.resolve(id: id, optionID: "yes")
        XCTAssertEqual(queue.current?.id, next)
        queue.resolve(id: next, optionID: "no")
        let rejection = await second.value
        XCTAssertEqual(rejection, .selected(optionID: "no"))
        XCTAssertNil(queue.current)
    }

    @MainActor func testTaskCancellationRemovesPendingDecision() async throws {
        let queue = PermissionQueue()
        let task = Task { await queue.request(request) }
        _ = try await waitForPrompt(queue)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(queue.current)
    }

    @MainActor func testCancellationWinsOverClickBeforeCleanupRuns() async throws {
        let queue = PermissionQueue()
        let task = Task { await queue.request(request) }
        let id = try await waitForPrompt(queue)
        task.cancel()
        queue.resolve(id: id, optionID: "yes")
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(queue.current)
    }

    @MainActor func testCancelAllDrainsQueuedRequests() async throws {
        let queue = PermissionQueue()
        let first = Task { await queue.request(request) }
        let id = try await waitForPrompt(queue)
        let queued = expectation(description: "Second request queued")
        queue.onChange = { queued.fulfill(); queue.onChange = nil }
        let second = Task { await queue.request(request) }
        await fulfillment(of: [queued], timeout: 2)
        XCTAssertEqual(queue.current?.id, id)
        queue.cancelAll()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(secondOutcome, .cancelled)
        queue.cancelAll()
        XCTAssertNil(queue.current)
    }

    @MainActor func testQueueOverflowIsCancelled() async {
        let queue = PermissionQueue()
        var tasks: [Task<ACPPermissionOutcome, Never>] = []
        for _ in 0..<16 {
            let queued = expectation(description: "Request queued")
            queue.onChange = { queued.fulfill(); queue.onChange = nil }
            tasks.append(Task { await queue.request(request) })
            await fulfillment(of: [queued], timeout: 2)
        }
        let overflow = await queue.request(request)
        XCTAssertEqual(overflow, .cancelled)
        queue.cancelAll()
        for task in tasks {
            let outcome = await task.value
            XCTAssertEqual(outcome, .cancelled)
        }
        XCTAssertNil(queue.current)
    }

    @MainActor func testDuplicateOptionIDsFailClosed() async {
        let queue = PermissionQueue()
        let outcome = await queue.request(ACPPermissionRequest(
            sessionId: "session-1", toolCall: .null,
            options: [request.options[0], request.options[0]]
        ))
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(queue.current)
    }

    @MainActor private func waitForPrompt(_ queue: PermissionQueue) async throws -> UUID {
        let deadline = ContinuousClock.now + .seconds(2)
        while queue.current == nil {
            if ContinuousClock.now >= deadline { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
        return queue.current!.id
    }
}

private enum WaitError: Error { case timedOut }
