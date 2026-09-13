import AppKit
import XCTest
@testable import LatchMacUI

final class ComposerControlsViewTests: XCTestCase {
    @MainActor func testLargeControlsWrapWithoutOverlapAtNarrowWidths() {
        let (bar, controls) = makeBar()
        for width: CGFloat in [340, 440, 748] {
            bar.setFrameSize(NSSize(width: width, height: 200))
            bar.setFrameSize(NSSize(width: width, height: bar.intrinsicContentSize.height))
            bar.layoutSubtreeIfNeeded()
            for control in controls {
                XCTAssertGreaterThanOrEqual(control.frame.height, 36)
                XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
                XCTAssertLessThanOrEqual(control.frame.maxX, width)
                XCTAssertLessThanOrEqual(control.frame.maxY, bar.bounds.height)
            }
            for i in controls.indices {
                for j in controls.indices where i < j {
                    XCTAssertFalse(controls[i].frame.intersects(controls[j].frame))
                }
            }
            XCTAssertEqual(controls.last!.frame.maxX, width)
            if width == 340 { XCTAssertGreaterThan(bar.bounds.height, 36) }
        }
    }

    @MainActor func testUnavailablePickersLeaveOnlyTrailingAction() {
        let (bar, controls) = makeBar()
        for control in controls.dropLast() { control.isHidden = true }
        bar.refreshLayout()
        bar.setFrameSize(NSSize(width: 440, height: bar.intrinsicContentSize.height))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.intrinsicContentSize.height, 36)
        XCTAssertEqual(controls.last!.frame, NSRect(x: 404, y: 0, width: 36, height: 36))
    }

    @MainActor func testShortChoicesFitOneWideRowAndRetainNativeMenus() {
        let (bar, controls) = makeBar(longNames: false)
        bar.setFrameSize(NSSize(width: 748, height: 36))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.intrinsicContentSize.height, 36)
        for picker in controls.prefix(3).compactMap({ $0 as? NSPopUpButton }) {
            XCTAssertEqual(picker.numberOfItems, 2)
            XCTAssertEqual(picker.selectedItem?.title, "Default")
            XCTAssertGreaterThanOrEqual(picker.frame.width, 96)
        }
    }

    @MainActor private func makeBar(longNames: Bool = true) -> (ComposerControlsView, [NSView]) {
        let pickers = (0..<3).map { _ in
            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            picker.controlSize = .large
            picker.font = .systemFont(ofSize: 14)
            picker.addItems(withTitles: [longNames ? String(repeating: "Long agent-provided name ", count: 4) : "Default", "Other"])
            return picker
        }
        let actions = [NSButton(title: "Stop", target: nil, action: nil), NSButton(title: "Send", target: nil, action: nil)]
        return (ComposerControlsView(pickers: pickers, actions: actions), pickers + actions)
    }
}
