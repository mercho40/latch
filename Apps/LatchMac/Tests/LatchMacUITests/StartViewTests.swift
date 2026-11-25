import AppKit
import LatchAgentCore
import XCTest
@testable import LatchMacUI
@testable import LatchSessionKit

@MainActor
final class StartViewTests: XCTestCase {
    private let server = UUID(uuidString: "5E4E4000-0000-0000-0000-000000000001")!

    func testReloadListsTheRecentsAndOpensTheOneClicked() throws {
        let start = StartView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var opened: RecentPlace?
        start.onOpenPlace = { opened = $0 }
        let recent = FileManager.default.temporaryDirectory
        let place = RecentPlace(location: .local(recent), agent: nil, server: nil)
        start.reload([place], offersRemote: false)
        XCTAssertEqual(start.shownRecents, [place])
        let row = try XCTUnwrap(Self.buttons(in: start).first { $0.accessibilityLabel() == "Start a session in \(recent.lastPathComponent)" })
        row.performClick(nil)
        XCTAssertEqual(opened, place)

        start.reload([], offersRemote: false)
        XCTAssertTrue(start.shownRecents.isEmpty)
        let choose = try XCTUnwrap(Self.buttons(in: start).first { $0.title == "New Session…" })
        XCTAssertEqual(choose.keyEquivalent, "\r", "With nothing recent, Return chooses a folder")
        let remote = try XCTUnwrap(Self.buttons(in: start).first { $0.title == "New Remote Session…" })
        XCTAssertTrue(remote.isHidden, "No server to start one on")
    }

    func testAServersFolderIsListedByServerAndANewRemoteSessionIsOffered() throws {
        let start = StartView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var opened: RecentPlace?
        var asked = false
        start.onOpenPlace = { opened = $0 }
        start.onNewRemoteSession = { asked = true }
        let place = RecentPlace(location: .remote(serverID: server, path: "/srv/app"), agent: .codex, server: "vps")
        start.reload([place], offersRemote: true)

        let row = try XCTUnwrap(Self.buttons(in: start).first { $0.accessibilityLabel() == "Start a session in app on vps" })
        XCTAssertEqual(row.toolTip, "vps · /srv/app")
        let labels = row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(labels, ["vps · app", "/srv"])
        row.performClick(nil)
        XCTAssertEqual(opened?.location, .remote(serverID: server, path: "/srv/app"))
        XCTAssertEqual(opened?.agent, .codex)

        let remote = try XCTUnwrap(Self.buttons(in: start).first { $0.title == "New Remote Session…" })
        XCTAssertFalse(remote.isHidden)
        remote.performClick(nil)
        XCTAssertTrue(asked)

        start.reload([], offersRemote: true)
        let choose = try XCTUnwrap(Self.buttons(in: start).first { $0.title == "New Session…" })
        XCTAssertEqual(choose.keyEquivalent, "\r", "Return stays on a folder here")
        XCTAssertEqual(remote.keyEquivalent, "")
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] + buttons(in: $0) }
    }
}
