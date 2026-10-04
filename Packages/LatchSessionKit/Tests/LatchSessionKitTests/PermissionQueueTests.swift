import Foundation
import LatchACP
import XCTest
@testable import LatchSessionKit

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

    func testAlwaysOptionsAreLabelledPlainly() {
        let labels = ["allow_once", "allow_always", "reject_once", "reject_always"].map {
            ACPPermissionOption(optionId: $0, name: "Agent's own name", kind: $0).permissionLabel
        }
        XCTAssertEqual(labels, ["Allow Once", "Always Allow", "Reject Once", "Always Reject"])
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

    /// Claude Code's plan approval: its own heading and reason, the plan, and its words for
    /// each option under Latch's labels.
    @MainActor func testAPlanApprovalShowsTheAgentsHeadingPlanAndWords() {
        let request = ACPPermissionRequest(
            sessionId: "s",
            toolCall: .object(["toolCallId": .string("plan-1"), "title": .string("Ready to code?"), "kind": .string("switch_mode"),
                               "content": .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("1. Read\n2. Fix")])])])]),
            options: [ACPPermissionOption(optionId: "exit-plan-default", name: "Yes, manually approve edits", kind: "allow_once"),
                      ACPPermissionOption(optionId: "reject", name: "Reject Once", kind: "reject_once")],
            meta: .object(["permission": .object(["version": .integer(1), "title": .string("Ready to code?"), "description": .string("Reason: the plan is done")])])
        )
        let prompt = PermissionQueue.Prompt(id: UUID(), request: request)
        XCTAssertEqual(prompt.heading, "Ready to code?")
        XCTAssertEqual(prompt.reason, "Reason: the plan is done")
        XCTAssertEqual(prompt.plan, "1. Read\n2. Fix")
        XCTAssertEqual(prompt.detail(for: request.options[0]), "Yes, manually approve edits")
        XCTAssertNil(prompt.detail(for: request.options[1]), "Words that only repeat the label add nothing")
        // Claude Code's usual names are a word of the label: under Allow Once, "Allow" says nothing more.
        XCTAssertNil(prompt.detail(for: ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")))
        XCTAssertNil(prompt.detail(for: ACPPermissionOption(optionId: "always", name: "always allow", kind: "allow_always")))
        XCTAssertNil(prompt.detail(for: ACPPermissionOption(optionId: "reject", name: "Reject", kind: "reject_once")))
        XCTAssertEqual(prompt.detail(for: ACPPermissionOption(optionId: "yes", name: "Yes", kind: "allow_once")), "Yes")
        // Words that say the opposite of the choice they would sit under are not shown.
        XCTAssertNil(prompt.detail(for: ACPPermissionOption(optionId: "trap", name: "No, keep planning", kind: "allow_once")))
        XCTAssertNil(prompt.detail(for: ACPPermissionOption(optionId: "trap", name: "Yes, go ahead", kind: "reject_once")))
        XCTAssertEqual(prompt.detail(for: ACPPermissionOption(optionId: "no", name: "No, keep planning", kind: "reject_once")), "No, keep planning")
        let plain = PermissionQueue.Prompt(id: UUID(), request: ACPPermissionRequest(
            sessionId: "s", toolCall: .object(["title": .string("git status"), "kind": .string("execute")]), options: []))
        XCTAssertEqual(plain.heading, "git status")
        // A heading is one line; the whole script is in the full request.
        let script = PermissionQueue.Prompt(id: UUID(), request: ACPPermissionRequest(
            sessionId: "s", toolCall: .object(["title": .string("cat <<'EOF' > a.sh\necho hi\nEOF"), "kind": .string("execute")]), options: []))
        XCTAssertEqual(script.heading, "cat <<'EOF' > a.sh…")
        XCTAssertTrue(script.fullRequest.contains("echo hi"))
        XCTAssertNil(plain.reason)
        XCTAssertNil(plain.plan)
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
