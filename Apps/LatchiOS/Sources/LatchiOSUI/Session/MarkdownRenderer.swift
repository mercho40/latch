import Foundation
import UIKit

/// One piece of a rendered reply. Prose runs are text a single text view shows; code, tables
/// and rules each get a view of their own, stacked in reply order.
enum MarkdownBlock: Equatable {
    case text(NSAttributedString)
    /// A block quote's prose, drawn beside a bar.
    case quote(NSAttributedString)
    /// Exact source text: nothing inside a fence is interpreted.
    case code(language: String?, code: String)
    case table(MarkdownTable)
    case rule
}

/// A GFM table, every row padded or cut to the header's column count.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    var alignments: [Alignment]
    var header: [NSAttributedString]
    var rows: [[NSAttributedString]]
}

extension NSAttributedString.Key {
    /// Inline code's background, which the transcript's text view draws as a rounded panel
    /// rather than the line-high box `.backgroundColor` draws.
    static let inlineCodeBackground = NSAttributedString.Key("LatchInlineCodeBackground")
    /// A heading's level, so the reply's stack can space a heading block apart.
    static let markdownHeading = NSAttributedString.Key("LatchMarkdownHeading")
}

/// Display-only Markdown through Foundation's parser, mapped to UIKit attributes. Nothing a
/// reply says is fetched or run: images show their alt text, HTML stays literal text, and only
/// http, https and mailto links are made tappable. The caller keeps the source for copying.
@MainActor
struct MarkdownRenderer {
    let traits: UITraitCollection

    init(traits: UITraitCollection) {
        self.traits = traits
    }

    func render(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return source.isEmpty ? [] : [.text(NSAttributedString(string: source, attributes: attributes(for: .body)))]
        }
        var builder = Builder(renderer: self)
        for run in parsed.runs {
            builder.add(String(parsed[run.range].characters), intent: run.presentationIntent,
                        inline: run.inlinePresentationIntent ?? [], link: run.link)
        }
        return builder.finish()
    }

    /// Where `source` can be rendered in independent pieces, so a streaming reply re-parses
    /// only its last piece. A piece starts at a line that begins in the first column after a
    /// blank line, outside a fence: nothing after such a line changes how the lines before it
    /// parse, since a table's delimiter row, a setext underline and a lazy continuation all
    /// follow their line directly. Only a link reference definition reaches back across the
    /// whole reply, so a reply with one stays in one piece.
    static func segments(_ source: String) -> [Substring] {
        var pieces: [Substring] = []
        var start = source.startIndex
        var fence: (marker: Character, count: Int, indent: Int)?
        var previousBlank = false
        var index = source.startIndex
        while index < source.endIndex {
            let lineEnd = source[index...].firstIndex(of: "\n") ?? source.endIndex
            let line = source[index..<lineEnd]
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let content = line.dropFirst(indent)
            let blank = content.allSatisfy(\.isWhitespace)
            if let open = fence {
                if let marker = content.first, marker == open.marker, indent <= open.indent + 3 {
                    let run = content.prefix(while: { $0 == marker }).count
                    if run >= open.count, content.dropFirst(run).allSatisfy(\.isWhitespace) { fence = nil }
                }
            } else {
                if previousBlank, indent == 0, !blank, index > start {
                    pieces.append(source[start..<index])
                    start = index
                }
                if indent <= 3, content.first == "[", content.contains("]:"),
                   content.range(of: #"^\[[^\]]+\]:"#, options: .regularExpression) != nil {
                    return [source[...]]
                }
                if let marker = content.first, marker == "`" || marker == "~" {
                    let run = content.prefix(while: { $0 == marker }).count
                    if run >= 3, marker == "~" || !content.dropFirst(run).contains("`") {
                        fence = (marker, run, indent)
                    }
                }
            }
            previousBlank = blank
            index = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
        }
        if start < source.endIndex { pieces.append(source[start...]) }
        return pieces
    }

    // MARK: Fonts

    enum Role: Equatable {
        case body, heading(Int), tableCell, tableHeader
    }

    func font(for role: Role) -> UIFont {
        switch role {
        case .body: preferred(.body)
        case let .heading(level):
            switch level {
            case 1: preferred(.title2, weight: .bold)
            case 2: preferred(.title3, weight: .semibold)
            case 3: preferred(.headline)
            default: preferred(.subheadline, weight: .semibold)
            }
        case .tableCell: preferred(.subheadline)
        case .tableHeader: preferred(.subheadline, weight: .semibold)
        }
    }

    /// Monospaced, scaled with Dynamic Type from the size it has at the default text size.
    func monospaced(_ size: CGFloat, for style: UIFont.TextStyle = .body, weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(
            for: .monospacedSystemFont(ofSize: size, weight: weight.adjusted(for: traits)), compatibleWith: traits)
    }

    /// The code font for text set in `font`: a touch smaller, because monospace runs large.
    func codeFont(matching font: UIFont) -> UIFont {
        let size = font.pointSize * 0.88
        let bold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
        return .monospacedSystemFont(ofSize: size, weight: (bold ? UIFont.Weight.semibold : .regular).adjusted(for: traits))
    }

    var codeBlockFont: UIFont { monospaced(14, for: .body) }

    private func preferred(_ style: UIFont.TextStyle, weight: UIFont.Weight? = nil) -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style, compatibleWith: traits)
        guard let weight else { return UIFont(descriptor: base, size: 0) }
        return UIFont(descriptor: base.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: 0)
    }

    func attributes(for role: Role) -> [NSAttributedString.Key: Any] {
        [.font: font(for: role), .foregroundColor: UIColor.label]
    }

    // MARK: Links

    /// Only the web and mail: a reply cannot open another app, a file, or script, and a link
    /// that carries a password is not followed.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
        case "mailto":
            return !url.absoluteString.dropFirst("mailto:".count).isEmpty
        default:
            return false
        }
    }
}

/// Walks the parser's runs in order and groups them into blocks by their presentation intent.
@MainActor
private struct Builder {
    let renderer: MarkdownRenderer
    private var blocks: [MarkdownBlock] = []

    private enum Open {
        /// `quote` is the outermost block quote's identity: two quotes in a row are two blocks.
        case prose(text: NSMutableAttributedString, quote: Int?, paragraph: Int, style: NSParagraphStyle)
        case code(id: Int, language: String?, text: String)
        case table(id: Int, table: TableBuilder)
        case rule(id: Int)
    }
    private var open: Open?
    static let inlineCodeKern: CGFloat = 3
    /// List items whose marker is already written: a second paragraph in an item has none.
    private var markedItems: Set<Int> = []

    init(renderer: MarkdownRenderer) {
        self.renderer = renderer
    }

    mutating func add(_ text: String, intent: PresentationIntent?, inline: InlinePresentationIntent, link: URL?) {
        let components = intent?.components ?? []
        if let code = components.first(where: { if case .codeBlock = $0.kind { true } else { false } }) {
            guard case let .codeBlock(language) = code.kind else { return }
            if case let .code(id, language, existing) = open, id == code.identity {
                open = .code(id: id, language: language, text: existing + text)
                return
            }
            markItemBeforeBlock(components)
            close()
            let hint = language?.trimmingCharacters(in: .whitespaces)
            open = .code(id: code.identity, language: hint?.isEmpty == false ? hint : nil, text: text)
            return
        }
        if let table = components.first(where: { if case .table = $0.kind { true } else { false } }) {
            guard case let .table(columns) = table.kind else { return }
            if case let .table(id, _) = open, id == table.identity {} else {
                markItemBeforeBlock(components)
                close()
                open = .table(id: table.identity, table: TableBuilder(alignments: columns.map(Self.alignment)))
            }
            guard case .table(let id, var builder) = open else { return }
            var row = 0
            var column = 0
            for component in components {
                switch component.kind {
                case .tableHeaderRow: row = 0
                case let .tableRow(index): row = index
                case let .tableCell(index): column = index
                default: break
                }
            }
            let role: MarkdownRenderer.Role = row == 0 ? .tableHeader : .tableCell
            builder.append(styled(text, role: role, inline: inline, link: link), row: row, column: column)
            open = .table(id: id, table: builder)
            return
        }
        if let rule = components.first(where: { $0.kind == .thematicBreak }) {
            if case let .rule(id) = open, id == rule.identity { return }
            close()
            open = .rule(id: rule.identity)
            return
        }
        addProse(text, components: components, inline: inline, link: link)
    }

    private mutating func addProse(_ text: String, components: [PresentationIntent.IntentType],
                                   inline: InlinePresentationIntent, link: URL?) {
        let paragraph = components.first?.identity ?? 0
        let quoteDepth = components.count(where: { $0.kind == .blockQuote })
        let quote = components.last(where: { $0.kind == .blockQuote })?.identity
        var level: Int?
        for component in components {
            if case let .header(value) = component.kind { level = value }
        }
        let role: MarkdownRenderer.Role = level.map { .heading($0) } ?? .body
        let isQuote = quote != nil
        let target: NSMutableAttributedString
        var style: NSParagraphStyle
        if case let .prose(existing, openQuote, current, currentStyle) = open, openQuote == quote {
            target = existing
            style = currentStyle
            if current != paragraph {
                // Each paragraph ends in a newline that carries its own style, so the spacing
                // after it is the spacing that paragraph asked for.
                target.append(NSAttributedString(string: "\n", attributes: target.attributes(at: target.length - 1, effectiveRange: nil)))
                style = startParagraph(in: target, components: components, role: role, quoteDepth: quoteDepth)
            }
        } else {
            close()
            target = NSMutableAttributedString()
            style = startParagraph(in: target, components: components, role: role, quoteDepth: quoteDepth)
        }
        let styledText = styled(text, role: role, inline: inline, link: link)
        let whole = NSRange(location: 0, length: styledText.length)
        // Inline code's panel reaches 3 points past its text: the character before it and its
        // own last one are kerned by that much, so the panel never touches the words beside
        // it. Only spacing: the text copied is unchanged.
        if inline.contains(.code), styledText.length > 0 {
            styledText.addAttribute(.kern, value: Builder.inlineCodeKern, range: NSRange(location: styledText.length - 1, length: 1))
            if target.length > 0, let last = target.string.unicodeScalars.last, !CharacterSet.newlines.contains(last),
               last != "\t", last != "\u{2028}" {
                target.addAttribute(.kern, value: Builder.inlineCodeKern, range: NSRange(location: target.length - 1, length: 1))
            }
        }
        styledText.addAttribute(.paragraphStyle, value: style, range: whole)
        if isQuote { styledText.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: whole) }
        if let level { styledText.addAttribute(.markdownHeading, value: level, range: whole) }
        target.append(styledText)
        open = .prose(text: target, quote: quote, paragraph: paragraph, style: style)
    }

    /// A list item that opens with a code block or a table: its marker goes on a line of its
    /// own before it, so the marker is not left for the item's next paragraph.
    private mutating func markItemBeforeBlock(_ components: [PresentationIntent.IntentType]) {
        guard let marker = listMarker(components) else { return }
        close()
        let style = paragraphStyle(components: components, role: .body, quoteDepth: 0)
        let font = renderer.font(for: .body)
        let markerFont = marker.last == "." ? UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) : font
        blocks.append(.text(NSAttributedString(string: "\t\(marker)\t", attributes: [
            .font: markerFont, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style,
        ])))
    }

    /// Writes a list item's marker, when the paragraph starts one, and returns its style.
    private mutating func startParagraph(in target: NSMutableAttributedString, components: [PresentationIntent.IntentType],
                                         role: MarkdownRenderer.Role, quoteDepth: Int) -> NSParagraphStyle {
        let style = paragraphStyle(components: components, role: role, quoteDepth: quoteDepth)
        guard let marker = listMarker(components) else {
            // A later paragraph in a list item lines up with the item's text.
            guard style.firstLineHeadIndent != style.headIndent, let continued = style.mutableCopy() as? NSMutableParagraphStyle else {
                return style
            }
            continued.firstLineHeadIndent = continued.headIndent
            return continued
        }
        let font = renderer.font(for: role)
        // Numbers in tabular figures, so a list's markers line up on their right edge.
        let markerFont = marker.last == "." ? UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) : font
        target.append(NSAttributedString(string: "\t\(marker)\t", attributes: [
            .font: markerFont, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style,
        ]))
        return style
    }

    /// Only an item's first paragraph carries the marker, after a leading tab that the
    /// paragraph style right-aligns it on.
    private mutating func listMarker(_ components: [PresentationIntent.IntentType]) -> String? {
        guard let index = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
              case let .listItem(ordinal) = components[index].kind,
              markedItems.insert(components[index].identity).inserted else { return nil }
        let depth = components.count(where: { if case .listItem = $0.kind { true } else { false } })
        let ordered = components[index...].first { $0.kind == .orderedList || $0.kind == .unorderedList }?.kind == .orderedList
        if ordered { return "\(ordinal)." }
        return ["•", "◦", "▪︎"][(depth - 1) % 3]
    }

    private func paragraphStyle(components: [PresentationIntent.IntentType], role: MarkdownRenderer.Role,
                                quoteDepth: Int) -> NSParagraphStyle {
        let font = renderer.font(for: role)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        let depth = components.count(where: { if case .listItem = $0.kind { true } else { false } })
        // Nested quotes step in inside the one bar the quote view draws.
        let quoteIndent = CGFloat(max(0, quoteDepth - 1)) * round(font.pointSize * 0.9)
        if depth > 0 {
            let step = round(font.pointSize * 1.45)
            let head = quoteIndent + CGFloat(depth) * step
            style.firstLineHeadIndent = quoteIndent + CGFloat(depth - 1) * step
            style.headIndent = head
            style.tabStops = [NSTextTab(textAlignment: .right, location: head - round(font.pointSize * 0.35)),
                              NSTextTab(textAlignment: .left, location: head)]
            style.paragraphSpacing = round(font.pointSize * 0.3)
        } else {
            style.firstLineHeadIndent = quoteIndent
            style.headIndent = quoteIndent
            style.paragraphSpacing = round(font.pointSize * 0.6)
        }
        if case let .heading(level) = role {
            style.paragraphSpacingBefore = level <= 2 ? round(font.pointSize * 0.5) : round(font.pointSize * 0.3)
            style.paragraphSpacing = round(font.pointSize * 0.25)
        }
        return style
    }

    private func styled(_ text: String, role: MarkdownRenderer.Role, inline: InlinePresentationIntent,
                        link: URL?) -> NSMutableAttributedString {
        var font = renderer.font(for: role)
        var traits = font.fontDescriptor.symbolicTraits
        if inline.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
        if inline.contains(.emphasized) { traits.insert(.traitItalic) }
        if traits != font.fontDescriptor.symbolicTraits,
           let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: 0)
        }
        // Line breaks inside a paragraph keep the paragraph's spacing: a line separator, not a newline.
        var string = text
        if inline.contains(.softBreak) || inline.contains(.lineBreak) { string = "\u{2028}" }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        if inline.contains(.code) {
            attributes[.font] = renderer.codeFont(matching: font)
            // Table cells are labels, which draw only the plain background.
            let inTable = role == .tableCell || role == .tableHeader
            attributes[inTable ? .backgroundColor : .inlineCodeBackground] = LatchPalette.inlineCode
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link, MarkdownRenderer.isAllowed(link) {
            attributes[.link] = link
        }
        return NSMutableAttributedString(string: string, attributes: attributes)
    }

    private static func alignment(_ column: PresentationIntent.TableColumn) -> MarkdownTable.Alignment {
        switch column.alignment {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    private mutating func close() {
        switch open {
        case let .prose(text, quote, _, _):
            blocks.append(quote != nil ? .quote(text) : .text(text))
        case let .code(_, language, text):
            // The fence's own final newline is not part of the code.
            blocks.append(.code(language: language, code: text.hasSuffix("\n") ? String(text.dropLast()) : text))
        case let .table(_, table):
            blocks.append(.table(table.table))
        case .rule:
            blocks.append(.rule)
        case nil:
            break
        }
        open = nil
    }

    mutating func finish() -> [MarkdownBlock] {
        close()
        return blocks
    }
}

private struct TableBuilder {
    let alignments: [MarkdownTable.Alignment]
    private var cells: [Int: [Int: NSMutableAttributedString]] = [:]

    init(alignments: [MarkdownTable.Alignment]) {
        self.alignments = alignments
    }

    mutating func append(_ text: NSAttributedString, row: Int, column: Int) {
        guard column < alignments.count else { return }
        let cell = cells[row, default: [:]][column] ?? NSMutableAttributedString()
        cell.append(text)
        cells[row, default: [:]][column] = cell
    }

    var table: MarkdownTable {
        let rows = (cells.keys.max() ?? 0)
        func row(_ index: Int) -> [NSAttributedString] {
            alignments.indices.map { cells[index]?[$0] ?? NSAttributedString() }
        }
        return MarkdownTable(alignments: alignments, header: row(0),
                             rows: rows == 0 ? [] : (1...rows).map(row))
    }
}

/// Rendered blocks per message, so a streaming update re-renders only the message that
/// changed, and within it only the pieces (`MarkdownRenderer.segments`) whose text changed:
/// as a reply grows, that is its last piece. Every piece renders to blocks of its own, so the
/// reply's views for the pieces before it are left alone too.
@MainActor
final class MarkdownCache {
    private struct Entry {
        let text: String
        let key: Key
        /// Copies, not slices: a slice would keep every earlier version of the reply alive.
        let pieces: [(text: String, blocks: [MarkdownBlock])]
        let blocks: [MarkdownBlock]
    }

    private struct Key: Equatable {
        let size: UIContentSizeCategory
        let bold: UILegibilityWeight
    }

    private var entries: [UUID: Entry] = [:]
    /// Messages rendered, for tests that check nothing is rendered twice.
    private(set) var renderCount = 0
    /// Pieces parsed, for tests that check a growing reply parses only its end.
    private(set) var pieceRenderCount = 0

    func blocks(for id: UUID, text: String, traits: UITraitCollection) -> [MarkdownBlock] {
        let key = Key(size: traits.preferredContentSizeCategory, bold: traits.legibilityWeight)
        let previous = entries[id].flatMap { $0.key == key ? $0 : nil }
        if let previous, previous.text == text { return previous.blocks }
        renderCount += 1
        let renderer = MarkdownRenderer(traits: traits)
        let old = previous?.pieces ?? []
        var pieces: [(text: String, blocks: [MarkdownBlock])] = []
        for (index, piece) in MarkdownRenderer.segments(text).enumerated() {
            if index < old.count, old[index].text == piece {
                pieces.append(old[index])
            } else {
                pieceRenderCount += 1
                let copy = String(piece)
                pieces.append((copy, renderer.render(copy)))
            }
        }
        let blocks = pieces.flatMap(\.blocks)
        entries[id] = Entry(text: text, key: key, pieces: pieces, blocks: blocks)
        return blocks
    }

    /// Forgets messages the transcript no longer holds.
    func keep(_ ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}
