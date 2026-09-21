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
                XCTAssertGreaterThanOrEqual(control.frame.height, ComposerControlsView.controlHeight)
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
            if width == 340 { XCTAssertGreaterThan(bar.bounds.height, ComposerControlsView.controlHeight) }
        }
    }

    @MainActor func testUnavailablePickersLeaveOnlyTrailingAction() {
        let (bar, controls) = makeBar()
        for control in controls.dropLast() { control.isHidden = true }
        bar.refreshLayout()
        bar.setFrameSize(NSSize(width: 440, height: bar.intrinsicContentSize.height))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.intrinsicContentSize.height, ComposerControlsView.controlHeight)
        XCTAssertEqual(controls.last!.frame, NSRect(x: 440 - ComposerControlsView.controlHeight, y: 0, width: ComposerControlsView.controlHeight, height: ComposerControlsView.controlHeight))
    }

    @MainActor func testShortChoicesFitOneWideRowAndRetainNativeMenus() {
        let (bar, controls) = makeBar(longNames: false)
        bar.setFrameSize(NSSize(width: 748, height: ComposerControlsView.controlHeight))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.intrinsicContentSize.height, ComposerControlsView.controlHeight)
        for picker in controls.prefix(3).compactMap({ $0 as? NSPopUpButton }) {
            XCTAssertEqual(picker.numberOfItems, 2)
            XCTAssertEqual(picker.selectedItem?.title, "Default")
            // As wide as the title it shows, not as wide as a form field.
            XCTAssertGreaterThan(picker.frame.width, 50)
            XCTAssertLessThan(picker.frame.width, 110)
        }
    }

    /// The harness picker joined the row, so four pickers plus Send have to share it. Long
    /// agent-supplied menu titles must not push a picker onto a second row at the width a
    /// default window actually gives the composer.
    @MainActor func testFourPickersShareOneRowAtTheDefaultComposerWidth() {
        let pickers = [
            ComposerControlsView.Slot(picker(["Claude Code", "Custom ACP Agent"]), minimumWidth: 110, maximumWidth: 150),
            ComposerControlsView.Slot(picker(["claude-opus-4-5-20260315-with-a-long-identifier"]), maximumWidth: 230),
            ComposerControlsView.Slot(picker(["Medium"]), minimumWidth: 96, maximumWidth: 130),
            ComposerControlsView.Slot(picker(["Accept edits automatically"]), minimumWidth: 130, maximumWidth: 180),
        ]
        let send = NSButton(title: "Send", target: nil, action: nil)
        let bar = ComposerControlsView(pickers: pickers, actions: [send])
        bar.setFrameSize(NSSize(width: 880, height: ComposerControlsView.controlHeight))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.intrinsicContentSize.height, ComposerControlsView.controlHeight)
        XCTAssertEqual(send.frame.maxX, 880)
        for slot in pickers {
            XCTAssertEqual(slot.button.frame.minY, 0, "A picker wrapped onto a second row")
        }
    }

    @MainActor private func picker(_ titles: [String]) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.controlSize = .large
        picker.font = .systemFont(ofSize: 14)
        picker.addItems(withTitles: titles)
        return picker
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
        return (ComposerControlsView(pickers: pickers.map { ComposerControlsView.Slot($0) }, actions: actions),
                pickers + actions)
    }
}
