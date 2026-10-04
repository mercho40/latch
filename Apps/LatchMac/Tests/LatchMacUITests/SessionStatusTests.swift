import AppKit
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
