import AppKit
@testable import LatchSessionKit
import XCTest
@testable import LatchMacUI

/// `TranscriptRenderScheduler` driving the Mac's transcript, measured. The scheduler's own
/// behaviour is tested with the shared session layer.
final class TranscriptStreamingBenchmarkTests: XCTestCase {
    @MainActor func testStreamingRenderingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["LATCH_STREAMING_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with LATCH_STREAMING_BENCHMARK=1 swift test -c release --filter TranscriptStreamingBenchmarkTests")
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
