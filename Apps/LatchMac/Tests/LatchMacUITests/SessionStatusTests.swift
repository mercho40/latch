import AppKit
import LatchACP
import XCTest
@testable import LatchMacUI

/// What the agent says about the session as a whole: its title, and how full its context is.
@MainActor
final class SessionStatusTests: XCTestCase {
    /// The agent's title replaces the first prompt's, and one it gave before, but never a rename.
    func testTheAgentsTitleNeverReplacesARename() {
        XCTAssertEqual(SessionViewController.adoptedTitle(current: "Fix the flaky test please", agentTitle: "Flaky test fix",
                                                          firstPrompt: "Fix the flaky test please\nIt fails on CI", adoptedBefore: nil), "Flaky test fix")
        XCTAssertEqual(SessionViewController.adoptedTitle(current: "Flaky test fix", agentTitle: "CI flake",
                                                          firstPrompt: "Fix the flaky test please", adoptedBefore: "Flaky test fix"), "CI flake")
        XCTAssertNil(SessionViewController.adoptedTitle(current: "My name for it", agentTitle: "CI flake",
                                                        firstPrompt: "Fix the flaky test please", adoptedBefore: "Flaky test fix"))
        XCTAssertNil(SessionViewController.adoptedTitle(current: "CI flake", agentTitle: "CI flake", firstPrompt: nil, adoptedBefore: nil))
        XCTAssertEqual(SessionViewController.adoptedTitle(current: "New Session", agentTitle: String(repeating: "x", count: 90),
                                                          firstPrompt: nil, adoptedBefore: nil)?.count, 60)
    }

    /// The agent's conversations newest first by the moment each changed, offsets counted;
    /// undated ones last, and each with its title and date.
    func testConversationsAreListedNewestFirst() {
        let conversations = [
            ACPSessionSummary(sessionId: "undated", cwd: "/srv", title: nil, updatedAt: nil),
            ACPSessionSummary(sessionId: "utc", cwd: "/srv", title: "Noon in London", updatedAt: "2026-10-01T12:00:00.000Z"),
            // An hour before the UTC one, though its clock reads later.
            ACPSessionSummary(sessionId: "berlin", cwd: "/srv", title: "One in Berlin", updatedAt: "2026-10-01T13:00:00+02:00"),
            ACPSessionSummary(sessionId: "later", cwd: "/srv", title: "Later", updatedAt: "2026-10-02T09:30:00Z"),
        ]
        XCTAssertEqual(SessionViewController.newestFirst(conversations).map(\.sessionId), ["later", "utc", "berlin", "undated"])
        XCTAssertEqual(SessionViewController.menuTitle(for: conversations[0]), "Untitled conversation")
        XCTAssertTrue(SessionViewController.menuTitle(for: conversations[3]).hasPrefix("Later — "))
    }

    /// The context note sits before the buttons when the row has room for it, and is left out
    /// rather than costing the composer a line when it has not.
    func testTheContextNoteOnlyTakesRoomTheRowHas() {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.addItem(withTitle: "Claude Opus")
        let send = NSButton(title: "Send", target: nil, action: nil)
        let note = NSTextField(labelWithString: "25% context")
        let controls = ComposerControlsView(pickers: [.init(picker)], actions: [send], accessory: note)
        controls.frame = NSRect(x: 0, y: 0, width: 600, height: ComposerControlsView.controlHeight)
        controls.layoutSubtreeIfNeeded()
        controls.layout()
        XCTAssertFalse(note.isHidden)
        XCTAssertLessThan(note.frame.maxX, send.frame.minX)
        XCTAssertGreaterThan(note.frame.minX, picker.frame.maxX)
        let height = controls.intrinsicContentSize.height
        // Too narrow for it even on the buttons' own row.
        controls.frame.size.width = 90
        controls.layout()
        XCTAssertTrue(note.isHidden)
        note.stringValue = ""
        controls.frame.size.width = 600
        controls.layout()
        XCTAssertTrue(note.isHidden, "Nothing to say, nothing shown")
        XCTAssertEqual(controls.intrinsicContentSize.height, height)
    }
}
