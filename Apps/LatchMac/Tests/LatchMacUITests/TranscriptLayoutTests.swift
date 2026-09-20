import AppKit
import XCTest
@testable import LatchMacUI

/// Dragging the window edge re-wraps every message in the transcript. That work is limited
/// to the rows the reader can see, so the rows that were skipped have to settle exactly
/// once the drag ends — an approximation that survived the drag would be a layout bug.
@MainActor
final class TranscriptLayoutTests: XCTestCase {
    private func conversation(_ count: Int) -> [ChatMessage] {
        (0..<count).map {
            ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
                        text: "Message \($0). " + String(repeating: "Wrapping prose whose height depends on the width. ", count: 4))
        }
    }

    private func transcript(_ messages: [ChatMessage]) -> ChatTranscriptView {
        let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        view.update(messages: messages, isWorking: false)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func resize(_ view: ChatTranscriptView, to width: CGFloat) {
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
    }

    func testLiveResizeDefersOffscreenRowsAndSettlesThemWhenTheDragEnds() throws {
        let messages = conversation(60)
        let reference = transcript(messages)
        let dragged = transcript(messages)
        XCTAssertEqual(reference.rowFrames, dragged.rowFrames, "The two transcripts start identical")

        dragged.limitsMeasurementToViewport = true
        for width in stride(from: CGFloat(680), through: 380, by: -60) {
            resize(dragged, to: width)
        }
        resize(reference, to: 380)

        let midDrag = dragged.rowFrames
        let settled = reference.rowFrames
        XCTAssertEqual(midDrag.count, settled.count)
        XCTAssertTrue(zip(midDrag, settled).contains { $0.height != $1.height },
                      "Nothing was deferred, so the resize measured every row after all")
        // The transcript follows the bottom, so the last message is what the reader is
        // looking at while the edge moves. It must never be an estimate.
        XCTAssertEqual(try XCTUnwrap(midDrag.last).height, try XCTUnwrap(settled.last).height,
                       "The row the reader can see was measured approximately")

        dragged.viewDidEndLiveResize()
        XCTAssertFalse(dragged.limitsMeasurementToViewport)
        XCTAssertEqual(dragged.rowFrames, settled, "Deferred rows did not settle when the drag ended")
    }

    /// An ordinary layout pass — a window restored at a new size, a sidebar toggled — is
    /// not a drag, and must measure everything straight away.
    func testAnOrdinaryResizeMeasuresEveryRow() {
        let messages = conversation(40)
        let reference = transcript(messages)
        let resized = transcript(messages)
        resize(reference, to: 420)
        resize(resized, to: 420)
        XCTAssertEqual(resized.rowFrames, reference.rowFrames)
        XCTAssertFalse(resized.limitsMeasurementToViewport)
    }
}
