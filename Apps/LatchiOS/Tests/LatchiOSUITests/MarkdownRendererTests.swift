import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class MarkdownRendererTests: XCTestCase {
    private let traits = UITraitCollection(preferredContentSizeCategory: .large)
    private var renderer: MarkdownRenderer { MarkdownRenderer(traits: traits) }

    private func render(_ source: String) -> [MarkdownBlock] { renderer.render(source) }

    private func text(_ blocks: [MarkdownBlock], _ index: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> NSAttributedString {
        guard blocks.indices.contains(index) else {
            XCTFail("No block \(index) in \(blocks)", file: file, line: line)
            return NSAttributedString()
        }
        switch blocks[index] {
        case let .text(text), let .quote(text): return text
        default:
            XCTFail("Block \(index) is not text: \(blocks[index])", file: file, line: line)
            return NSAttributedString()
        }
    }

    private func attribute<T>(_ key: NSAttributedString.Key, of word: String, in text: NSAttributedString,
                              as type: T.Type = T.self) -> T? {
        let range = (text.string as NSString).range(of: word)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(key, at: range.location, effectiveRange: nil) as? T
    }

    private func font(_ word: String, in text: NSAttributedString) -> UIFont? {
        attribute(.font, of: word, in: text)
    }

    func testProseKeepsItsTextAndUsesTheBodyFont() {
        let blocks = render("Hello 👩🏽‍💻 e\u{301} 世界\nnext line\n\nSecond paragraph")
        XCTAssertEqual(blocks.count, 1)
        let rendered = text(blocks)
        XCTAssertEqual(rendered.string, "Hello 👩🏽‍💻 e\u{301} 世界\u{2028}next line\nSecond paragraph")
        XCTAssertEqual(font("世界", in: rendered), UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits))
        XCTAssertEqual(attribute(.foregroundColor, of: "Second", in: rendered, as: UIColor.self), .label)
        XCTAssertEqual(render(""), [])
    }

    func testHeadingsScaleDownByLevelAndAreBold() {
        let rendered = text(render("# Title\n## Section\n### Part\n#### Small\n\nBody"))
        XCTAssertEqual(rendered.string, "Title\nSection\nPart\nSmall\nBody")
        let sizes = ["Title", "Section", "Part", "Small", "Body"].compactMap { font($0, in: rendered)?.pointSize }
        XCTAssertEqual(sizes.count, 5)
        XCTAssertGreaterThan(sizes[0], sizes[1])
        XCTAssertGreaterThan(sizes[1], sizes[2])
        XCTAssertGreaterThan(sizes[2], sizes[3])
        XCTAssertGreaterThan(sizes[2], sizes[4] - 0.5, "A third-level heading is at least body size")
        for word in ["Title", "Section", "Part", "Small"] {
            XCTAssertTrue(font(word, in: rendered)?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false, word)
        }
        XCTAssertFalse(font("Body", in: rendered)?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? true)
    }

    func testHeadingsFollowDynamicType() {
        let large = MarkdownRenderer(traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge))
        let body = { (renderer: MarkdownRenderer) in renderer.font(for: .body).pointSize }
        XCTAssertGreaterThan(body(large), body(renderer) * 1.5)
        XCTAssertGreaterThan(large.font(for: .heading(1)).pointSize, renderer.font(for: .heading(1)).pointSize)
        XCTAssertGreaterThan(large.codeBlockFont.pointSize, renderer.codeBlockFont.pointSize)
    }

    func testEmphasisStrongStrikethroughAndInlineCode() {
        let rendered = text(render("**bold** *italic* ***both*** ~~gone~~ `let x = 1` plain"))
        XCTAssertEqual(rendered.string, "bold italic both gone let x = 1 plain")
        XCTAssertTrue(font("bold", in: rendered)!.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(font("italic", in: rendered)!.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(font("both", in: rendered)!.fontDescriptor.symbolicTraits.contains([.traitBold, .traitItalic]))
        XCTAssertEqual(attribute(.strikethroughStyle, of: "gone", in: rendered, as: Int.self), NSUnderlineStyle.single.rawValue)
        XCTAssertTrue(font("let", in: rendered)!.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertNotNil(attribute(.inlineCodeBackground, of: "let", in: rendered, as: UIColor.self))
        XCTAssertNil(attribute(.inlineCodeBackground, of: "plain", in: rendered, as: UIColor.self))
        XCTAssertFalse(font("plain", in: rendered)!.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    func testNestedListsHaveMarkersAndHangingIndents() {
        let rendered = text(render("- first\n- second\n  1. one\n  2. two\n     - deep\n- third"))
        XCTAssertEqual(rendered.string, "\t•\tfirst\n\t•\tsecond\n\t1.\tone\n\t2.\ttwo\n\t▪︎\tdeep\n\t•\tthird")
        let outer = attribute(.paragraphStyle, of: "first", in: rendered, as: NSParagraphStyle.self)
        let nested = attribute(.paragraphStyle, of: "one", in: rendered, as: NSParagraphStyle.self)
        let deep = attribute(.paragraphStyle, of: "deep", in: rendered, as: NSParagraphStyle.self)
        XCTAssertGreaterThan(outer?.headIndent ?? 0, 0, "Wrapped lines hang under the text, not the marker")
        XCTAssertGreaterThan(nested?.headIndent ?? 0, outer?.headIndent ?? 0)
        XCTAssertGreaterThan(deep?.headIndent ?? 0, nested?.headIndent ?? 0)
        XCTAssertEqual(outer?.firstLineHeadIndent, 0)
        XCTAssertEqual(nested?.firstLineHeadIndent, outer?.headIndent)
        XCTAssertEqual(outer?.tabStops.last?.location, outer?.headIndent, "The text starts at the hanging indent")
        XCTAssertEqual(attribute(.foregroundColor, of: "•", in: rendered, as: UIColor.self), .secondaryLabel)
    }

    func testAnOrderedListKeepsItsStartAndASecondParagraphHasNoMarker() {
        let rendered = text(render("3. three\n4. four\n\n   more about four"))
        XCTAssertEqual(rendered.string, "\t3.\tthree\n\t4.\tfour\nmore about four")
        let continuation = attribute(.paragraphStyle, of: "more", in: rendered, as: NSParagraphStyle.self)
        XCTAssertEqual(continuation?.firstLineHeadIndent, continuation?.headIndent)
        XCTAssertGreaterThan(continuation?.headIndent ?? 0, 0)
    }

    func testCodeFencesWithAndWithoutALanguage() {
        let blocks = render("Before\n\n```swift\nlet 🌍 = \"**literal**\"\n\n  indented\n```\n\n```\nplain <b>html</b>\n```\nAfter")
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[1], .code(language: "swift", code: "let 🌍 = \"**literal**\"\n\n  indented"))
        XCTAssertEqual(blocks[2], .code(language: nil, code: "plain <b>html</b>"))
        XCTAssertEqual(text(blocks, 3).string, "After")
    }

    func testAnUnclosedFenceStreamsAsCode() {
        XCTAssertEqual(render("```python\ndef f():\n    return"), [.code(language: "python", code: "def f():\n    return")])
        XCTAssertEqual(render("```"), [], "A fence with nothing in it yet shows nothing")
    }

    func testTablesAreGridsWithAlignedColumns() {
        let blocks = render("| Left | Middle | Right |\n| :--- | :----: | ----: |\n| a | **b** | `c` |\n| d | e | f |\n\nafter")
        XCTAssertEqual(blocks.count, 2)
        guard case let .table(table) = blocks[0] else { return XCTFail("Not a table: \(blocks[0])") }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.header.map(\.string), ["Left", "Middle", "Right"])
        XCTAssertEqual(table.rows.map { $0.map(\.string) }, [["a", "b", "c"], ["d", "e", "f"]])
        XCTAssertTrue((table.header[0].attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?
            .fontDescriptor.symbolicTraits.contains(.traitBold) ?? false, "The header is emphasised")
        XCTAssertTrue((table.rows[0][1].attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?
            .fontDescriptor.symbolicTraits.contains(.traitBold) ?? false, "Cells keep inline styles")
        XCTAssertEqual(text(blocks, 1).string, "after")
    }

    func testARaggedTableIsPaddedAndCut() {
        guard case let .table(table) = render("| a | b |\n| - | - |\n| only |\n| one | two | three |")[0] else {
            return XCTFail("Not a table")
        }
        XCTAssertEqual(table.rows.map { $0.map(\.string) }, [["only", ""], ["one", "two"]])
    }

    func testAWideTableScrollsSideways() {
        let header = (1...8).map { "Column \($0)" }.joined(separator: " | ")
        let row = (1...8).map { "value number \($0)" }.joined(separator: " | ")
        let blocks = render("| \(header) |\n|\(String(repeating: " --- |", count: 8))\n| \(row) |")
        let view = TableBlockView()
        view.show(blocks[0], renderer: renderer)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        view.layoutIfNeeded()
        XCTAssertTrue(view.scrolls, "Eight columns do not fit 360 points")
        let narrow = TableBlockView()
        narrow.show(render("| a | b |\n| - | - |\n| 1 | 2 |")[0], renderer: renderer)
        narrow.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        narrow.layoutIfNeeded()
        XCTAssertFalse(narrow.scrolls)
    }

    func testAPartiallyStreamedTableIsProseUntilItsDelimiterArrives() {
        XCTAssertEqual(text(render("| a | b |")).string, "| a | b |")
        guard case .table = render("| a | b |\n| - | - |")[0] else { return XCTFail("The delimiter row makes it a table") }
    }

    func testBlockQuotesAreSetApart() {
        let blocks = render("Before\n\n> quoted **word**\n> more\n>\n> > nested\n\nAfter")
        XCTAssertEqual(blocks.count, 3)
        guard case let .quote(quote) = blocks[1] else { return XCTFail("Not a quote: \(blocks[1])") }
        XCTAssertEqual(quote.string, "quoted word\u{2028}more\nnested")
        XCTAssertEqual(attribute(.foregroundColor, of: "quoted", in: quote, as: UIColor.self), .secondaryLabel)
        let nested = attribute(.paragraphStyle, of: "nested", in: quote, as: NSParagraphStyle.self)
        XCTAssertGreaterThan(nested?.headIndent ?? 0, 0, "A nested quote steps in")
    }

    func testThematicBreaksAreRules() {
        XCTAssertEqual(render("one\n\n---\n\ntwo").count, 3)
        XCTAssertEqual(render("one\n\n---\n\ntwo")[1], .rule)
    }

    func testOnlyWebAndMailLinksAreTappable() {
        let rendered = text(render("[web](https://example.com/a) [mail](mailto:me@example.com) [plain](http://example.com)"))
        XCTAssertEqual(rendered.string, "web mail plain")
        for word in ["web", "mail", "plain"] {
            XCTAssertNotNil(attribute(.link, of: word, in: rendered, as: URL.self), word)
        }
        for destination in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "latch://vps?token=x",
                            "/relative", "https://user:password@example.com", "tel:123"] {
            let unsafe = text(render("[label](\(destination))"))
            XCTAssertEqual(unsafe.string, "label", destination)
            var links = 0
            unsafe.enumerateAttribute(.link, in: NSRange(location: 0, length: unsafe.length)) { value, _, _ in
                if value != nil { links += 1 }
            }
            XCTAssertEqual(links, 0, destination)
        }
    }

    func testAJavaScriptLinkIsNotTappableInTheTextView() throws {
        let view = TranscriptTextView()
        let blocks = render("[run](javascript:alert(1)) and [site](https://example.com)")
        view.setText(text(blocks))
        // The text view opens only what the renderer allows, even a link set some other way.
        XCTAssertFalse(MarkdownRenderer.isAllowed(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertTrue(MarkdownRenderer.isAllowed(try XCTUnwrap(URL(string: "https://example.com"))))
        var links: [URL] = []
        view.attributedText.enumerateAttribute(.link, in: NSRange(location: 0, length: view.attributedText.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links, [URL(string: "https://example.com")])
        XCTAssertTrue(view.dataDetectorTypes.isEmpty)
        XCTAssertFalse(view.isEditable)
    }

    func testImagesShowTheirAltTextAndHTMLStaysLiteral() {
        let rendered = text(render("![a diagram](https://example.com/x.png) <b>raw</b> <img src=\"https://e.com/a\">"))
        XCTAssertEqual(rendered.string, "a diagram <b>raw</b> <img src=\"https://e.com/a\">")
        var resources = 0
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            if attributes[.link] != nil || attributes[.attachment] != nil { resources += 1 }
        }
        XCTAssertEqual(resources, 0)
    }

    func testAVeryLongUnbrokenTokenWrapsInsideItsWidth() {
        let token = String(repeating: "abcdefghij", count: 60)
        let blocks = render("Before \(token) after")
        let view = MarkdownContentView()
        view.show(blocks, renderer: renderer)
        view.prepare(width: 300)
        let size = view.systemLayoutSizeFitting(CGSize(width: 300, height: UIView.layoutFittingCompressedSize.height),
                                                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        XCTAssertEqual(size.width, 300, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 100, "The token wraps onto many lines instead of running off the side")
        XCTAssertLessThan(size.height, 2_000)
    }

    func testBlocksKeepTheirOrderAcrossKinds() {
        let blocks = render("# Plan\n\nText\n\n```sh\nmake\n```\n\n| a |\n| - |\n| 1 |\n\n> quote\n\n---\n\nEnd")
        let kinds = blocks.map { block -> String in
            switch block {
            case .text: "text"
            case .quote: "quote"
            case .code: "code"
            case .table: "table"
            case .rule: "rule"
            }
        }
        XCTAssertEqual(kinds, ["text", "code", "table", "quote", "rule", "text"])
    }

    func testTheCacheRendersEachTextOnceAndAgainForANewTextSize() {
        let cache = MarkdownCache()
        let id = UUID()
        _ = cache.blocks(for: id, text: "**one**", traits: traits)
        _ = cache.blocks(for: id, text: "**one**", traits: traits)
        XCTAssertEqual(cache.renderCount, 1)
        _ = cache.blocks(for: id, text: "**one** two", traits: traits)
        XCTAssertEqual(cache.renderCount, 2)
        _ = cache.blocks(for: id, text: "**one** two", traits: UITraitCollection(preferredContentSizeCategory: .accessibilityLarge))
        XCTAssertEqual(cache.renderCount, 3)
        _ = cache.blocks(for: UUID(), text: "**one** two", traits: traits)
        XCTAssertEqual(cache.renderCount, 4, "Another message renders on its own")
    }

    func testStreamingReusesTheViewsAlreadyShown() {
        let view = MarkdownContentView()
        view.show(render("Intro\n\n```swift\nlet a = 1"), renderer: renderer)
        let first = view.blockViews
        view.show(render("Intro\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nDone"), renderer: renderer)
        XCTAssertTrue(view.blockViews[0] === first[0])
        XCTAssertTrue(view.blockViews[1] === first[1], "The growing code block keeps its view")
        XCTAssertEqual(view.blockViews.count, 3)
        XCTAssertEqual((view.blockViews[1] as? CodeBlockView)?.code, "let a = 1\nlet b = 2")
    }

    // MARK: Pieces and streaming

    func testARepliesSplitsIntoPiecesAtBlankLinesOutsideFences() {
        XCTAssertEqual(MarkdownRenderer.segments("One\n\nTwo\nstill two\n\n- a\n\n  more a\n- b"),
                       ["One\n\n", "Two\nstill two\n\n", "- a\n\n  more a\n- b"])
        XCTAssertEqual(MarkdownRenderer.segments("```\na\n\nb\n```\n\nafter"), ["```\na\n\nb\n```\n\n", "after"],
                       "A blank line inside a fence does not split it")
        XCTAssertEqual(MarkdownRenderer.segments("~~~~\n~~~\n\nx\n~~~~\n\ny").count, 2, "Only a long enough fence closes it")
        XCTAssertEqual(MarkdownRenderer.segments("See [the docs][d].\n\nMore.\n\n[d]: https://example.com").count, 1,
                       "A reference definition keeps the reply whole")
        XCTAssertEqual(MarkdownRenderer.segments(""), [])
    }

    /// Whatever prefix the cache saw last, its blocks equal a fresh render of the new text:
    /// reusing pieces never changes the output. Compared by structure, as the Mac's tests do.
    func testTheCacheMatchesAFreshRenderAtEveryPrefix() {
        let reply = """
            ## Plan

            First **step** with `code` and a [link](https://example.com).

            1. one
            2. two
               - nested

            ```swift
            let a = 1

            let b = 2
            ```

            | a | b |
            | - | - |
            | 1 | 2 |

            > quoted
            > still

            ---

            Done.
            """
        let cache = MarkdownCache()
        let id = UUID()
        var index = reply.startIndex
        while index < reply.endIndex {
            index = reply.index(after: index)
            let prefix = String(reply[..<index])
            let streamed = cache.blocks(for: id, text: prefix, traits: traits)
            let fresh = MarkdownCache().blocks(for: id, text: prefix, traits: traits)
            XCTAssertEqual(signature(streamed), signature(fresh), "At \(prefix.count): \(prefix.suffix(20))")
        }
        XCTAssertLessThan(cache.pieceRenderCount, reply.count + 20, "Growing text re-parses only its last piece")

        // Pieces rendered on their own say what the whole reply rendered at once says.
        let whole = render(reply)
        let pieces = cache.blocks(for: id, text: reply, traits: traits)
        func prose(_ blocks: [MarkdownBlock]) -> String {
            blocks.compactMap { if case let .text(text) = $0 { text.string } else { nil } }.joined(separator: "\n")
        }
        XCTAssertEqual(prose(pieces), prose(whole))
        XCTAssertEqual(signature(pieces).filter { !$0.hasPrefix("text:") }, signature(whole).filter { !$0.hasPrefix("text:") })
    }

    func testAGrowingReplyReparsesOnlyItsLastPiece() {
        let cache = MarkdownCache()
        let id = UUID()
        let paragraphs = (0..<50).map { "Paragraph \($0) with **bold** text." }.joined(separator: "\n\n")
        _ = cache.blocks(for: id, text: paragraphs, traits: traits)
        let before = cache.pieceRenderCount
        let blocks = cache.blocks(for: id, text: paragraphs + " More", traits: traits)
        XCTAssertEqual(cache.pieceRenderCount, before + 1)
        XCTAssertEqual(blocks.count, 50, "Each paragraph is a block of its own, so only the last text view changes")
    }

    private func signature(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case let .text(text): "text:\(text.string):\(text.length)"
            case let .quote(text): "quote:\(text.string)"
            case let .code(language, code): "code:\(language ?? ""):\(code)"
            case let .table(table): "table:\(([table.header] + table.rows).map { $0.map(\.string) })"
            case .rule: "rule"
            }
        }
    }

    // MARK: Structure

    func testAListItemThatOpensWithAFenceKeepsItsMarkerFirst() {
        let blocks = render("- ```\n  code first\n  ```\n  then text")
        XCTAssertEqual(blocks.count, 3, "\(blocks)")
        XCTAssertEqual(text(blocks, 0).string, "\t•\t")
        XCTAssertEqual(blocks[1], .code(language: nil, code: "code first"))
        XCTAssertEqual(text(blocks, 2).string, "then text")
    }

    func testTwoQuotesInARowAreTwoBlocks() {
        let blocks = render("> quote one\n\n> quote two")
        XCTAssertEqual(blocks.count, 2, "\(blocks)")
        XCTAssertEqual(text(blocks, 0).string, "quote one")
        XCTAssertEqual(text(blocks, 1).string, "quote two")
    }

    func testLinksInQuotesAndTablesAreOfferedToVoiceOver() {
        let view = MarkdownContentView()
        view.show(render("> [q](https://q.example)\n\n| a |\n| - |\n| [t](https://t.example) |"), renderer: renderer)
        XCTAssertEqual(view.links.map(\.url.absoluteString), ["https://q.example", "https://t.example"])
    }

    func testInlineCodeIsDrawnOnARoundedPanelOutsideTables() {
        let prose = text(render("Run `make` now"))
        XCTAssertNotNil(attribute(.inlineCodeBackground, of: "make", in: prose, as: UIColor.self))
        XCTAssertNil(attribute(.backgroundColor, of: "make", in: prose, as: UIColor.self))
        XCTAssertTrue(InlineCodeLayoutFragment.hasInlineCode(prose))
        guard case let .table(table) = render("| a |\n| - |\n| `x` |")[0] else { return XCTFail("Not a table") }
        XCTAssertNotNil(table.rows[0][0].attribute(.backgroundColor, at: 0, effectiveRange: nil), "Labels draw the plain background")
    }

    func testAVeryLongCodeLineIsCutForDisplayButCopiedWhole() {
        let line = String(repeating: "{\"key\":\"value\"},", count: 6_000)
        let view = CodeBlockView()
        view.show(.code(language: "json", code: "short\n" + line), renderer: renderer)
        XCTAssertEqual(view.code, "short\n" + line)
        let shown = view.displayedCode.split(separator: "\n")
        XCTAssertEqual(shown.first, "short")
        XCTAssertTrue(shown.last?.hasSuffix("…") ?? false)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        view.layoutIfNeeded()
        let widest = view.allDescendants.map(\.bounds.width).max() ?? 0
        XCTAssertLessThanOrEqual(widest, CodeBlockView.maximumLineWidth + 40, "No view is wider than a capped line")
    }

    func testACodeBlockWithoutALanguageStartsAtTheTop() {
        let plain = CodeBlockView()
        plain.show(.code(language: nil, code: "make"), renderer: renderer)
        let labelled = CodeBlockView()
        labelled.show(.code(language: "sh", code: "make"), renderer: renderer)
        for view in [plain, labelled] {
            view.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
            view.frame.size.height = view.systemLayoutSizeFitting(CGSize(width: 360, height: 0), withHorizontalFittingPriority: .required,
                                                                  verticalFittingPriority: .fittingSizeLevel).height
            view.layoutIfNeeded()
        }
        XCTAssertLessThan(plain.bounds.height, labelled.bounds.height - 20, "No empty header band without a language")
    }
}

private extension UIView {
    var allDescendants: [UIView] { subviews + subviews.flatMap(\.allDescendants) }
}
