import AppKit

@MainActor
final class ChatInputView: NSTextView {
    /// The keys a menu open over the field gets before the field does.
    enum MenuKey { case up, down, accept, dismiss }

    var onSubmit: (() -> Void)?
    /// Returns whether an open menu used the key; if not, the field handles it as usual.
    var onMenuKey: ((MenuKey) -> Bool)?
    var placeholder = "Message the agent…" { didSet { needsDisplay = true } }
    /// Drawn after the text in the placeholder colour, for what a chosen command expects next.
    var inputHint: String? { didSet { if inputHint != oldValue { needsDisplay = true } } }
    /// Offered a paste or a drop first; returns whether it took the content as attachments.
    /// Anything it declines is pasted or dropped as text, as before.
    var onAttach: ((NSPasteboard) -> Bool)?
    /// Where Paste reads from. Tests substitute a private pasteboard for the user's clipboard.
    var pasteSource = NSPasteboard.general

    override func paste(_ sender: Any?) {
        if onAttach?(pasteSource) == true { return }
        super.paste(sender)
    }

    /// Whether Paste would bring in attachments. A plain-text field enables Paste only when
    /// the clipboard holds text, so without this a screenshot left Paste, and ⌘V, disabled.
    var canPasteAttachments: Bool {
        onAttach != nil && isEditable && ComposerAttachment.canAttach(from: pasteSource)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)), canPasteAttachments { return true }
        return super.validateMenuItem(item)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), canPasteAttachments { return true }
        return super.validateUserInterfaceItem(item)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        attaches(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        attaches(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if attaches(sender), onAttach?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    private func attaches(_ drag: any NSDraggingInfo) -> Bool {
        onAttach != nil && isEditable && ComposerAttachment.canAttach(from: drag.draggingPasteboard)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = modifiers.intersection([.shift, .option, .control, .command]).isEmpty && !hasMarkedText()
        let menuKey: MenuKey? = switch event.keyCode {
        case 126 where plain: .up
        case 125 where plain: .down
        case 36, 76, 48 where plain: .accept
        case 53 where plain: .dismiss
        default: nil
        }
        if let menuKey, onMenuKey?(menuKey) == true { return }
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor,
        ]
        guard !string.isEmpty else {
            (placeholder as NSString).draw(
                at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                withAttributes: attributes
            )
            return
        }
        guard let inputHint, let layout = layoutManager, let container = textContainer else { return }
        let glyphs = layout.glyphRange(for: container)
        guard glyphs.length > 0 else { return }
        let last = layout.boundingRect(forGlyphRange: NSRange(location: NSMaxRange(glyphs) - 1, length: 1), in: container)
        (inputHint as NSString).draw(
            at: NSPoint(x: last.maxX + textContainerOrigin.x, y: last.minY + textContainerOrigin.y),
            withAttributes: attributes
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
