import AppKit

enum LatchPalette {
    /// The page a conversation sits on, from under the toolbar to the window's bottom edge.
    /// In dark it is deeper than the sidebar, so the transcript is the lowest layer and the
    /// sidebar and the glass composer sit above it; light keeps the system's window colour.
    /// Anything that fades or dims into the page has to use this, or its edge shows.
    static let page = NSColor(name: "LatchPage") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)
            : .windowBackgroundColor
    }

    /// The panel behind a code block: a faint wash of the text colour rather than a grey slab,
    /// so on the dark page it reads as set into the page, not stacked on it.
    static let codeBlock = tint(dark: 0.05, light: 0.035)
    /// The hairline around that panel, which gives it an edge the faint fill alone would not.
    static let codeBlockEdge = tint(dark: 0.08, light: 0.07)
    /// Behind inline `code`: a little stronger than a block, because it is a few characters wide.
    static let inlineCode = tint(dark: 0.09, light: 0.06)
    /// The rule under a table's header row.
    static let tableRule = tint(dark: 0.18, light: 0.16)
    /// The fainter rule between a table's body rows.
    static let tableRowRule = tint(dark: 0.08, light: 0.07)

    /// White over the dark page, black over the light one, at the given strength.
    private static func tint(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        }
    }
}
