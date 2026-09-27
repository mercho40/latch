import Foundation
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest
@testable import LatchAgentServer

final class RemoteEventJournalTests: XCTestCase {
    private let first = AgentRuntimeID("first")
    private let second = AgentRuntimeID("second")

    func testTheLargestCursorAClientCanSendIsAnswered() {
        let journal = RemoteEventJournal(runtimeBudget: 1000, globalBudget: 1000, clock: { .now })
        let connection = journal.openConnection(wake: {})
        XCTAssertEqual(journal.subscribe(connection, to: first, after: .max).backlogFrom, .max)
        journal.createRuntime(first)
        journal.append(event(100), to: first)
        let known = journal.subscribe(connection, to: first, after: .max)
        XCTAssertEqual(known.backlogFrom, 2)
        XCTAssertTrue(known.truncated)
    }

    func testGlobalBudgetEvictsTheOldestAcrossRuntimes() throws {
        let journal = RemoteEventJournal(runtimeBudget: 1000, globalBudget: 250, clock: { .now })
        journal.createRuntime(first)
        journal.createRuntime(second)
        journal.append(event(100), to: first)
        journal.append(event(100), to: second)
        journal.append(event(100), to: second)
        XCTAssertEqual(journal.byteCount, 200)

        let connection = journal.openConnection(wake: {})
        XCTAssertEqual(journal.subscribe(connection, to: first, after: 0).truncated, true)
        XCTAssertEqual(journal.subscribe(connection, to: second, after: 0).truncated, false)
        journal.activate(connection, runtimeID: first)
        journal.activate(connection, runtimeID: second)
        let frames = try decode(journal.pull(connection, byteBudget: 1 << 20))
        XCTAssertEqual(frames.map(\.runtimeID), [second, second])

        // The event just appended survives even when it alone is over budget. The attach
        // already reported losing the first event, so its frame carries no second gap.
        journal.append(event(400), to: first)
        XCTAssertEqual(journal.byteCount, 400)
        let big = try decode(journal.pull(connection, byteBudget: 1))
        XCTAssertEqual(big.map(\.sequence), [2])
        XCTAssertEqual(big.map(\.gap), [false])

        // An eviction after the attach is a gap.
        journal.append(event(100), to: second)
        journal.append(event(200), to: first)
        journal.append(event(200), to: first)
        let evicted = try decode(journal.pull(connection, byteBudget: 1 << 20))
        XCTAssertEqual(evicted.map(\.runtimeID), [first])
        XCTAssertEqual(evicted.map(\.sequence), [4])
        XCTAssertEqual(evicted.map(\.gap), [true])
    }

    func testRetiredEventsWaitForTheSlowestCursor() throws {
        let journal = RemoteEventJournal(runtimeBudget: 1000, globalBudget: 1000, clock: { .now })
        journal.createRuntime(first)
        for _ in 0..<3 { journal.append(event(40), to: first) }
        let behind = journal.openConnection(wake: {})
        let ahead = journal.openConnection(wake: {})
        for connection in [behind, ahead] {
            _ = journal.subscribe(connection, to: first, after: 0)
            journal.activate(connection, runtimeID: first)
        }
        XCTAssertEqual(try decode(journal.pull(ahead, byteBudget: 1 << 20)).map(\.sequence), [1, 2, 3])
        journal.retire(first, through: 3)
        journal.append(event(40), to: first)
        XCTAssertEqual(journal.byteCount, 160)

        let caughtUp = try decode(journal.pull(behind, byteBudget: 1 << 20))
        XCTAssertEqual(caughtUp.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(caughtUp.map(\.gap), [false, false, false, false])
        XCTAssertEqual(journal.byteCount, 40)

        // A later attach learns of the loss once, from the reply.
        let late = journal.openConnection(wake: {})
        XCTAssertEqual(journal.subscribe(late, to: first, after: 0).backlogFrom, 4)
        journal.activate(late, runtimeID: first)
        XCTAssertEqual(try decode(journal.pull(late, byteBudget: 1 << 20)).map(\.gap), [false])
    }

    func testRetiredEventsGoWhenTheSlowestCursorLeaves() {
        let journal = RemoteEventJournal(runtimeBudget: 1000, globalBudget: 1000, clock: { .now })
        journal.createRuntime(first)
        journal.append(event(40), to: first)
        let idle = journal.openConnection(wake: {})
        _ = journal.subscribe(idle, to: first, after: 0)
        journal.retire(first, through: 1)
        XCTAssertEqual(journal.byteCount, 40)
        journal.closeConnection(idle)
        XCTAssertEqual(journal.byteCount, 0)
    }

    func testCursorBeyondTheJournalIsClamped() throws {
        let journal = RemoteEventJournal(runtimeBudget: 1000, globalBudget: 1000, clock: { .now })
        journal.createRuntime(first)
        journal.append(event(40), to: first)
        let connection = journal.openConnection(wake: {})
        // Only another runtime under the same ID could have sent that cursor.
        let subscription = journal.subscribe(connection, to: first, after: 99)
        XCTAssertEqual(subscription.backlogFrom, 2)
        XCTAssertTrue(subscription.truncated)
        journal.activate(connection, runtimeID: first)
        journal.append(event(40), to: first)
        XCTAssertEqual(try decode(journal.pull(connection, byteBudget: 1 << 20)).map(\.sequence), [2])
    }

    func testDetachedSinceFollowsTheLastConnection() {
        let clock = TestClock()
        let journal = RemoteEventJournal(runtimeBudget: 1000, globalBudget: 1000, clock: { clock.now })
        journal.createRuntime(first)
        XCTAssertEqual(journal.detachedSince(first), clock.base)

        let one = journal.openConnection(wake: {})
        let two = journal.openConnection(wake: {})
        _ = journal.subscribe(one, to: first, after: 0)
        _ = journal.subscribe(one, to: first, after: 0)
        _ = journal.subscribe(two, to: first, after: 0)
        XCTAssertNil(journal.detachedSince(first))
        clock.set(.seconds(5))
        journal.closeConnection(one)
        XCTAssertNil(journal.detachedSince(first))
        clock.set(.seconds(9))
        journal.unsubscribe(two, from: first)
        XCTAssertEqual(journal.detachedSince(first), clock.base + .seconds(9))
        journal.unsubscribe(two, from: first)
        XCTAssertEqual(journal.detachedSince(first), clock.base + .seconds(9))
    }

    func testRemovedRuntimeLeavesNoCursorsOrBytes() throws {
        let journal = RemoteEventJournal(runtimeBudget: 1000, globalBudget: 1000, clock: { .now })
        journal.createRuntime(first)
        journal.append(event(40), to: first)
        let connection = journal.openConnection(wake: {})
        _ = journal.subscribe(connection, to: first, after: 0)
        journal.activate(connection, runtimeID: first)
        journal.removeRuntime(first)
        XCTAssertEqual(journal.byteCount, 0)
        XCTAssertEqual(journal.pull(connection, byteBudget: 1 << 20), [])
        XCTAssertNil(journal.append(event(40), to: first))
    }

    /// An encoded event of exactly `size` bytes.
    private func event(_ size: Int) -> Data {
        let prefix = #"{"kind":"x","pad":""#
        let suffix = #""}"#
        return Data((prefix + String(repeating: "a", count: size - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
    }

    private func decode(_ lines: [Data]) throws -> [LatchRemoteEventFrame] {
        try lines.map { line in
            guard case let .event(frame) = try LatchRemoteCoding.decode(LatchRemoteServerFrame.self, fromLine: line.dropLast()) else {
                throw HubTestError.unexpected("not an event")
            }
            return frame
        }
    }
}
