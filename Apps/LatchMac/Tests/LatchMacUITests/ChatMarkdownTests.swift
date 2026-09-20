import AppKit
import XCTest
@testable import LatchMacUI

final class ChatMarkdownTests: XCTestCase {
    @MainActor func testProseWhitespaceAndUnicode() async {
        let source = "  Hello 👩🏽‍💻 e\u{301} 世界  \r\nnext\n\nlast\n"
        let rendered = ChatMarkdown.render(source)
        XCTAssertEqual(rendered.string, source)
        XCTAssertEqual(ChatMarkdown.render("").length, 0)
        XCTAssertEqual(font(rendered, at: "世界").pointSize, ChatMarkdown.bodyFontSize)
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .labelColor)
    }

    @MainActor func testInlineStylesAndUTF16Ranges() async {
        let rendered = ChatMarkdown.render("👩🏽‍💻 **bold** *italic* ***both*** `let 🌍 = 1` plain")
        XCTAssertEqual(rendered.string, "👩🏽‍💻 bold italic both let 🌍 = 1 plain")
        XCTAssertTrue(font(rendered, at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font(rendered, at: "italic").fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(font(rendered, at: "both").fontDescriptor.symbolicTraits.contains([.bold, .italic]))
        XCTAssertEqual(font(rendered, at: "let"), .monospacedSystemFont(ofSize: ChatMarkdown.codeFontSize, weight: .regular))
        XCTAssertEqual(font(rendered, at: "plain"), .systemFont(ofSize: ChatMarkdown.bodyFontSize))
    }

    @MainActor func testFencedCodePreservesExactContent() async {
        let code = "    let 🌍 = \"**literal**\"  \r\n\t<raw> ![image](https://example.com/a)\r\n\r\n"
        let rendered = ChatMarkdown.render("Before\r\n```swift\r\n" + code + "```\r\nAfter")
        XCTAssertEqual(rendered.string, "Before\r\n" + code + "After")
        XCTAssertEqual(font(rendered, at: "let"), .monospacedSystemFont(ofSize: 12, weight: .regular))
        XCTAssertEqual(font(rendered, at: "After"), .systemFont(ofSize: 14))
        assertNoLinksOrAttachments(rendered)
    }

    @MainActor func testIncompleteFencesAndMismatchedClosers() async {
        let rendered = ChatMarkdown.render("  ````swift\n  first\n```\n~~~\n```` trailing\n\tlast  ")
        XCTAssertEqual(rendered.string, "  first\n```\n~~~\n```` trailing\n\tlast  ")
        XCTAssertEqual(font(rendered, at: "last").pointSize, ChatMarkdown.codeFontSize)
        XCTAssertEqual(ChatMarkdown.render("~~~\nx\n~~~~\n**end**").string, "x\nend")
        XCTAssertEqual(ChatMarkdown.render("```").string, "")
        XCTAssertEqual(ChatMarkdown.render("``\n**half").string, "``\n**half")
        XCTAssertEqual(ChatMarkdown.render("`unfinished").string, "`unfinished")
    }

    @MainActor func testIndentedCodeAndListIndentation() async {
        let rendered = ChatMarkdown.render("    **literal**  \n\tcode\n- first\n  + second\n12) third")
        XCTAssertEqual(rendered.string, "    **literal**  \n\tcode\n• first\n  • second\n12. third")
        XCTAssertEqual(font(rendered, at: "literal").pointSize, ChatMarkdown.codeFontSize)
        let range = (rendered.string as NSString).range(of: "second")
        let paragraph = rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(paragraph?.headIndent ?? 0, 0)
    }

    @MainActor func testHeadingsQuotesAndUnsupportedBlocks() async {
        let rendered = ChatMarkdown.render("# Title #\n###### Small\n> quoted **word**\n###nospace\n| a | b |\n---")
        XCTAssertEqual(rendered.string, "Title\nSmall\nquoted word\n###nospace\n| a | b |\n---")
        XCTAssertGreaterThan(font(rendered, at: "Title").pointSize, font(rendered, at: "Small").pointSize)
        XCTAssertTrue(font(rendered, at: "Small").fontDescriptor.symbolicTraits.contains(.bold))
        let range = (rendered.string as NSString).range(of: "quoted")
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        XCTAssertEqual((rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent, 12)
    }

    @MainActor func testLinkAllowlist() async {
        let rendered = ChatMarkdown.render("[web](https://example.com/path) [mail](mailto:hello@example.com) [http](http://example.com)")
        XCTAssertEqual(rendered.string, "web mail http")
        for word in ["web", "mail", "http"] {
            let range = (rendered.string as NSString).range(of: word)
            XCTAssertNotNil(rendered.attribute(.link, at: range.location, effectiveRange: nil), word)
        }
        for destination in ["javascript:alert", "data:text/html,test", "file:///tmp/a", "latch:run", "/relative", "//example.com", "https://user:password@example.com"] {
            let unsafe = ChatMarkdown.render("[label](\(destination))")
            XCTAssertEqual(unsafe.string, "label", destination)
            assertNoLinksOrAttachments(unsafe)
        }
    }

    @MainActor func testImagesHTMLAndCodeNeverProduceResources() async {
        let source = "![alt](https://example.com/image.png)\n<b>raw</b> <img src=\"https://example.com/a\">\n`[link](https://example.com) <b>`"
        let rendered = ChatMarkdown.render(source)
        XCTAssertEqual(rendered.string, "![alt](https://example.com/image.png)\n<b>raw</b> <img src=\"https://example.com/a\">\n[link](https://example.com) <b>")
        assertNoLinksOrAttachments(rendered)
        XCTAssertEqual(font(rendered, at: "[link]").pointSize, ChatMarkdown.codeFontSize)
    }

    @MainActor func testPipeTableCellsAlignmentAndHeader() async {
        let rendered = ChatMarkdown.render("| Left | Middle | Right |\n| :--- | :----: | ----: |\n| a | b | c |\nafter\n")
        XCTAssertEqual(rendered.string, "Left\nMiddle\nRight\na\nb\nc\nafter\n")
        XCTAssertTrue(font(rendered, at: "Left").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(font(rendered, at: "a").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertNil(block(rendered, at: "after"), "Prose after a table stayed inside it")
        for (cell, alignment) in [("Left", NSTextAlignment.left), ("Middle", .center), ("Right", .right),
                                  ("a", .left), ("b", .center), ("c", .right)] {
            XCTAssertEqual(paragraph(rendered, at: cell)?.alignment, alignment, cell)
        }
        let table = block(rendered, at: "Left")?.table
        XCTAssertEqual(table?.numberOfColumns, 3)
        for (cell, row, column) in [("Left", 0, 0), ("Middle", 0, 1), ("Right", 0, 2),
                                    ("a", 1, 0), ("b", 1, 1), ("c", 1, 2)] {
            XCTAssertEqual(block(rendered, at: cell)?.startingRow, row, cell)
            XCTAssertEqual(block(rendered, at: cell)?.startingColumn, column, cell)
            XCTAssertTrue(block(rendered, at: cell)?.table === table, cell)
        }
    }

    @MainActor func testPipeTableLaysOutAsAGrid() async {
        let note = "a sentence that has to wrap inside its own cell"
        let rendered = ChatMarkdown.render("| Command | Note | Count |\n| --- | --- | ---: |\n| run | \(note) | 12 |\n")
        let frames = layout(rendered, width: 320)
        XCTAssertLessThanOrEqual(frames.used.maxX, 321, "Table overflowed its container")
        XCTAssertEqual(frames["Command"].minX, frames["run"].minX, accuracy: 0.5, "Left column is ragged")
        XCTAssertEqual(frames["Note"].minX, frames[note].minX, accuracy: 0.5, "Middle column is ragged")
        XCTAssertEqual(frames["Count"].maxX, frames["12"].maxX, accuracy: 0.5, "Right-aligned column is ragged")
        XCTAssertLessThan(frames["Command"].maxY, frames["run"].minY, "Rows did not stack")
        XCTAssertEqual(frames["run"].minY, frames[note].minY, accuracy: 0.5, "Row cells do not share a top")
        XCTAssertEqual(frames["12"].minY, frames[note].minY, accuracy: 0.5, "Row cells do not share a top")
        XCTAssertGreaterThan(frames[note].height, frames["run"].height * 1.5, "Long cell did not wrap in place")
        XCTAssertGreaterThanOrEqual(frames.used.maxY, frames[note].maxY, "Measured height excludes the last row")
    }

    @MainActor func testPipeTableColumnsAreSizedToTheirContent() async {
        let note = "a sentence long enough that its column has to earn more room than a one word column"
        let rendered = ChatMarkdown.render("| Note | Ok | Count |\n| - | - | - |\n| \(note) | yes | 12 |\n")
        let shares = ["Note", "Ok", "Count"].map { block(rendered, at: $0)?.value(for: .width) ?? 0 }
        XCTAssertEqual(block(rendered, at: "Note")?.valueType(for: .width), .percentageValueType)
        XCTAssertEqual(shares.reduce(0, +), 100, accuracy: 0.01, "Columns do not fill the container")
        XCTAssertGreaterThan(shares[0], shares[1] * 3, "Prose shares the width evenly with a one-word column")
        // However little a column holds, it keeps enough width to read as a column.
        for (cell, share) in zip(["Ok", "Count"], shares.dropFirst()) {
            XCTAssertGreaterThan(share, 5, cell)
        }
    }

    @MainActor func testPipeTableNeedsAMatchingDelimiterRow() async {
        // While streaming, a header arrives before its delimiter; it stays prose until then.
        for source in ["| a | b |", "| a | b |\n| --- |", "| a | b |\n| --- | :: |", "| a | b |\n| --- | -x- |",
                       "| a | b |\nplain", "a\n| --- | --- |", "    | a | b |\n    | - | - |"] {
            XCTAssertEqual(ChatMarkdown.render(source).string, source, source)
        }
        XCTAssertEqual(ChatMarkdown.render("```\n| a |\n| - |\n```").string, "| a |\n| - |\n")
        XCTAssertEqual(ChatMarkdown.render("> | a | b |\n> | - | - |").string, "| a | b |\n| - | - |")
        XCTAssertEqual(ChatMarkdown.render("# a | b\n| - | - |").string, "a | b\n| - | - |")
        // A header and its delimiter alone already make a table, just one without body rows.
        let bodyless = ChatMarkdown.render("| a | b |\n| - | - |")
        XCTAssertEqual(bodyless.string, "a\nb\n")
        XCTAssertEqual(block(bodyless, at: "a")?.table.numberOfColumns, 2)
    }

    @MainActor func testPipeTableCellContent() async {
        let rendered = ChatMarkdown.render("| Escaped | Styled |\n| - | - |\n| a \\| b | **bold** `code` [web](https://example.com) |\n| only |\n| one | two | three |\n")
        XCTAssertEqual(rendered.string, "Escaped\nStyled\na | b\nbold code web\nonly\n\none\ntwo\n")
        XCTAssertTrue(font(rendered, at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(font(rendered, at: "code"), .monospacedSystemFont(ofSize: ChatMarkdown.codeFontSize, weight: .regular))
        let link = (rendered.string as NSString).range(of: "web")
        XCTAssertNotNil(rendered.attribute(.link, at: link.location, effectiveRange: nil))
        // The short row is padded and the long one truncated, so every row fills the same grid.
        XCTAssertEqual(block(rendered, at: "only")?.startingRow, 2)
        XCTAssertEqual(block(rendered, at: "one")?.startingRow, 3)
        XCTAssertEqual(block(rendered, at: "two")?.startingColumn, 1)
        XCTAssertEqual((rendered.string as NSString).range(of: "three").location, NSNotFound)
        let image = ChatMarkdown.render("| a | b |\n| - | - |\n| ![alt](https://example.com/i.png) | x |\n")
        XCTAssertEqual(image.string, "a\nb\n![alt](https://example.com/i.png)\nx\n")
        assertNoLinksOrAttachments(image)
    }

    @MainActor private func font(_ rendered: NSAttributedString, at text: String) -> NSFont {
        let range = (rendered.string as NSString).range(of: text)
        guard range.location != NSNotFound,
              let font = rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else {
            XCTFail("Missing font for \(text)")
            return .systemFont(ofSize: 0)
        }
        return font
    }

    @MainActor private func paragraph(_ rendered: NSAttributedString, at text: String) -> NSParagraphStyle? {
        let range = (rendered.string as NSString).range(of: text)
        guard range.location != NSNotFound else {
            XCTFail("Missing \(text)")
            return nil
        }
        return rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    }

    @MainActor private func block(_ rendered: NSAttributedString, at text: String) -> NSTextTableBlock? {
        paragraph(rendered, at: text)?.textBlocks.first as? NSTextTableBlock
    }

    /// Lays the rendered text out the way a transcript row does, so the assertions read
    /// real TextKit geometry rather than the attributes that were asked for.
    @MainActor private func layout(_ rendered: NSAttributedString, width: CGFloat) -> TableLayout {
        let storage = NSTextStorage(attributedString: rendered)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return TableLayout(storage: storage, manager: manager, container: container)
    }

    @MainActor private struct TableLayout {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer

        var used: NSRect { manager.usedRect(for: container) }

        subscript(cell: String) -> NSRect {
            let range = (storage.string as NSString).range(of: cell)
            guard range.location != NSNotFound else { return .zero }
            return manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                        in: container)
        }
    }

    // MARK: Resumable rendering

    /// Text, runs, and every attribute that decides how a run looks — but text blocks by
    /// their position in the grid rather than by object identity. Two renders of the same
    /// table build two `NSTextTable` objects, so even a full render never equals itself.
    @MainActor private static func signature(_ rendered: NSAttributedString) -> String {
        var lines = [rendered.string.debugDescription]
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, range, _ in
            var parts = ["\(range.location)+\(range.length)"]
            for key in attributes.keys.map(\.rawValue).sorted() {
                let value = attributes[NSAttributedString.Key(key)]
                switch value {
                case let style as NSParagraphStyle:
                    let blocks = style.textBlocks.map { block in
                        guard let cell = block as? NSTextTableBlock else { return "block" }
                        return "cell(\(cell.startingRow)+\(cell.rowSpan),\(cell.startingColumn)+\(cell.columnSpan))"
                    }
                    parts.append("\(key)=[align \(style.alignment.rawValue), spacing \(style.lineSpacing), "
                                 + "head \(style.headIndent), first \(style.firstLineHeadIndent), "
                                 + "break \(style.lineBreakMode.rawValue), blocks \(blocks)]")
                case let font as NSFont:
                    parts.append("\(key)=\(font.fontName)@\(font.pointSize)")
                default:
                    parts.append("\(key)=\(String(describing: value))")
                }
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// Guards the guard: the comparison above has to be blind to table identity but still
    /// see a genuine difference.
    @MainActor func testTheRenderSignatureIgnoresTableIdentityButNotContent() {
        let table = "| Step | Result |\n| --- | ---: |\n| build | ok |\n"
        XCTAssertEqual(Self.signature(ChatMarkdown.render(table)), Self.signature(ChatMarkdown.render(table)))
        XCTAssertNotEqual(Self.signature(ChatMarkdown.render(table)),
                          Self.signature(ChatMarkdown.render("| Step | Result |\n| ---: | --- |\n| build | ok |\n")),
                          "Column alignment is part of the rendering and must be compared")
        XCTAssertNotEqual(Self.signature(ChatMarkdown.render("plain")), Self.signature(ChatMarkdown.render("**plain**")))
    }


    /// Every construct the renderer carries state across: a table that keeps gaining rows,
    /// a fence that opens and later closes, emphasis that completes, and a heading.
    private static let streamingCorpus = """
    Intro prose before anything structural.
    # A heading
    Some **bold** and `code` here.

    | Step | Result |
    | --- | ---: |
    | build | ok |
    | test | ok |

    ```swift
    let value = 42
    ```

    - item one
    - item two

    > quoted line

        indented code
    Closing prose with an unclosed **bold
    """

    /// The cache must be indistinguishable from re-rendering the whole answer, at every
    /// single character of the stream — that is the only property that makes it safe.
    @MainActor func testResumedRenderMatchesAFullRenderAtEveryPrefix() {
        let cache = ChatMarkdown.Cache()
        var streamed = ""
        for character in Self.streamingCorpus {
            streamed.append(character)
            XCTAssertEqual(Self.signature(ChatMarkdown.render(streamed, into: cache)),
                           Self.signature(ChatMarkdown.render(streamed)),
                           "Resumed render diverged after \(streamed.count) characters")
        }
    }

    /// Chunks arrive as whole runs of text, not one character at a time.
    @MainActor func testResumedRenderMatchesForRaggedChunks() {
        let cache = ChatMarkdown.Cache()
        var streamed = ""
        var remaining = Substring(Self.streamingCorpus)
        var size = 1
        while !remaining.isEmpty {
            let chunk = remaining.prefix(size)
            remaining = remaining.dropFirst(size)
            streamed += chunk
            size = size % 17 + 1
            XCTAssertEqual(Self.signature(ChatMarkdown.render(streamed, into: cache)),
                           Self.signature(ChatMarkdown.render(streamed)))
        }
    }

    /// The history bound trims a message from the front, and a reused row can be handed an
    /// unrelated answer. Neither may reuse anything the previous render left behind.
    @MainActor func testResumedRenderSurvivesRewritesAndTrimming() {
        let cache = ChatMarkdown.Cache()
        let full = Self.streamingCorpus
        XCTAssertEqual(Self.signature(ChatMarkdown.render(full, into: cache)), Self.signature(ChatMarkdown.render(full)))
        for rewritten in [String(full.dropFirst(120)),
                          String(full.dropLast(200)),
                          "An entirely different answer.\n\n| a | b |\n| - | - |\n| 1 | 2 |",
                          "",
                          full] {
            XCTAssertEqual(Self.signature(ChatMarkdown.render(rewritten, into: cache)),
                           Self.signature(ChatMarkdown.render(rewritten)),
                           "Resumed render diverged after a rewrite")
        }
    }

    /// A table only becomes a table when its delimiter row lands, and it keeps growing
    /// afterwards. Both retroactively change lines the previous frame already rendered.
    @MainActor func testResumedRenderRebuildsATableThatKeepsGrowing() {
        let cache = ChatMarkdown.Cache()
        var source = "before\n| Step | Result |"
        for addition in ["\n| --- | ---: |", "\n| build | ok |", "\n| test | ok |", "\n| ship | ok |", "\nafter"] {
            source += addition
            XCTAssertEqual(Self.signature(ChatMarkdown.render(source, into: cache)),
                           Self.signature(ChatMarkdown.render(source)),
                           "Resumed render diverged while the table grew")
        }
    }

    @MainActor private func assertNoLinksOrAttachments(_ rendered: NSAttributedString) {
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.attachment])
            XCTAssertNil(attributes[NSAttributedString.Key("NSImageURL")])
        }
    }
}
