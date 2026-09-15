import AppKit
import XCTest
@testable import LatchMacUI

final class TranscriptRenderSchedulerTests: XCTestCase {
    @MainActor func testAsyncBurstCoalescesAndCanScheduleAnotherBurst() async {
        let gate = RenderWaitGate()
        let first = expectation(description: "First render")
        let second = expectation(description: "Second render")
        var renders = 0
        let scheduler = TranscriptRenderScheduler(wait: { await gate.wait() }) {
            renders += 1
            (renders == 1 ? first : second).fulfill()
        }
        scheduler.request()
        await fulfillment(of: [gate.entered(0)], timeout: 2)
        for _ in 0..<64 {
            scheduler.request()
            await Task.yield()
        }
        XCTAssertEqual(gate.count, 1)
        XCTAssertEqual(renders, 0)
        gate.release(0)
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(renders, 1)
        scheduler.request()
        await fulfillment(of: [gate.entered(1)], timeout: 2)
        gate.release(1)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(renders, 2)
        scheduler.flush()
        XCTAssertEqual(renders, 2, "An idle flush must not render")
    }

    @MainActor func testContinuousStreamUsesFirstDeadlineRatherThanDebouncing() async {
        let gate = RenderWaitGate()
        var history = ChatHistory()
        var rendered: [String] = []
        let first = expectation(description: "Render while stream remains active")
        let second = expectation(description: "Next frame")
        let scheduler = TranscriptRenderScheduler(wait: { await gate.wait() }) {
            rendered.append(history.messages.last!.text)
            (rendered.count == 1 ? first : second).fulfill()
        }
        history.appendAssistant("0")
        scheduler.request()
        await fulfillment(of: [gate.entered(0)], timeout: 2)
        for n in 1...16 {
            history.appendAssistant(" \(n)")
            scheduler.request()
            await Task.yield()
        }
        XCTAssertEqual(gate.count, 1, "Later chunks cannot replace the first deadline")
        XCTAssertFalse(gate.wasCancelled(0))
        gate.release(0)
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(rendered, [(0...16).map(String.init).joined(separator: " ")])
        history.appendAssistant(" still streaming")
        scheduler.request()
        await fulfillment(of: [gate.entered(1)], timeout: 2)
        XCTAssertEqual(rendered.count, 1)
        gate.release(1)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(rendered.last, history.messages.last?.text)
    }

    @MainActor func testCancelAndRequeueIgnoresStaleTask() async {
        let gate = RenderWaitGate()
        let staleRender = expectation(description: "Cancelled deadline must not flush replacement")
        staleRender.isInverted = true
        let currentRender = expectation(description: "Replacement deadline renders")
        var renders = 0
        let scheduler = TranscriptRenderScheduler(wait: { await gate.wait() }) {
            renders += 1
            (gate.isReleased(1) ? currentRender : staleRender).fulfill()
        }
        scheduler.request()
        await fulfillment(of: [gate.entered(0)], timeout: 2)
        scheduler.cancel()
        scheduler.cancel()
        scheduler.request()
        await fulfillment(of: [gate.entered(1)], timeout: 2)
        XCTAssertTrue(gate.wasCancelled(0))
        XCTAssertFalse(gate.wasCancelled(1))
        // The gate intentionally ignores cancellation and returns successfully.
        gate.release(0)
        await fulfillment(of: [gate.exited(0)], timeout: 2)
        await fulfillment(of: [staleRender], timeout: 0.05)
        XCTAssertEqual(renders, 0)
        gate.release(1)
        await fulfillment(of: [currentRender], timeout: 2)
        XCTAssertEqual(renders, 1)
    }

    @MainActor func testExplicitStateFlushReadsLatestHistoryAndCancelsDeadline() async {
        let gate = RenderWaitGate()
        var history = ChatHistory()
        @MainActor final class State { var working = true }
        let state = State()
        var snapshots: [[ChatMessage]] = []
        var states: [Bool] = []
        let redundant = expectation(description: "No redundant delayed render")
        redundant.isInverted = true
        let scheduler = TranscriptRenderScheduler(wait: { await gate.wait() }) {
            snapshots.append(history.messages)
            states.append(state.working)
            if snapshots.count > 1 { redundant.fulfill() }
        }
        history.appendUser("Question")
        history.appendAssistant("First")
        scheduler.request()
        await fulfillment(of: [gate.entered(0)], timeout: 2)
        history.appendAssistant(" latest")
        history.updateTool(toolCallID: "tool", title: "Read", status: "completed")
        state.working = false
        scheduler.flush()
        XCTAssertEqual(snapshots, [history.messages], "Flush must read current state, not a request-time snapshot")
        XCTAssertEqual(states, [false])
        XCTAssertTrue(gate.wasCancelled(0))
        scheduler.flush()
        gate.release(0)
        await fulfillment(of: [gate.exited(0)], timeout: 2)
        await fulfillment(of: [redundant], timeout: 0.05)
        XCTAssertEqual(snapshots.count, 1)
    }

    @MainActor func testDeinitCancelsPendingWaitWithoutCallback() async {
        let gate = RenderWaitGate()
        let callback = expectation(description: "No callback after destruction")
        callback.isInverted = true
        var scheduler: TranscriptRenderScheduler? = TranscriptRenderScheduler(wait: { await gate.wait() }) {
            callback.fulfill()
        }
        weak var weakScheduler = scheduler
        scheduler?.request()
        await fulfillment(of: [gate.entered(0)], timeout: 2)
        scheduler = nil
        XCTAssertNil(weakScheduler, "Pending task must not retain its owner")
        XCTAssertTrue(gate.wasCancelled(0))
        gate.release(0)
        await fulfillment(of: [gate.exited(0)], timeout: 2)
        await fulfillment(of: [callback], timeout: 0.05)
    }

    @MainActor func testEightSessionsHaveIndependentPendingDeadlines() async {
        let gates = (0..<8).map { _ in RenderWaitGate() }
        let rendered = (0..<8).map { expectation(description: "Session \($0)") }
        var counts = Array(repeating: 0, count: 8)
        let schedulers = (0..<8).map { index in
            TranscriptRenderScheduler(wait: { await gates[index].wait() }) {
                counts[index] += 1
                rendered[index].fulfill()
            }
        }
        defer { withExtendedLifetime(schedulers) {} }
        for scheduler in schedulers { scheduler.request() }
        await fulfillment(of: gates.map { $0.entered(0) }, timeout: 2)
        for _ in 0..<32 {
            for scheduler in schedulers { scheduler.request() }
            await Task.yield()
        }
        XCTAssertEqual(gates.map(\.count), Array(repeating: 1, count: 8))
        for index in [5, 0, 7, 2, 6, 1, 4, 3] {
            gates[index].release(0)
            await fulfillment(of: [rendered[index]], timeout: 2)
            XCTAssertEqual(counts[index], 1)
            for other in 0..<8 where !gates[other].isReleased(0) {
                XCTAssertEqual(counts[other], 0)
                XCTAssertFalse(gates[other].wasCancelled(0))
            }
        }
        XCTAssertEqual(counts, Array(repeating: 1, count: 8))
    }

    @MainActor func testStreamingRenderingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["LATCH_STREAMING_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with LATCH_STREAMING_BENCHMARK=1 swift test -c release --filter TranscriptRenderSchedulerTests")
        }
        #if DEBUG
        throw XCTSkip("Rendering benchmark requires -c release")
        #else
        _ = NSApplication.shared
        let chunks = (0..<128).map { $0.isMultiple(of: 8) ? "\n\n**Update** `code` " : "token " }
        let archive = (0..<24).map {
            ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
                        text: "History \($0): " + String(repeating: "retained text ", count: 12))
        }
        for sessionCount in [1, 8] {
            var baseline: [[String]] = []
            for coalesced in [false, true] {
                autoreleasepool {
                    let sessions = (0..<sessionCount).map { _ in RenderBenchmarkSession(archive: archive) }
                    // No real-time sleeps: each eight chunks represent one simulated frame.
                    // This measures update/Markdown/layout CPU work, not presentation or FPS.
                    let schedulers = sessions.map { session in
                        TranscriptRenderScheduler(wait: { throw CancellationError() }) { session.render() }
                    }
                    let elapsed = ContinuousClock().measure {
                        for (index, chunk) in chunks.enumerated() {
                            for (session, scheduler) in zip(sessions, schedulers) {
                                autoreleasepool {
                                    session.history.appendAssistant(chunk)
                                    if coalesced {
                                        scheduler.request()
                                        if (index + 1).isMultiple(of: 8) { scheduler.flush() }
                                    } else { session.render() }
                                }
                            }
                        }
                        for scheduler in schedulers { scheduler.flush() }
                    }
                    let counts = sessions.map(\.updates)
                    XCTAssertEqual(counts, Array(repeating: coalesced ? 16 : 128, count: sessionCount))
                    let finalText = sessions.map { $0.history.messages.map(\.text) }
                    if coalesced { XCTAssertEqual(finalText, baseline) } else { baseline = finalText }
                    for session in sessions {
                        XCTAssertEqual(session.view.messageCount, session.history.messages.count)
                        session.view.search("token")
                        XCTAssertEqual(session.view.matchCount, 112, "Actual rendered view contains the final stream")
                    }
                    print("STREAMING_BENCHMARK sessions=\(sessionCount) chunks_per_session=\(chunks.count) archived_rows=\(archive.count) mode=\(coalesced ? "coalesced" : "per-chunk") updates=\(counts.reduce(0, +)) updates_per_session=\(counts) elapsed=\(elapsed) simulated_chunks_per_frame=8 (simulated pacing; not FPS; setup excluded)")
                }
            }
        }
        #endif
    }
}

// Cancellation is recorded synchronously but deliberately does not resume the wait.
// Tests control exact deadline delivery, including successful returns from stale waits.
// Short inverted-expectation windows only observe forbidden callbacks; they do not pace streams.
private final class RenderWaitGate: @unchecked Sendable {
    private struct Slot {
        let entered: XCTestExpectation
        let exited: XCTestExpectation
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false
        var released = false
    }
    private let lock = NSLock()
    private var slots: [Slot] = (0..<256).map {
        Slot(entered: XCTestExpectation(description: "Wait \($0) entered"),
             exited: XCTestExpectation(description: "Wait \($0) exited"))
    }
    private var next = 0
    var count: Int { lock.withLock { next } }
    func entered(_ index: Int) -> XCTestExpectation { lock.withLock { slots[index].entered } }
    func exited(_ index: Int) -> XCTestExpectation { lock.withLock { slots[index].exited } }
    func wasCancelled(_ index: Int) -> Bool { lock.withLock { slots[index].cancelled } }
    func isReleased(_ index: Int) -> Bool { lock.withLock { slots[index].released } }

    func wait() async {
        let index = lock.withLock { let index = next; next += 1; return index }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock { slots[index].continuation = continuation }
                entered(index).fulfill()
            }
        } onCancel: {
            self.lock.withLock { self.slots[index].cancelled = true }
        }
        exited(index).fulfill()
    }

    func release(_ index: Int) {
        let continuation = lock.withLock {
            let continuation = slots[index].continuation
            slots[index].continuation = nil
            slots[index].released = true
            return continuation
        }
        XCTAssertNotNil(continuation, "Release only an entered, unreleased wait")
        continuation?.resume()
    }
}

@MainActor private final class RenderBenchmarkSession {
    var history = ChatHistory()
    let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var updates = 0

    init(archive: [ChatMessage]) {
        history.restore(archive)
        history.appendAssistant("Streaming response: ")
        view.update(messages: history.messages, isWorking: true)
        view.layoutSubtreeIfNeeded()
    }

    func render() {
        view.update(messages: history.messages, isWorking: true)
        updates += 1
    }
}
