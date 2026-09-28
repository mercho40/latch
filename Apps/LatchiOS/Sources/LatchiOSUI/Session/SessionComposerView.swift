import UIKit

/// The field at the bottom of a session: a growing text view with the photos to send above
/// it, an Add Photos button before it, and one button after it that sends, or stops the turn
/// that is running. It holds the draft; the session decides what each state allows.
final class SessionComposerView: UIView, UITextViewDelegate {
    enum Action: Equatable {
        case send(enabled: Bool)
        case stop(enabled: Bool)
    }

    /// Keys a hardware keyboard sends that the session may take before the text does.
    enum Key { case `return`, up, down, tab, escape }

    let textView = ComposerTextView()
    let placeholderLabel = UILabel()
    let attachButton = UIButton(type: .system)
    let actionButton = UIButton(type: .system)
    private let field = UIView()
    private let fieldBackground: UIView
    private let strip = UIScrollView()
    private let stripStack = UIStackView()
    private lazy var textHeight = textView.heightAnchor.constraint(equalToConstant: 44)
    private(set) var attachments: [ComposerImage] = []
    private(set) var action = Action.send(enabled: false)

    var onTextChange: ((String) -> Void)?
    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    var onAttach: (() -> Void)?
    var onRemoveAttachment: ((UUID) -> Void)?
    /// After the field grows or shrinks, so the transcript can keep its end in view.
    var onHeightChange: (() -> Void)?
    /// Photos pasted into the field.
    var onPasteImages: (([NSItemProvider]) -> Void)? {
        get { textView.onPasteImages }
        set { textView.onPasteImages = newValue }
    }
    /// Whether the session takes `key` now; when it does not, the text view has it as usual.
    var canHandleKey: ((Key) -> Bool)? {
        get { textView.canHandleKey }
        set { textView.canHandleKey = newValue }
    }
    var onKey: ((Key) -> Void)? {
        get { textView.onKey }
        set { textView.onKey = newValue }
    }

    /// The most lines the field grows to before it scrolls. At accessibility sizes fewer,
    /// so a phone held sideways with the keyboard up still shows some of the conversation.
    static let maximumLines = 6
    private var maximumLines: Int {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 3 : Self.maximumLines
    }
    private static let fieldRadius: CGFloat = 22

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            textChanged(notify: false)
        }
    }

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .corners(radius: .fixed(Self.fieldRadius))
            fieldBackground = glass
        } else {
            let plain = UIView()
            plain.backgroundColor = .secondarySystemBackground
            plain.layer.cornerRadius = Self.fieldRadius
            plain.layer.cornerCurve = .continuous
            plain.layer.borderWidth = 1 / max(1, UITraitCollection.current.displayScale)
            plain.layer.borderColor = UIColor.separator.cgColor
            fieldBackground = plain
        }
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = "Message"
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        // Wraps rather than cut the agent's name short at large text sizes.
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isAccessibilityElement = false

        var attach: UIButton.Configuration
        if #available(iOS 26.0, *) {
            attach = .glass()
        } else {
            attach = .gray()
            attach.cornerStyle = .capsule
        }
        attach.image = UIImage(systemName: "plus")
        attach.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .medium)
        attach.baseForegroundColor = .label
        attachButton.configuration = attach
        attachButton.accessibilityLabel = "Add Photos"
        attachButton.showsLargeContentViewer = true
        attachButton.largeContentTitle = "Add Photos"
        attachButton.largeContentImage = UIImage(systemName: "plus")
        attachButton.addAction(UIAction { [weak self] _ in self?.onAttach?() }, for: .primaryActionTriggered)
        attachButton.isPointerInteractionEnabled = true
        actionButton.isPointerInteractionEnabled = true

        actionButton.showsLargeContentViewer = true
        actionButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            switch action {
            case .send: onSend?()
            case .stop: onStop?()
            }
        }, for: .primaryActionTriggered)
        configureActionButton()

        strip.showsHorizontalScrollIndicator = false
        strip.alwaysBounceHorizontal = false
        stripStack.axis = .horizontal
        stripStack.spacing = 2
        stripStack.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(stripStack)
        strip.isHidden = true
        strip.accessibilityLabel = "Photos to send"

        dropHighlight.backgroundColor = LatchPalette.tint.withAlphaComponent(0.15)
        dropHighlight.layer.cornerRadius = Self.fieldRadius
        dropHighlight.layer.cornerCurve = .continuous
        dropHighlight.isUserInteractionEnabled = false
        dropHighlight.alpha = 0
        for view in [fieldBackground, dropHighlight, strip, textView, placeholderLabel, actionButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(view)
        }
        for view in [attachButton, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let stripHeight = strip.heightAnchor.constraint(equalToConstant: 72)
        let collapsedStrip = strip.heightAnchor.constraint(equalToConstant: 0)
        self.stripHeight = stripHeight
        self.collapsedStrip = collapsedStrip
        collapsedStrip.isActive = true
        NSLayoutConstraint.activate([
            attachButton.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            attachButton.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: 44),
            attachButton.heightAnchor.constraint(equalToConstant: 44),
            field.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            field.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            fieldBackground.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            fieldBackground.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            fieldBackground.topAnchor.constraint(equalTo: field.topAnchor),
            fieldBackground.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            dropHighlight.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            dropHighlight.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            dropHighlight.topAnchor.constraint(equalTo: field.topAnchor),
            dropHighlight.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            strip.topAnchor.constraint(equalTo: field.topAnchor),
            stripStack.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor, constant: 10),
            stripStack.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor, constant: -10),
            stripStack.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor, constant: 4),
            stripStack.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            stripStack.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor, constant: -4),
            textView.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor),
            textView.topAnchor.constraint(equalTo: strip.bottomAnchor),
            textView.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            textHeight,
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholderBaseline,
            actionButton.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            actionButton.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 44),
            actionButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        addInteraction(UILargeContentViewerInteraction())
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: SessionComposerView, _) in
            view.textChanged(notify: false)
        }
        textChanged(notify: false)
    }

    private var stripHeight: NSLayoutConstraint?
    private var collapsedStrip: NSLayoutConstraint?
    private lazy var placeholderBaseline = placeholderLabel.firstBaselineAnchor.constraint(equalTo: textView.topAnchor)

    // MARK: State

    var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set {
            placeholderLabel.text = newValue
            textView.accessibilityLabel = newValue.isEmpty ? "Message" : newValue
        }
    }

    var isEditable: Bool {
        get { textView.isEditable }
        set {
            textView.isEditable = newValue
            textView.textColor = newValue ? .label : .secondaryLabel
        }
    }

    var canAttach = true {
        didSet { attachButton.isEnabled = canAttach }
    }

    /// Photos are being dragged over the page: the field says it takes them.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) {
                self.dropHighlight.alpha = self.isDropTarget ? 1 : 0
            }
        }
    }
    private let dropHighlight = UIView()

    func setAction(_ action: Action) {
        guard action != self.action else { return }
        self.action = action
        configureActionButton()
    }

    private func configureActionButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 30, weight: .regular)
        let title: String
        switch action {
        case let .send(enabled):
            configuration.image = UIImage(systemName: "arrow.up.circle.fill")
            title = "Send"
            actionButton.isEnabled = enabled
        case let .stop(enabled):
            configuration.image = UIImage(systemName: "stop.circle.fill")
            title = "Stop"
            actionButton.isEnabled = enabled
        }
        configuration.baseForegroundColor = LatchPalette.tint
        actionButton.configuration = configuration
        actionButton.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseForegroundColor = button.isEnabled ? LatchPalette.tint : .tertiaryLabel
            button.configuration = updated
        }
        actionButton.accessibilityLabel = title
        actionButton.largeContentTitle = title
        actionButton.largeContentImage = configuration.image
    }

    func setAttachments(_ attachments: [ComposerImage]) {
        self.attachments = attachments
        stripStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            let tile = ComposerAttachmentTile(attachment) { [weak self] in self?.onRemoveAttachment?(attachment.id) }
            stripStack.addArrangedSubview(tile)
        }
        let showing = !attachments.isEmpty
        strip.isHidden = !showing
        collapsedStrip?.isActive = !showing
        stripHeight?.isActive = showing
        onHeightChange?()
    }

    // MARK: Growing

    func textViewDidChange(_ textView: UITextView) {
        textChanged(notify: true)
    }

    private func textChanged(notify: Bool) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        // One line sits centred in the 44 point field; more lines keep the same inset.
        let inset = max(6, floor((44 - font.lineHeight) / 2))
        textView.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        placeholderBaseline.constant = inset + font.ascender
        let width = textView.bounds.width > 0 ? textView.bounds.width : 200
        let natural = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let maximum = ceil(font.lineHeight * CGFloat(maximumLines) + inset * 2)
        let height = max(44, min(natural, maximum))
        textView.isScrollEnabled = natural > maximum
        if abs(textHeight.constant - height) > 0.5 {
            textHeight.constant = height
            onHeightChange?()
        }
        if notify { onTextChange?(textView.text) }
    }

    override func layoutSubviews() {
        let width = textView.bounds.width
        super.layoutSubviews()
        if abs(textView.bounds.width - width) > 0.5 { textChanged(notify: false) }
    }
}

/// A photo in the composer, with a button that takes it out again: its badge sits inside the
/// thumbnail's top corner, as in Messages, and its 44 point target lies wholly inside the
/// tile, so every point of it takes a tap.
private final class ComposerAttachmentTile: UIView {
    init(_ attachment: ComposerImage, remove: @escaping () -> Void) {
        super.init(frame: .zero)
        let image = UIImageView(image: attachment.thumbnail ?? UIImage(systemName: "photo"))
        image.contentMode = attachment.thumbnail == nil ? .center : .scaleAspectFill
        image.tintColor = .secondaryLabel
        image.backgroundColor = .tertiarySystemFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 10
        image.layer.cornerCurve = .continuous
        image.accessibilityIgnoresInvertColors = true
        image.isAccessibilityElement = true
        image.accessibilityLabel = "Image, \(attachment.name)"
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark.circle.fill")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, UIColor.black.withAlphaComponent(0.55)]))
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.accessibilityLabel = "Remove \(attachment.name)"
        button.showsLargeContentViewer = true
        button.largeContentTitle = "Remove \(attachment.name)"
        button.addAction(UIAction { _ in remove() }, for: .primaryActionTriggered)
        for view in [image, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            image.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            image.widthAnchor.constraint(equalToConstant: 56),
            image.heightAnchor.constraint(equalToConstant: 56),
            trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            bottomAnchor.constraint(greaterThanOrEqualTo: image.bottomAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        accessibilityElements = [image, button]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The composer's text: plain text, as typed or pasted, and photos pasted into it, which go
/// to the composer rather than into the text. On a hardware keyboard it offers the session
/// Return, the arrows, Tab and Escape first; whatever the session does not take, the text
/// view handles as usual, so Shift-Return and a Return that ends marked text still type.
final class ComposerTextView: UITextView {
    var onPasteImages: (([NSItemProvider]) -> Void)?
    var canHandleKey: ((SessionComposerView.Key) -> Bool)?
    var onKey: ((SessionComposerView.Key) -> Void)?

    private static let keys: [(String, SessionComposerView.Key, Selector)] = [
        ("\r", .return, #selector(returnKey)), (UIKeyCommand.inputUpArrow, .up, #selector(upKey)),
        (UIKeyCommand.inputDownArrow, .down, #selector(downKey)), ("\t", .tab, #selector(tabKey)),
        (UIKeyCommand.inputEscape, .escape, #selector(escapeKey)),
    ]

    override var keyCommands: [UIKeyCommand]? {
        Self.keys.map { input, _, action in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if let key = Self.keys.first(where: { $0.2 == action })?.1 {
            return markedTextRange == nil && canHandleKey?(key) == true
        }
        if action == #selector(paste(_:)), onPasteImages != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func returnKey() { onKey?(.return) }
    @objc private func upKey() { onKey?(.up) }
    @objc private func downKey() { onKey?(.down) }
    @objc private func tabKey() { onKey?(.tab) }
    @objc private func escapeKey() { onKey?(.escape) }

    /// A photo on the pasteboard is attached; text pastes as text.
    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if let onPasteImages, pasteboard.hasImages, !pasteboard.hasStrings {
            return onPasteImages(pasteboard.itemProviders)
        }
        super.paste(sender)
    }
}
