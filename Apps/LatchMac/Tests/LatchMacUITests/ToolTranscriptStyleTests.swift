import AppKit
import LatchACP
import XCTest
@testable import LatchMacUI

@MainActor
final class ToolTranscriptStyleTests: XCTestCase {
    private func event(_ fields: [String: ACPJSONValue]) -> ACPToolCallEvent {
        var update = fields
        update["sessionUpdate"] = .string("tool_call_update")
        update["toolCallId"] = .string("tool")
        let notification = ACPSessionNotification(sessionId: "session", update: .object(update))
        guard case let .toolCall(tool, _) = notification.event else { fatalError("Invalid test event") }
        return tool
    }

    private func text(_ value: String) -> ACPJSONValue {
        .object(["type": .string("content"), "content": .object([
            "type": .string("text"), "text": .string(value),
        ])])
    }

    private func weight(_ rendered: NSAttributedString, at location: Int) -> NSFont.Weight? {
        guard let font = rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont else { return nil }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { NSFont.Weight($0.doubleValue) }
    }

    /// Section headers are discovered from the rendered sections themselves rather than
    /// from literal label strings, so renaming a label in ToolCallDetails fails here
    /// instead of silently dropping the emphasis.
    func testEverySectionHeaderRendersSemibold() {
        var details = ToolCallDetails()
        details.apply(event([
            "content": .array([text("first line of content")]),
            "locations": .array([.object(["path": .string("/a"), "line": .integer(12)])]),
            "rawInput": .string("input one"), "rawOutput": .string("output two"),
        ]))
        let source = details.text
        let sections = source.components(separatedBy: "\n\n")
        XCTAssertEqual(sections.count, 4, "Expected content, locations, rawInput and rawOutput sections")
        let rendered = ToolTranscriptStyle.render(source)
        var offset = 0
        for section in sections {
            let header = section.components(separatedBy: "\n")[0]
            XCTAssertFalse(header.isEmpty)
            let location = (source as NSString).range(of: header, options: .literal,
                                                      range: NSRange(location: offset, length: (source as NSString).length - offset))
            XCTAssertNotEqual(location.location, NSNotFound)
            XCTAssertEqual(weight(rendered, at: location.location), .semibold,
                           "Section header '\(header)' lost its emphasis")
            // The line under the header stays regular weight.
            let body = section.components(separatedBy: "\n").dropFirst().first
            if let body, !body.isEmpty {
                let bodyRange = (source as NSString).range(of: body, options: .literal,
                                                           range: NSRange(location: location.location, length: (source as NSString).length - location.location))
                XCTAssertEqual(weight(rendered, at: bodyRange.location), .regular,
                               "Body of '\(header)' should not be emphasized")
            }
            offset = NSMaxRange(location)
        }
    }

    func testDiffHunkLinesAreColoredAndTintedPerSide() {
        var details = ToolCallDetails()
        details.apply(event(["content": .array([.object([
            "type": .string("diff"), "path": .string("/not/a/real/file"),
            "oldText": .string("keep\nremoved\n"), "newText": .string("keep\nadded\n"),
        ])])]))
        let source = details.text
        let rendered = ToolTranscriptStyle.render(source)
        let string = source as NSString
        for (prefix, expected) in [("-removed", NSColor.systemRed), ("+added", NSColor.systemGreen)] {
            let range = string.range(of: prefix, options: .literal)
            XCTAssertNotEqual(range.location, NSNotFound, "Missing \(prefix) line in:\n\(source)")
            XCTAssertEqual(rendered.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, expected)
            XCTAssertNotNil(rendered.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
        }
        let hunk = string.range(of: "@@ ", options: .literal)
        XCTAssertNotEqual(hunk.location, NSNotFound)
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: hunk.location, effectiveRange: nil) as? NSColor,
                       .secondaryLabelColor)
        // Unchanged context keeps the ordinary label color.
        let context = string.range(of: " keep", options: .literal)
        XCTAssertNotEqual(context.location, NSNotFound)
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: context.location, effectiveRange: nil) as? NSColor,
                       .labelColor)
    }
}

extension ToolTranscriptStyleTests {
    /// The row's header shows the title line, so the expanded body starts at the details and its
    /// first line is only emphasised when it is a section header.
    @MainActor func testUntitledBodyDoesNotEmphasiseItsFirstLine() {
        let plain = ToolTranscriptStyle.render("plain output\nsecond line", titled: false)
        let font = plain.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
        let section = ToolTranscriptStyle.render("Content:\nvalue", titled: false)
        let header = section.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(header?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }
}
