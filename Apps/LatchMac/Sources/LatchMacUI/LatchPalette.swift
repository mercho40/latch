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
}
