import AppKit
import XCTest
@testable import LatchMacUI

final class ComposerControlsViewTests: XCTestCase {
    @MainActor func testPickersThatDoNotFitFoldIntoOneRow() {
        let (bar, controls) = makeBar()
        for width: CGFloat in [340, 440, 748] {
            bar.setFrameSize(NSSize(width: width, height: ComposerControlsView.controlHeight))
            bar.layoutSubtreeIfNeeded()
            XCTAssertEqual(bar.intrinsicContentSize.height, ComposerControlsView.controlHeight)
            let shown = controls.filter { !(($0 as? NSPopUpButton).map(bar.isFolded) ?? false) }
            for control in shown {
                XCTAssertEqual(control.frame.minY, 0, "A control wrapped onto a second row at \(width)")
                XCTAssertGreaterThanOrEqual(control.frame.height, ComposerControlsView.controlHeight)
                XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
                XCTAssertLessThanOrEqual(control.frame.maxX, width)
            }
            for i in shown.indices {
                for j in shown.indices where i < j {
                    XCTAssertFalse(shown[i].frame.intersects(shown[j].frame))
                }
            }
            XCTAssertEqual(controls.last!.frame.maxX, width)
        }
        bar.setFrameSize(NSSize(width: 340, height: ComposerControlsView.controlHeight))
        bar.layoutSubtreeIfNeeded()
        let pickers = controls.compactMap { $0 as? NSPopUpButton }
        // The last pickers fold first, and the first keeps its place.
        XCTAssertFalse(bar.isFolded(pickers[0]))
        XCTAssertTrue(bar.isFolded(pickers[2]))
    }

    @MainActor func testTheMoreMenuChoosesForAFoldedPicker() throws {
        let (bar, controls) = makeBar()
        let pickers = controls.compactMap { $0 as? NSPopUpButton }
        let target = ActionRecorder()
        for (index, picker) in pickers.enumerated() {
            picker.setAccessibilityLabel("Picker \(index)")
            picker.target = target
            picker.action = #selector(ActionRecorder.record(_:))
            for item in picker.itemArray { item.representedObject = item.title }
        }
        bar.setFrameSize(NSSize(width: 340, height: ComposerControlsView.controlHeight))
        bar.layoutSubtreeIfNeeded()
        let more = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSPopUpButton }.first { $0.pullsDown })
        XCTAssertFalse(more.isHidden)
        let menu = try XCTUnwrap(more.menu)
        bar.menuNeedsUpdate(menu)
        let headers = menu.items.filter(\.isSectionHeader).map(\.title)
        XCTAssertEqual(headers, pickers.filter(bar.isFolded).compactMap { $0.accessibilityLabel() })
        XCTAssertTrue(headers.contains("Picker 2"))
        // The section's current choice is checked, and choosing another sends the picker's action.
        let section = try XCTUnwrap(menu.items.firstIndex { $0.title == "Picker 2" })
        XCTAssertEqual(menu.items[section + 1].state, .on)
        let other = menu.items[section + 2]
        XCTAssertEqual(other.title, "Other")
        menu.performActionForItem(at: section + 2)
        XCTAssertTrue(target.senders.last === pickers[2])
        XCTAssertEqual(pickers[2].titleOfSelectedItem, "Other")
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

    @MainActor private final class ActionRecorder: NSObject {
        var senders: [AnyObject] = []
        @objc func record(_ sender: AnyObject) { senders.append(sender) }
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
        // As in the composer: the first picker shortens rather than folding.
        return (ComposerControlsView(pickers: pickers.enumerated().map { ComposerControlsView.Slot($1, folds: $0 > 0) },
                                     actions: actions),
                pickers + actions)
    }
}
