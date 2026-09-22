import AppKit
import XCTest
@testable import LatchMacUI

@MainActor
final class ChatInputPasteTests: XCTestCase {
    private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("latch-paste-\(UUID().uuidString)"))
        board.clearContents()
        fill(board)
        return board
    }

    private func screenshot() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private var pasteItem: NSMenuItem { NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v") }

    /// A plain-text field enables Paste only for text, so an image on the clipboard left the
    /// menu item, and with it ⌘V, disabled before the paste ever reached the attachment path.
    func testPasteIsEnabledForAnImageWithNoText() throws {
        let field = ChatInputView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        field.isRichText = false
        let image = try screenshot()
        field.pasteSource = board { $0.setData(image, forType: .png) }
        var taken: NSPasteboard?
        field.onAttach = { taken = $0; return true }

        XCTAssertTrue(field.validateMenuItem(pasteItem))
        field.paste(nil)
        XCTAssertTrue(taken === field.pasteSource)
        XCTAssertTrue(field.string.isEmpty)
    }

    // When attachments decline, Paste falls back to the text system, which reads the real
    // clipboard; so these check the decision itself rather than the menu item.
    func testOnlyAnEditableFieldWithSomewhereToPutThemPastesAttachments() throws {
        let field = ChatInputView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let image = try screenshot()
        field.pasteSource = board { $0.setData(image, forType: .png) }
        XCTAssertFalse(field.canPasteAttachments, "Nothing takes attachments yet")
        field.onAttach = { _ in true }
        XCTAssertTrue(field.canPasteAttachments)
        field.isEditable = false
        XCTAssertFalse(field.canPasteAttachments, "A read-only composer takes nothing")
        field.isEditable = true
        field.pasteSource = board { $0.setString("words", forType: .string) }
        XCTAssertFalse(field.canPasteAttachments, "Text pastes as text")
    }
}
