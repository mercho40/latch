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

    @MainActor private func font(_ rendered: NSAttributedString, at text: String) -> NSFont {
        let range = (rendered.string as NSString).range(of: text)
        guard range.location != NSNotFound,
              let font = rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else {
            XCTFail("Missing font for \(text)")
            return .systemFont(ofSize: 0)
        }
        return font
    }

    @MainActor private func assertNoLinksOrAttachments(_ rendered: NSAttributedString) {
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.attachment])
            XCTAssertNil(attributes[NSAttributedString.Key("NSImageURL")])
        }
    }
}
