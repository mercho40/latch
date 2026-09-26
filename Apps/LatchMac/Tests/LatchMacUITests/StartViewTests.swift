import AppKit
import XCTest
@testable import LatchMacUI

final class StartViewTests: XCTestCase {
    func testOnlyExistingFoldersAreOfferedNewestFirstAndAtMostFive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("latch-recents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = try (1...7).map { index -> URL in
            let url = root.appendingPathComponent("workspace-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let file = root.appendingPathComponent("notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("deleted", isDirectory: true)
        let remote = try XCTUnwrap(URL(string: "https://example.com/project"))

        let offered = StartView.recentWorkspaces([missing, folders[0], file, remote] + Array(folders.dropFirst()))
        XCTAssertEqual(offered, Array(folders.prefix(5)))
    }

    @MainActor func testReloadListsTheRecentsAndOpensTheOneClicked() throws {
        let start = StartView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var opened: URL?
        start.onOpenWorkspace = { opened = $0 }
        let recent = FileManager.default.temporaryDirectory
        start.reload([recent])
        XCTAssertEqual(start.shownRecents, [recent])
        let row = try XCTUnwrap(Self.buttons(in: start).first { $0.accessibilityLabel() == "Start a session in \(recent.lastPathComponent)" })
        row.performClick(nil)
        XCTAssertEqual(opened, recent)

        start.reload([])
        XCTAssertTrue(start.shownRecents.isEmpty)
        let choose = try XCTUnwrap(Self.buttons(in: start).first { $0.title == "New Session…" })
        XCTAssertEqual(choose.keyEquivalent, "\r", "With nothing recent, Return chooses a folder")
    }

    @MainActor private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] + buttons(in: $0) }
    }
}
