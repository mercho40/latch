import AppKit
import Foundation

/// Native, display-only Markdown. The caller retains the original source for raw copy.
/// Supports line-local emphasis, code and links, ATX headings, list items, quotes,
/// indented code and backtick/tilde fences (including unclosed streaming fences).
/// Prose line endings and code whitespace are retained. Nested block structure,
/// tables, setext headings and reference links are not interpreted. Image-markup
/// lines stay literal; HTML stays text. No attachments or external resources load.
@MainActor
internal enum ChatMarkdown {
    static let bodyFontSize: CGFloat = 14
    static let codeFontSize: CGFloat = 12

    static func render(_ source: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        var fence: (marker: Character, count: Int)?
        // NSString line ranges preserve CRLF as well as Unicode paragraph separators.
        let text = source as NSString
        var offset = 0
        while offset < text.length {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: offset, length: 0))
            let line = text.substring(with: NSRange(location: offset, length: contentsEnd - offset))
            let ending = text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
            offset = end

            if let active = fence {
                if let candidate = fenceMarker(line), candidate.marker == active.marker,
                   candidate.count >= active.count,
                   candidate.tail.trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                } else {
                    output.append(literal(line + ending, code: true))
                }
                continue
            }
            if let candidate = fenceMarker(line),
               candidate.marker != "`" || !candidate.tail.contains("`") {
                fence = (candidate.marker, candidate.count)
                continue
            }
            output.append(prose(line, ending: ending))
        }
        return NSAttributedString(attributedString: output)
    }

    private static func fenceMarker(_ line: String) -> (marker: Character, count: Int, tail: String)? {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return nil }
        let content = line.dropFirst(spaces)
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let count = content.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        return (marker, count, String(content.dropFirst(count)))
    }

    private static func literal(_ text: String, code: Bool = false) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: code ? NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
                        : NSFont.systemFont(ofSize: bodyFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        if code { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func prose(_ line: String, ending: String) -> NSAttributedString {
        // Do not discard image destinations or risk accidentally promoting an image to a link.
        if line.contains("![") { return literal(line + ending) }
        var content = line
        var prefix = ""
        var heading = 0
        var quoted = false
        var list = false
        if let range = content.range(of: #"^ {0,3}#{1,6}(?:[ \t]+|$)"#, options: .regularExpression) {
            heading = content[range].filter { $0 == "#" }.count
            content.removeSubrange(range)
            if let closing = content.range(of: #"[ \t]+#+[ \t]*$"#, options: .regularExpression) {
                content.removeSubrange(closing)
            }
        } else if let range = content.range(of: #"^ {0,3}(?:>[ \t]?)+"#, options: .regularExpression) {
            content.removeSubrange(range)
            quoted = true
        } else if let range = content.range(of: #"^[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+"#, options: .regularExpression) {
            let marker = String(content[range])
            let indent = String(marker.prefix { $0 == " " || $0 == "\t" })
            let number = marker.dropFirst(indent.count).prefix { $0.isNumber }
            prefix = indent + (number.isEmpty ? "• " : "\(number). ")
            content.removeSubrange(range)
            list = true
        } else if content.hasPrefix("    ") || content.hasPrefix("\t") {
            return literal(line + ending, code: true)
        }

        let size = heading == 0 ? bodyFontSize : bodyFontSize + CGFloat(7 - heading)
        let baseFont = NSFont.systemFont(ofSize: size, weight: heading == 0 ? .regular : .bold)
        let color: NSColor = quoted ? .secondaryLabelColor : .labelColor
        let result = NSMutableAttributedString(string: prefix, attributes: [.font: baseFont, .foregroundColor: color])
        if let parsed = try? AttributedString(markdown: content, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )) {
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                let code = intent.contains(.code)
                var font = code ? NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular) : baseFont
                if intent.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                // Explicit allowlist: never bridge image/HTML or other parser attributes.
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if code { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if !code, let url = run.link, isSafeLink(url) {
                    attributes[.link] = url
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        } else {
            result.append(NSAttributedString(string: content, attributes: [.font: baseFont, .foregroundColor: color]))
        }
        result.append(NSAttributedString(string: ending, attributes: [.font: baseFont, .foregroundColor: color]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        if quoted {
            paragraph.firstLineHeadIndent = 12
            paragraph.headIndent = 12
        } else if list {
            paragraph.headIndent = (prefix as NSString).size(withAttributes: [.font: baseFont]).width
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func isSafeLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host?.isEmpty == false && url.user == nil && url.password == nil
        // Markdown's bridged NSURL may report an empty URL.path for opaque URLs.
        case "mailto": return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.isEmpty == false
        default: return false
        }
    }
}
