import Foundation
import LatchACP
import LatchServiceProtocol
import XCTest
@testable import LatchSessionKit

final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func ago(_ seconds: TimeInterval) -> String {
        RelativeTime.since(now.addingTimeInterval(-seconds), now: now, calendar: utc, locale: Locale(identifier: "en_US"))
    }

    func testAgesReadInTheSidebarsShortUnits() {
        XCTAssertEqual(ago(0), "now")
        XCTAssertEqual(ago(59), "now")
        XCTAssertEqual(ago(60), "1m")
        XCTAssertEqual(ago(59 * 60), "59m")
        XCTAssertEqual(ago(3600), "1h")
        XCTAssertEqual(ago(23 * 3600 + 3599), "23h")
        XCTAssertEqual(ago(86_400), "1d")
        XCTAssertEqual(ago(6 * 86_400), "6d")
        XCTAssertEqual(ago(7 * 86_400), "1w")
        XCTAssertEqual(ago(34 * 86_400), "4w")
        XCTAssertEqual(ago(-300), "now", "A clock that moved back is not a negative age")
    }

    func testOlderThanFiveWeeksShowsTheDate() {
        let date = now.addingTimeInterval(-40 * 86_400)
        let shown = RelativeTime.since(date, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        XCTAssertFalse(shown.hasSuffix("w"))
        XCTAssertTrue(shown.contains(where: \.isNumber), "A month and day: \(shown)")
    }

    func testDurationIsPreciseWhileShort() {
        XCTAssertEqual(RelativeTime.duration(0), "0s")
        XCTAssertEqual(RelativeTime.duration(8), "8s")
        XCTAssertEqual(RelativeTime.duration(72), "1m 12s")
        XCTAssertEqual(RelativeTime.duration(3600 + 3 * 60 + 9), "1h 3m")
        XCTAssertEqual(RelativeTime.duration(-4), "0s")
    }

    func testSpokenDurationIsInWordsAndCutShort() {
        XCTAssertEqual(RelativeTime.spokenDuration(8), "8 seconds")
        XCTAssertEqual(RelativeTime.spokenDuration(75), "1 minute, 15 seconds")
        XCTAssertEqual(RelativeTime.spokenDuration(3_830), "1 hour, 3 minutes")
    }

    func testOlderSavedSessionsLoadWithoutATime() throws {
        let older = #"{"id":"00000000-0000-0000-0000-000000000001","workspacePath":"/tmp","title":"T","agentID":"codex","customCommand":"","draft":"","messages":[]}"#
        XCTAssertNil(try JSONDecoder().decode(SavedSession.self, from: Data(older.utf8)).lastActiveAt)
        var saved = try JSONDecoder().decode(SavedSession.self, from: Data(older.utf8))
        saved.lastActiveAt = now
        XCTAssertEqual(try JSONDecoder().decode(SavedSession.self, from: try JSONEncoder().encode(saved)).lastActiveAt, now)
    }

    @MainActor func testATurnMarksWhenItStartedAndWhenItEnded() async {
        let client = TurnClient()
        let model = SessionModel(makeClient: { client })
        var clock = now
        model.now = { clock }
        await model.connect(command: "/bin/sh", workspace: FileManager.default.temporaryDirectory)
        XCTAssertNil(model.lastActiveAt)
        clock = now.addingTimeInterval(10)
        let sent = clock
        await client.onPrompt { clock = self.now.addingTimeInterval(95) }
        await model.send("Go")
        XCTAssertEqual(model.promptStartedAt, sent)
        XCTAssertEqual(model.lastActiveAt, now.addingTimeInterval(95), "The finished turn is the latest activity")
        await model.disconnect()
    }
}

private actor TurnClient: AgentServiceClient {
    nonisolated let transportDescription = "turn timing mock"
    nonisolated let events: AsyncStream<LatchAgentEvent>
    private nonisolated let continuation: AsyncStream<LatchAgentEvent>.Continuation
    private var duringPrompt: (@MainActor () -> Void)?

    init() {
        let pair = AsyncStream<LatchAgentEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    nonisolated func close() { continuation.finish() }
    func onPrompt(_ body: @escaping @MainActor () -> Void) { duringPrompt = body }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .startRuntime(id, _):
            return .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init()))
        case let .newSession(id, _):
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: "session-1"))
        case let .prompt(id, _):
            if let duringPrompt { await duringPrompt() }
            return .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn"))
        case let .stopRuntime(id):
            return .runtimeStopped(runtimeID: id)
        default:
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected mock command")
        }
    }
}
