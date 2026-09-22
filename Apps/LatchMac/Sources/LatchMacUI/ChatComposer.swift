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
        // TextKit 1 for the same reason the transcript uses it: the composer is sized to
        // its whole draft, so it needs a full height on every keystroke rather than a
        // viewport's worth. See TranscriptMessageView.arrange(width:).
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
    /// Concentric with the 36-point capsules inside it, which sit 8 points in: 18 + 8.
    static let cornerRadius: CGFloat = 26
    private var glass: NSView?

    /// The composer floats over the end of the transcript. On macOS 26 it is a pane of glass, so the
    /// conversation shows through it softened, and a shadow lifts it off the page; before that, a
    /// drawn panel.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.glass = glass
        }
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: -10)
        layer?.shadowRadius = 24
        updateShadow()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func layout() {
        super.layout()
        // A path, so the shadow is not recomputed from the alpha of everything inside on each frame.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    private func updateShadow() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowOpacity = dark ? 0.55 : 0.16
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard glass == nil else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadow()
        needsDisplay = true
    }
}
