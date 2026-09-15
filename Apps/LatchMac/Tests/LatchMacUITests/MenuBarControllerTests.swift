import AppKit
import XCTest
@testable import LatchMacUI

/// The menu bar extra lists every session, whichever one the window happens to show.
@MainActor
final class MenuBarControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suite = "MenuBarControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testMenuListsSessionsWithTheirState() throws {
        let controller = MenuBarController(defaults: defaults, installsStatusItem: false)
        let waiting = row("Fix the parser", phase: .prompting, needsPermission: true)
        let idle = row("Read the README", phase: .ready, needsPermission: false)
        controller.sessions = { [waiting, idle] }

        let menu = controller.buildMenu()

        XCTAssertEqual(menu.items.first?.title, "1 waiting for a decision")
        XCTAssertFalse(try XCTUnwrap(menu.items.first).isEnabled, "The headline is not a command")
        let rows = menu.items.filter { $0.representedObject is UUID }
        XCTAssertEqual(rows.map(\.title), ["Fix the parser", "Read the README"])
        XCTAssertEqual(rows.first?.subtitle, "Waiting for a decision")
        XCTAssertEqual(rows.last?.subtitle, idle.status)
        XCTAssertNotNil(rows.first?.image)
        XCTAssertEqual(menu.items.map(\.title).suffix(2), ["Hide Menu Bar Icon", "Quit Latch"])
        XCTAssertNotNil(menu.items.first { $0.title == "New Session…" })
    }

    func testHeadlineCountsRunningSessionsWhenNothingIsWaiting() {
        let controller = MenuBarController(defaults: defaults, installsStatusItem: false)
        controller.sessions = { [self.row("One", phase: .prompting, needsPermission: false),
                                 self.row("Two", phase: .ready, needsPermission: false)] }

        XCTAssertEqual(controller.buildMenu().items.first?.title, "1 running")

        controller.sessions = { [self.row("One", phase: .ready, needsPermission: false)] }
        XCTAssertEqual(controller.buildMenu().items.first?.title, "1 session")

        controller.sessions = { [] }
        XCTAssertEqual(controller.buildMenu().items.first?.title, "No sessions")
    }

    func testChoosingASessionReportsIt() throws {
        let controller = MenuBarController(defaults: defaults, installsStatusItem: false)
        let session = row("Fix the parser", phase: .ready, needsPermission: false)
        controller.sessions = { [session] }
        var selected: UUID?
        controller.onSelect = { selected = $0 }
        let item = try XCTUnwrap(controller.buildMenu().items.first { $0.representedObject is UUID })

        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(selected, session.id)
    }

    func testVisibilityIsRememberedAndOnByDefault() {
        let controller = MenuBarController(defaults: defaults, installsStatusItem: false)
        XCTAssertTrue(controller.isVisible, "Latch runs agents in the background; the extra is the way back")

        controller.isVisible = false

        XCTAssertFalse(MenuBarController(defaults: defaults, installsStatusItem: false).isVisible)
    }

    private func row(_ title: String, phase: SessionModel.Phase, needsPermission: Bool) -> MenuBarSession {
        MenuBarSession(id: UUID(), title: title, status: "Connected · Codex",
                       phase: phase, needsPermission: needsPermission)
    }
}
