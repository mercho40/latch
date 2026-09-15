import AppKit
import XCTest
@testable import LatchMacUI

final class ChatComposerTests: XCTestCase {
    @MainActor func testEmptyAndShortDraftsStayCompact() {
        let (scroll, text) = makeComposer()
        for draft in ["", "A short message", "你好 👩🏽‍💻"] {
            text.string = draft
            scroll.refreshHeight()
            XCTAssertEqual(height(of: scroll), ChatComposerScrollView.minimumHeight)
        }
    }

    @MainActor func testMultilineDraftGrowsAndLongDraftIsBounded() {
        let (scroll, text) = makeComposer()
        text.string = Array(repeating: "A line", count: 5).joined(separator: "\n")
        scroll.refreshHeight()
        XCTAssertGreaterThan(height(of: scroll), ChatComposerScrollView.minimumHeight)
        XCTAssertLessThan(height(of: scroll), ChatComposerScrollView.maximumHeight)
        text.string = String(repeating: "A long draft\n", count: 100)
        scroll.refreshHeight()
        XCTAssertEqual(height(of: scroll), ChatComposerScrollView.maximumHeight)
        XCTAssertTrue(scroll.hasVerticalScroller)
    }

    @MainActor func testClearingOrRestoringDraftRemeasuresWithoutAnEditingNotification() {
        let (scroll, text) = makeComposer()
        text.string = String(repeating: "Restored draft\n", count: 30)
        scroll.refreshHeight()
        XCTAssertEqual(height(of: scroll), ChatComposerScrollView.maximumHeight)
        text.string = ""
        scroll.refreshHeight()
        XCTAssertEqual(height(of: scroll), ChatComposerScrollView.minimumHeight)
    }

    @MainActor func testWidthChangesRemeasureWrappingWithoutChangingDraftOrSelection() {
        let (scroll, text) = makeComposer()
        let draft = String(repeating: "word ", count: 35)
        text.string = draft
        text.setSelectedRange(NSRange(location: 5, length: 9))
        scroll.refreshHeight()
        let wide = height(of: scroll)
        scroll.setFrameSize(NSSize(width: 240, height: 184))
        scroll.tile()
        XCTAssertGreaterThan(height(of: scroll), wide)
        XCTAssertEqual(text.string, draft)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 5, length: 9))
        scroll.setFrameSize(NSSize(width: 640, height: 184))
        scroll.tile()
        XCTAssertEqual(height(of: scroll), wide)
    }

    @MainActor func testTrailingNewlineReservesTheInsertionLine() {
        let (scroll, text) = makeComposer()
        text.string = "one\ntwo\nthree"
        scroll.refreshHeight()
        let before = height(of: scroll)
        text.string += "\n"
        scroll.refreshHeight()
        XCTAssertGreaterThan(height(of: scroll), before)
    }

    @MainActor private func height(of scroll: ChatComposerScrollView) -> CGFloat {
        scroll.constraints.first { $0.firstAttribute == .height && $0.secondItem == nil }!.constant
    }

    @MainActor private func makeComposer() -> (ChatComposerScrollView, ChatInputView) {
        let scroll = ChatComposerScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 184))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = ChatInputView(frame: NSRect(x: 0, y: 0, width: 640, height: 184))
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isRichText = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.tile()
        return (scroll, text)
    }
}
