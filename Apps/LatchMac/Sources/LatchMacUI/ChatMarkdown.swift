import AppKit
import Foundation

/// Native, display-only Markdown. The caller retains the original source for raw copy.
/// Supports line-local emphasis, code and links, ATX headings, list items, quotes,
/// indented code, backtick/tilde fences (including unclosed streaming fences) and GFM
/// pipe tables. Prose line endings and code whitespace are retained; a table's source
/// punctuation is replaced by laid-out cells. Nested block structure, setext headings
/// and reference links are not interpreted. Image-markup lines stay literal; HTML stays
/// text. No attachments or external resources load.
@MainActor
internal enum ChatMarkdown {
    static let bodyFontSize: CGFloat = 14
    static let codeFontSize: CGFloat = 12
    static let tableCellPadding: CGFloat = 6

    static func render(_ source: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        var fence: (marker: Character, count: Int)?
        let lines = split(source)
        var index = 0
        while index < lines.count {
            let start = index
            let (line, ending) = lines[start]
            index += 1

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
            if let table = pipeTable(at: start, in: lines) {
                output.append(render(table))
                index = start + table.lineCount
                continue
            }
            output.append(prose(line, ending: ending))
        }
        return NSAttributedString(attributedString: output)
    }

    /// NSString line ranges preserve CRLF as well as Unicode paragraph separators.
    private static func split(_ source: String) -> [(content: String, ending: String)] {
        let text = source as NSString
        var lines: [(content: String, ending: String)] = []
        var offset = 0
        while offset < text.length {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: offset, length: 0))
            lines.append((text.substring(with: NSRange(location: offset, length: contentsEnd - offset)),
                          text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))))
            offset = end
        }
        return lines
    }

    /// A GFM pipe table: a header row, a delimiter row agreeing on column count, then
    /// body rows until the first line that is not a row. Ragged body rows are padded or
    /// truncated to the header's width so every row fills the same grid.
    private struct PipeTable {
        let alignments: [NSTextAlignment]
        /// Row 0 is the header.
        let rows: [[String]]
        let lineCount: Int
    }

    private static func pipeTable(at index: Int, in lines: [(content: String, ending: String)]) -> PipeTable? {
        guard index + 1 < lines.count, let header = tableCells(lines[index].content),
              let alignments = delimiterAlignments(lines[index + 1].content),
              alignments.count == header.count else { return nil }
        var rows = [header]
        var cursor = index + 2
        while cursor < lines.count, let cells = tableCells(lines[cursor].content) {
            rows.append((0..<header.count).map { $0 < cells.count ? cells[$0] : "" })
            cursor += 1
        }
        return PipeTable(alignments: alignments, rows: rows, lineCount: cursor - index)
    }

    /// Splits a candidate row on unescaped pipes, dropping the optional outer pair.
    /// Returns nil when the line opens a block that outranks a table or carries no pipe.
    private static func tableCells(_ line: String) -> [String]? {
        guard line.range(of: #"^ {0,3}(?:#{1,6}(?:[ \t]|$)|>)"#, options: .regularExpression) == nil,
              !line.hasPrefix("    "), !line.hasPrefix("\t") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var sawPipe = false
        for character in trimmed {
            if escaped {
                // A backslash escapes only the pipe here; the rest stays for inline parsing.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                sawPipe = true
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        guard sawPipe else { return nil }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        guard !cells.isEmpty else { return nil }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func delimiterAlignments(_ line: String) -> [NSTextAlignment]? {
        guard let cells = tableCells(line) else { return nil }
        var alignments: [NSTextAlignment] = []
        for cell in cells {
            guard cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.right)
            default: alignments.append(.left)
            }
        }
        return alignments
    }

    /// One paragraph per cell, each owned by a table block, so TextKit draws the shared grid
    /// and wraps long cells in place. The table always fills the container: the source has no
    /// say in its width, and the renderer cannot know the container's until layout.
    private static func render(_ table: PipeTable) -> NSAttributedString {
        let layout = NSTextTable()
        layout.numberOfColumns = table.alignments.count
        layout.layoutAlgorithm = .automaticLayoutAlgorithm
        layout.collapsesBorders = true
        layout.hidesEmptyCells = false
        let cells = table.rows.enumerated().map { row, texts in
            texts.map { inline($0, font: .systemFont(ofSize: bodyFontSize, weight: row == 0 ? .bold : .regular),
                               color: .labelColor) }
        }
        let shares = columnShares(cells, columns: layout.numberOfColumns)
        let result = NSMutableAttributedString()
        for (row, texts) in cells.enumerated() {
            for (column, text) in texts.enumerated() {
                let block = NSTextTableBlock(table: layout, startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setBorderColor(.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(tableCellPadding, type: .absoluteValueType, for: .padding)
                block.setValue(shares[column], type: .percentageValueType, for: .width)
                if row == 0 { block.backgroundColor = .quaternaryLabelColor }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.alignment = table.alignments[column]
                paragraph.lineBreakMode = .byWordWrapping
                let content = NSMutableAttributedString(attributedString: text)
                // Each cell is its own paragraph; the newline closes it rather than showing.
                content.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: bodyFontSize), .foregroundColor: NSColor.labelColor,
                ]))
                content.addAttribute(.paragraphStyle, value: paragraph,
                                     range: NSRange(location: 0, length: content.length))
                result.append(content)
            }
        }
        return result
    }

    /// Percentages of the container, one per column. Left to itself NSTextTable divides the
    /// width evenly, which starves a column of prose sitting beside a column of single words,
    /// so each column instead takes a share of its widest cell, floored at a third of an even
    /// split so that a column of short or empty cells still reads as a column. A table wider
    /// than its container shrinks every column alike, so a word longer than its share still
    /// breaks; wrapping the rest of the row is the cheaper loss.
    private static func columnShares(_ cells: [[NSAttributedString]], columns: Int) -> [CGFloat] {
        // A share covers the cell's chrome as well as its text, or every column lands short
        // by its padding and the narrow ones pay the most for it.
        let chrome = tableCellPadding * 2 + 2
        let natural = (0..<columns).map { column in
            cells.reduce(1 as CGFloat) { max($0, ceil($1[column].size().width) + chrome) }
        }
        let smallest = natural.reduce(0, +) / CGFloat(columns * 3)
        let widths = natural.map { max($0, smallest) }
        let total = widths.reduce(0, +)
        return widths.map { $0 / total * 100 }
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
        result.append(inline(content, font: baseFont, color: color))
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

    /// Emphasis, code spans and allowlisted links within one span of text. Carries no
    /// paragraph style, so block callers stay free to impose their own.
    private static func inline(_ content: String, font baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let plain = NSAttributedString(string: content, attributes: [.font: baseFont, .foregroundColor: color])
        // Do not discard image destinations or risk accidentally promoting an image to a link.
        guard !content.contains("!["), let parsed = try? AttributedString(markdown: content, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )) else { return plain }
        let result = NSMutableAttributedString()
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
