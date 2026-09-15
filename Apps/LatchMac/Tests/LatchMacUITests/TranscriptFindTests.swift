import AppKit
import XCTest
@testable import LatchMacUI

/// ⌘F searches the conversation on screen: every visible message, in reading order.
@MainActor
final class TranscriptFindTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testFindBarOpensAndClosesWithoutDisturbingTheTranscript() {
        let transcript = make(messages: [ChatMessage(role: .user, text: "alpha beta")])
        XCTAssertFalse(transcript.isFindBarVisible)

        transcript.beginFind()
        XCTAssertTrue(transcript.isFindBarVisible)

        transcript.search("beta")
        XCTAssertEqual(transcript.matchCount, 1)

        transcript.endFind()
        XCTAssertFalse(transcript.isFindBarVisible)
        XCTAssertEqual(transcript.matchCount, 0, "Closing the bar drops the matches")
        XCTAssertEqual(transcript.messageCount, 1, "Find never changes the conversation")
    }

    func testMatchesAreFoundAcrossMessagesInOrder() {
        let transcript = make(messages: [
            ChatMessage(role: .user, text: "needle in the first"),
            ChatMessage(role: .user, text: "second has needle and NEEDLE"),
        ])

        transcript.search("needle")

        // Case-insensitive, every message, first match selected.
        XCTAssertEqual(transcript.matchCount, 3)
        XCTAssertEqual(transcript.currentMatch, 1)
        XCTAssertTrue(transcript.canStepMatches)
    }

    func testSteppingWrapsInBothDirections() {
        let transcript = make(messages: [ChatMessage(role: .user, text: "one two one two one")])

        transcript.search("one")
        XCTAssertEqual(transcript.matchCount, 3)

        transcript.findNext()
        XCTAssertEqual(transcript.currentMatch, 2)
        transcript.findNext()
        transcript.findNext()
        XCTAssertEqual(transcript.currentMatch, 1, "Next wraps to the first match")

        transcript.findPrevious()
        XCTAssertEqual(transcript.currentMatch, 3, "Previous wraps to the last match")
    }

    func testNoMatchesLeavesNothingToStepThrough() {
        let transcript = make(messages: [ChatMessage(role: .user, text: "alpha")])

        transcript.search("omega")

        XCTAssertEqual(transcript.matchCount, 0)
        XCTAssertEqual(transcript.currentMatch, 0)
        XCTAssertFalse(transcript.canStepMatches)
        transcript.findNext()
        XCTAssertEqual(transcript.currentMatch, 0)
    }

    func testCollapsedToolRowsAreNotSearched() {
        let transcript = make(messages: [
            ChatMessage(role: .user, text: "visible needle"),
            ChatMessage(role: .tool, text: "Read · running\nhidden needle"),
        ])

        transcript.search("needle")

        // A collapsed tool row has nothing on screen to reveal, so it is skipped.
        XCTAssertEqual(transcript.matchCount, 1)
    }

    func testStreamingKeepsTheCurrentMatch() {
        var messages = [ChatMessage(role: .user, text: "needle one"),
                        ChatMessage(role: .user, text: "needle two")]
        let transcript = make(messages: messages)
        transcript.search("needle")
        transcript.findNext()
        XCTAssertEqual(transcript.currentMatch, 2)

        messages[1].text += " and more text arriving"
        transcript.update(messages: messages, isWorking: true)

        XCTAssertEqual(transcript.matchCount, 2)
        XCTAssertEqual(transcript.currentMatch, 2, "A streaming update must not jump the reader")
    }

    private func make(messages: [ChatMessage]) -> ChatTranscriptView {
        let transcript = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        transcript.update(messages: messages, isWorking: false)
        return transcript
    }
}
