import AppKit

extension NSAttributedString.Key {
    /// A block of code. The value is the source line that opened it, which keeps two blocks
    /// with nothing between them from being drawn as one.
    static let latchCodeBlock = NSAttributedString.Key("LatchCodeBlock")
    /// A run of quoted lines.
    static let latchQuote = NSAttributedString.Key("LatchQuote")
}

/// Draws what a character background cannot: one rounded, padded panel behind a whole code
/// block, and a bar beside a quote. Both are decoration over unchanged text, so the storage,
/// selection, find and the streaming edit path see exactly the characters they always did.
///
/// A layout manager rather than overlay views because this view is TextKit 1 on purpose, and
/// the panels then cost nothing to keep in step with text that is still arriving.
final class TranscriptLayoutManager: NSLayoutManager {
    static let codeInset: CGFloat = 12
    static let codePadding: CGFloat = 10
    static let quoteIndent: CGFloat = 14
    private static let codeRadius: CGFloat = 8
    private static let quoteBarWidth: CGFloat = 3

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first else { return }
        let width = container.size.width
        eachBlock(.latchCodeBlock, in: glyphsToShow) { rect in
            NSColor.quaternaryLabelColor.setFill()
            let panel = NSRect(x: origin.x, y: origin.y + rect.minY, width: width, height: rect.height)
            NSBezierPath(roundedRect: panel, xRadius: Self.codeRadius, yRadius: Self.codeRadius).fill()
        }
        eachBlock(.latchQuote, in: glyphsToShow) { rect in
            NSColor.tertiaryLabelColor.setFill()
            let bar = NSRect(x: origin.x, y: origin.y + rect.minY + 1, width: Self.quoteBarWidth, height: rect.height - 2)
            NSBezierPath(roundedRect: bar, xRadius: Self.quoteBarWidth / 2, yRadius: Self.quoteBarWidth / 2).fill()
        }
    }

    /// The vertical extent of every marked block touching `glyphs`. A block is drawn whole even
    /// when only part of it is dirty, or a partial redraw would square off its corners. First and
    /// last line fragments are enough: there is one column, so everything between lies within them.
    private func eachBlock(_ key: NSAttributedString.Key, in glyphs: NSRange, _ body: (NSRect) -> Void) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var position = characters.location
        while position < min(NSMaxRange(characters), storage.length) {
            var run = NSRange()
            let value = storage.attribute(key, at: position, longestEffectiveRange: &run, in: whole)
            if value != nil, run.length > 0 {
                let blockGlyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
                if blockGlyphs.length > 0 {
                    let first = lineFragmentRect(forGlyphAt: blockGlyphs.location, effectiveRange: nil)
                    let last = lineFragmentRect(forGlyphAt: NSMaxRange(blockGlyphs) - 1, effectiveRange: nil)
                    body(first.union(last))
                }
            }
            position = max(NSMaxRange(run), position + 1)
        }
    }
}
