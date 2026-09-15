import AppKit

@MainActor
final class ChatInputView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder = "Message the agent…" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if [36, 76].contains(event.keyCode),
           modifiers.intersection([.shift, .option, .control]).isEmpty,
           !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
        )
    }
}

/// Measures the native text layout, including wrapping and a trailing empty line.
/// Long drafts scroll instead of pushing the conversation out of the window.
@MainActor
final class ChatComposerScrollView: NSScrollView {
    static let minimumHeight: CGFloat = 56
    static let maximumHeight: CGFloat = 184
    private lazy var height = heightAnchor.constraint(equalToConstant: Self.minimumHeight)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func tile() {
        super.tile()
        refreshHeight()
    }

    /// Also called after draft restoration, sending, and undo (not just typing).
    func refreshHeight() {
        guard let text = documentView as? NSTextView,
              text.bounds.width > 0,
              let container = text.textContainer,
              let layout = text.layoutManager else { return }
        layout.ensureLayout(for: container)
        let contentHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let measured = ceil(contentHeight + text.textContainerInset.height * 2)
        let next = min(Self.maximumHeight, max(Self.minimumHeight, measured))
        if height.constant != next { height.constant = next }
    }
}

@MainActor
final class ChatComposerBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
