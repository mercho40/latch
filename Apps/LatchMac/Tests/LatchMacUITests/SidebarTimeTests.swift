import AppKit
import XCTest
@testable import LatchMacUI

/// The sidebar's use of `RelativeTime`, which the shared session layer tests on its own.
final class SidebarTimeTests: XCTestCase {
    @MainActor func testTheTimeTakesTheSlotOnlyAtRest() throws {
        let cell = SessionCellView(identifier: .init("session"))
        cell.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        func timeLabel() -> NSTextField? { cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "3h" } }
        cell.configure(title: "Fix retry backoff", status: .resting, detail: "Codex", time: "3h", spokenTime: "3 hours ago")
        XCTAssertEqual(timeLabel()?.isHidden, false)
        XCTAssertTrue(cell.accessibilityLabel()?.hasSuffix("active 3 hours ago") == true)
        cell.configure(title: "Fix retry backoff", status: .working, detail: "Working · 12s", time: "3h", spokenTime: "3 hours ago")
        XCTAssertEqual(timeLabel()?.isHidden, true, "Work in progress says more than when it last moved")
        cell.configure(title: "Fix retry backoff", status: .resting, detail: "Codex", time: "3h", spokenTime: "3 hours ago")
        cell.mouseEntered(with: NSEvent())
        XCTAssertEqual(timeLabel()?.isHidden, true, "The close button takes the slot under the pointer")
    }
}
