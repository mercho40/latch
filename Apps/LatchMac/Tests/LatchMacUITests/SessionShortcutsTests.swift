import AppKit
import XCTest
@testable import LatchMacUI
import LatchSessionKit

@MainActor
final class SessionShortcutsTests: XCTestCase {
    func testCommandNumbersGoToTheSessionsInOrderAndNineToTheLast() {
        XCTAssertEqual(SessionShortcut.index(forNumber: 1, count: 3), 0)
        XCTAssertEqual(SessionShortcut.index(forNumber: 3, count: 3), 2)
        XCTAssertNil(SessionShortcut.index(forNumber: 4, count: 3), "No fourth session")
        XCTAssertEqual(SessionShortcut.index(forNumber: 9, count: 3), 2)
        XCTAssertEqual(SessionShortcut.index(forNumber: 9, count: 12), 11)
        XCTAssertNil(SessionShortcut.index(forNumber: 1, count: 0))
        XCTAssertNil(SessionShortcut.index(forNumber: 0, count: 3))
    }

    func testTheShortcutsSelectSessionsFromTheSessionMenu() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1), fixture.session(2), fixture.session(3))
            let item = NSMenuItem(title: "Session 2", action: #selector(SessionWindowController.goToSession(_:)), keyEquivalent: "2")
            item.tag = 2
            XCTAssertTrue(window.validateMenuItem(item))
            window.goToSession(item)
            XCTAssertTrue(sidebar.selectedSession === sidebar.allSessions[1])
            item.tag = 9
            window.goToSession(item)
            XCTAssertTrue(sidebar.selectedSession === sidebar.allSessions[2])
            item.tag = 5
            XCTAssertFalse(window.validateMenuItem(item))
        }
    }

    func testASessionCanBeMarkedUnreadAndReadFromItsRow() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(fixture.session(1), fixture.session(2))
            let session = sidebar.allSessions[1]
            XCTAssertFalse(session.hasUnseenReply)
            let unread = try XCTUnwrap(sidebar.contextMenuItems(for: session).first { $0.title == "Mark as Unread" })
            _ = unread.target?.perform(unread.action, with: unread)
            XCTAssertTrue(session.hasUnseenReply)
            let read = try XCTUnwrap(sidebar.contextMenuItems(for: session).first { $0.title == "Mark as Read" })
            _ = read.target?.perform(read.action, with: read)
            XCTAssertFalse(session.hasUnseenReply)
        }
    }

    func testARestingSessionWithADraftSaysSo() {
        XCTAssertEqual(SessionViewController.draftDetail("\n  Fix the flaky test\nand the docs"), "Draft: Fix the flaky test")
        XCTAssertNil(SessionViewController.draftDetail(" \n\t\n"))
        XCTAssertEqual(SessionViewController.draftDetail(String(repeating: "x", count: 200))?.count, 87)
    }
}
