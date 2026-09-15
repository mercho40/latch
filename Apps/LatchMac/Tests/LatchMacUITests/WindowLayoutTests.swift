import AppKit
import XCTest
@testable import LatchMacUI

@MainActor
final class WindowLayoutTests: XCTestCase {
    private func layout(_ window: NSWindow, passes: Int = 20) {
        for _ in 0..<passes {
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func testDividerPositionsSurviveRepeatedLayoutAndWindowResize() async throws {
        try await WindowFixture.run { fixture in
            let (controller, sidebar) = try await fixture.restored(fixture.session(1))
            let window = try XCTUnwrap(controller.window)
            let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
            split.splitView.autosaveName = nil
            window.setContentSize(NSSize(width: 1200, height: 720))
            layout(window)
            for width: CGFloat in [220, 320, 260, 350, 200] {
                split.splitView.setPosition(width, ofDividerAt: 0)
                layout(window)
                XCTAssertEqual(sidebar.view.frame.width, width, accuracy: 1)
            }
            for width: CGFloat in [1500, 820, 1200] {
                window.setContentSize(NSSize(width: width, height: 720))
                layout(window)
                XCTAssertEqual(sidebar.view.frame.width, 200, accuracy: 1)
                XCTAssertGreaterThanOrEqual(split.children.last!.view.frame.width, 560)
            }
        }
    }
}
