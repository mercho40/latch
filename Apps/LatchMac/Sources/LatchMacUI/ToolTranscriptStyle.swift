import AppKit

/// Styles a persisted plain-text preview without interpreting Markdown, loading
/// resources, or creating actionable file/URL links. Copy and search stay literal.
@MainActor
enum ToolTranscriptStyle {
    /// `titled` is false for text whose title line is shown elsewhere, so its first line is ordinary content.
    static func render(_ text: String, titled: Bool = true) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let source = text as NSString
        var position = 0
        var diffSection = false
        var diffHunk = false
        while position < source.length {
            var end = 0
            var contentEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentEnd,
                                for: NSRange(location: position, length: 0))
            let range = NSRange(location: position, length: end - position)
            let line = source.substring(with: NSRange(location: position, length: contentEnd - position))
            if line.isEmpty { diffSection = false; diffHunk = false }
            if line.hasPrefix("Diff: ") { diffSection = true; diffHunk = false }
            if diffSection && line.hasPrefix("@@ ") {
                diffHunk = true
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            } else if diffHunk && (line.hasPrefix("+") || line.hasPrefix("-")) {
                let color: NSColor = line.hasPrefix("+") ? .systemGreen : .systemRed
                result.addAttributes([.foregroundColor: color, .backgroundColor: color.withAlphaComponent(0.08)], range: range)
            } else if (titled && position == 0) || ["Content:", "Locations:"].contains(line)
                        || line.hasPrefix("Diff: ") || line.hasPrefix("rawInput (") || line.hasPrefix("rawOutput (") {
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), range: range)
            }
            position = end
        }
        return result
    }
}
