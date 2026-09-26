import AppKit

/// The attachments waiting in the composer, above the draft: images as thumbnails, anything
/// else as its icon and name. Each has a remove button; the row scrolls sideways when full.
@MainActor
final class ComposerAttachmentStrip: NSView {
    static let height: CGFloat = 60
    static let thumbnailSize: CGFloat = 48
    /// The draft's text starts this far in, and so does the first attachment.
    static let leadingInset: CGFloat = 8

    var onRemove: ((UUID) -> Void)?
    private(set) var shown: [UUID] = []
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.leadingInset, bottom: 0, right: Self.leadingInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Attachments")
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func show(_ attachments: [ComposerAttachment]) {
        let ids = attachments.map(\.id)
        guard ids != shown else { return }
        shown = ids
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            let chip: NSView = if case .image = attachment.content {
                ImageChip(attachment) { [weak self] in self?.onRemove?(attachment.id) }
            } else {
                FileChip(attachment) { [weak self] in self?.onRemove?(attachment.id) }
            }
            stack.addArrangedSubview(chip)
        }
        isHidden = attachments.isEmpty
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// A small button that takes an attachment back out. Over a picture it needs a dark disc to
/// stand out from whatever the image shows; inside a chip a plain mark is enough.
@MainActor
private func removeButton(for name: String, overImage: Bool, action: @escaping () -> Void) -> NSButton {
    let button = ClosureButton(action: action)
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove \(name)")
    button.symbolConfiguration = .init(pointSize: overImage ? 8 : 9, weight: overImage ? .bold : .semibold)
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.contentTintColor = overImage ? .white : .secondaryLabelColor
    if overImage {
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        button.layer?.cornerRadius = 9
    }
    button.toolTip = "Remove \(name)"
    button.setAccessibilityLabel("Remove \(name)")
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 18),
        button.heightAnchor.constraint(equalToConstant: 18),
    ])
    return button
}

@MainActor
private final class ClosureButton: NSButton {
    private let run: () -> Void
    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    @objc private func fire() { run() }
}

/// The image itself, cropped square, with the remove button over its corner.
@MainActor
private final class ImageChip: NSView {
    init(_ attachment: ComposerAttachment, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        let size = ComposerAttachmentStrip.thumbnailSize
        let picture = NSView()
        picture.wantsLayer = true
        picture.layer?.contents = attachment.thumbnail
        picture.layer?.contentsGravity = .resizeAspectFill
        picture.layer?.cornerRadius = 10
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = 1
        picture.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picture)
        self.picture = picture
        let remove = removeButton(for: attachment.name, overImage: true, action: onRemove)
        addSubview(remove)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Room for the button to sit over the corner without being clipped.
            widthAnchor.constraint(equalToConstant: size + 6),
            heightAnchor.constraint(equalToConstant: size + 6),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor),
            picture.bottomAnchor.constraint(equalTo: bottomAnchor),
            picture.widthAnchor.constraint(equalToConstant: size),
            picture.heightAnchor.constraint(equalToConstant: size),
            remove.centerXAnchor.constraint(equalTo: picture.trailingAnchor, constant: -3),
            remove.centerYAnchor.constraint(equalTo: picture.topAnchor, constant: 3),
        ])
        toolTip = attachment.name
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image, \(attachment.name)")
        updateOutline()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private weak var picture: NSView?

    /// A hairline so a white screenshot still has an edge: black in light, white in dark.
    private func updateOutline() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        picture?.layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateOutline()
    }
}

/// The file's icon and name in a capsule, the remove button at its end.
@MainActor
private final class FileChip: NSView {
    init(_ attachment: ComposerAttachment, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        refreshFill()
        let icon = NSImageView(image: attachment.thumbnail)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: attachment.name)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let remove = removeButton(for: attachment.name, overImage: false, action: onRemove)
        for view in [icon, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(remove)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            remove.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = attachment.record.path ?? attachment.name
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File, \(attachment.name)")
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFill()
    }

    /// A layer colour is fixed when set, so it is resolved against this view's appearance.
    private func refreshFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }
}
