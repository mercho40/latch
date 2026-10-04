import LatchACP
import LatchSessionKit
import UIKit

/// The field at the bottom of a session: a growing text view with the photos to send above
/// it, an Add Photos button before it, and one button after it that sends, or stops the turn
/// that is running; while the agent works and the draft has something in it, Send, with Stop
/// beside it. Before them, once the agent says, how much of its context is in use. Over it
/// all, while the agent has one, the agent's plan, and under that the messages waiting for the
/// turn to end. It holds the draft; the session decides what each state allows.
final class SessionComposerView: UIView, UITextViewDelegate {
    enum Action: Equatable {
        case send(enabled: Bool)
        case stop(enabled: Bool)
        /// The agent works, and the draft can go: into its turn when it `steers`, else once the
        /// turn ends. Stop sits before Send.
        case sendWhileWorking(steers: Bool, canStop: Bool)
    }

    /// Keys a hardware keyboard sends that the session may take before the text does.
    enum Key { case `return`, up, down, tab, escape }

    let textView = ComposerTextView()
    let placeholderLabel = UILabel()
    let attachButton = UIButton(type: .system)
    let actionButton = UIButton(type: .system)
    /// Stop, beside Send while the agent works and there is a draft to send.
    let stopButton = UIButton(type: .system)
    /// "25%" of the context in use; its menu has the tokens and the cost.
    let usageButton = UIButton(type: .system)
    private(set) var usage: ContextUsageSummary?
    let planView = SessionPlanView()
    let queueView = SessionQueueView()
    /// The plan over the queue, over the field.
    private let panels = UIStackView()
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
            case .send, .sendWhileWorking: onSend?()
            case .stop: onStop?()
            }
        }, for: .primaryActionTriggered)
        stopButton.isPointerInteractionEnabled = true
        stopButton.showsLargeContentViewer = true
        stopButton.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .primaryActionTriggered)
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
        usageButton.showsMenuAsPrimaryAction = true
        usageButton.showsLargeContentViewer = true
        usageButton.isPointerInteractionEnabled = true
        usageButton.isHidden = true
        // It stays a caption beside the field's text, which needs the room more; held down,
        // it shows large, as the bar's buttons do.
        usageButton.maximumContentSizeCategory = .extraExtraLarge
        // Never squeezed by the text, but gone entirely while there is nothing to show.
        usageButton.setContentHuggingPriority(.required, for: .horizontal)
        usageButton.setContentCompressionResistancePriority(.defaultHigh + 10, for: .horizontal)
        for view in [fieldBackground, dropHighlight, strip, textView, placeholderLabel, usageButton, stopButton, actionButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(view)
        }
        panels.axis = .vertical
        panels.spacing = 6
        panels.addArrangedSubview(planView)
        panels.addArrangedSubview(queueView)
        for view in [panels, attachButton, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        planView.onLayoutChange = { [weak self] in self?.panelsChanged() }
        queueView.onLayoutChange = { [weak self] in self?.panelsChanged() }
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
            field.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            fieldUnderMargin,
            panels.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            panels.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            panels.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
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
            textView.trailingAnchor.constraint(equalTo: usageButton.leadingAnchor),
            usageButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor),
            usageButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            usageButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            usageHidden,
            stopButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor),
            stopButton.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            stopButton.heightAnchor.constraint(equalToConstant: 44),
            stopWidth,
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
            view.configureUsageButton()
            view.textChanged(notify: false)
        }
        textChanged(notify: false)
    }

    private var stripHeight: NSLayoutConstraint?
    private var collapsedStrip: NSLayoutConstraint?
    private lazy var fieldUnderMargin = field.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor)
    private lazy var fieldUnderPanels = field.topAnchor.constraint(equalTo: panels.bottomAnchor, constant: 8)
    private lazy var placeholderBaseline = placeholderLabel.firstBaselineAnchor.constraint(equalTo: textView.topAnchor)
    /// No usage yet: the text runs to the action button.
    private lazy var usageHidden = usageButton.widthAnchor.constraint(equalToConstant: 0)
    /// Nothing but the action button, unless Stop is beside Send.
    private lazy var stopWidth = stopButton.widthAnchor.constraint(equalToConstant: 0)

    // MARK: State

    var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set {
            guard newValue != placeholderLabel.text else { return }
            placeholderLabel.text = newValue
            textChanged(notify: false)
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
        let hadStop = !stopButton.isHidden
        self.action = action
        configureActionButton()
        // Stop beside Send narrows the text, or gives it back: measured again once laid out.
        if hadStop == stopButton.isHidden {
            layoutIfNeeded()
            textChanged(notify: false)
        }
    }

    private func configureActionButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 30, weight: .regular)
        let title: String
        var hint: String?
        var stop: Bool?
        switch action {
        case let .send(enabled):
            configuration.image = UIImage(systemName: "arrow.up.circle.fill")
            title = "Send"
            actionButton.isEnabled = enabled
        case let .stop(enabled):
            configuration.image = UIImage(systemName: "stop.circle.fill")
            title = "Stop"
            actionButton.isEnabled = enabled
        case let .sendWhileWorking(steers, canStop):
            configuration.image = UIImage(systemName: "arrow.up.circle.fill")
            title = "Send"
            hint = steers ? "The agent takes it at its next step." : "Sends when the agent finishes."
            actionButton.isEnabled = true
            stop = canStop
        }
        configuration.baseForegroundColor = LatchPalette.tint
        actionButton.configuration = configuration
        actionButton.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseForegroundColor = button.isEnabled ? LatchPalette.tint : .tertiaryLabel
            button.configuration = updated
        }
        actionButton.accessibilityLabel = title
        actionButton.accessibilityHint = hint
        actionButton.largeContentTitle = title
        actionButton.largeContentImage = configuration.image
        configureStopButton(stop)
    }

    /// Stop beside Send is the quieter of the two, so the message just written goes with Send.
    private func configureStopButton(_ enabled: Bool?) {
        stopButton.isHidden = enabled == nil
        stopWidth.constant = enabled == nil ? 0 : 44
        guard let enabled else { return }
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.image = UIImage(systemName: "stop.circle.fill")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 30, weight: .regular)
        configuration.baseForegroundColor = .secondaryLabel
        stopButton.configuration = configuration
        stopButton.isEnabled = enabled
        stopButton.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseForegroundColor = button.isEnabled ? .secondaryLabel : .tertiaryLabel
            button.configuration = updated
        }
        stopButton.accessibilityLabel = "Stop"
        stopButton.largeContentTitle = "Stop"
        stopButton.largeContentImage = configuration.image
    }

    /// How much of its context the agent has used, as it last said: "25%" before the action
    /// button, amber once the context is mostly full, with the tokens and the cost in its menu
    /// and for VoiceOver. Nothing until the agent says.
    func setUsage(_ usage: ContextUsage?) {
        let summary = usage.map { ContextUsageSummary($0) }
        guard summary != self.usage else { return }
        self.usage = summary
        usageButton.isHidden = summary == nil
        usageHidden.isActive = summary == nil
        if let summary {
            configureUsageButton()
            usageButton.menu = UIMenu(title: summary.title, children: summary.details.map { UIAction(title: $0, attributes: .disabled) { _ in } })
            usageButton.accessibilityLabel = summary.spoken
            usageButton.largeContentTitle = summary.title
        }
        // The text's width changed: measured again once the field has laid it out.
        layoutIfNeeded()
        textChanged(notify: false)
    }

    /// Its font is scaled for its own traits, which stop at its largest size.
    private func configureUsageButton() {
        guard let usage else { return }
        var configuration = UIButton.Configuration.plain()
        configuration.title = usage.short
        configuration.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 2)
        configuration.baseForegroundColor = usage.isHigh ? .systemOrange : .secondaryLabel
        let size = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                                                                     compatibleWith: usageButton.traitCollection)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
        usageButton.configuration = configuration
    }

    /// The agent's plan, as it last listed it; empty when it has none.
    func setPlan(_ plan: [ACPPlanEntry]) {
        planView.show(plan)
    }

    /// The messages waiting for the turn to end, in order; empty when there are none.
    func setQueue(_ prompts: [QueuedPrompt]) {
        queueView.show(prompts)
    }

    private func panelsChanged() {
        let showing = !planView.plan.isEmpty || !queueView.prompts.isEmpty
        // The one in use goes before the other comes, so the two never conflict.
        if showing, !fieldUnderPanels.isActive {
            fieldUnderMargin.isActive = false
            fieldUnderPanels.isActive = true
        } else if !showing, fieldUnderPanels.isActive {
            fieldUnderPanels.isActive = false
            fieldUnderMargin.isActive = true
        }
        onHeightChange?()
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
        // An empty field is as tall as its placeholder, which wraps at large text sizes.
        let placeholderHeight = placeholderLabel.isHidden ? 0
            : ceil(placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height) + inset * 2
        let height = max(44, min(max(natural, placeholderHeight), maximum))
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

/// The agent's context usage as the composer says it: "25%", and "Context 25% full" with
/// "50,000 of 200,000 tokens" and "$0.12 so far" in its menu, as the Mac's tooltip has them.
struct ContextUsageSummary: Equatable {
    let short: String
    let title: String
    let details: [String]
    let spoken: String
    /// Mostly full: the agent will soon compact the conversation.
    let isHigh: Bool

    init(_ usage: ContextUsage, locale: Locale = .current) {
        let percent = Int((usage.fraction * 100).rounded())
        short = "\(percent)%"
        title = "Context \(percent)% full"
        let tokens = "\(usage.used.formatted(.number.locale(locale))) of \(usage.size.formatted(.number.locale(locale))) tokens"
        let cost = usage.cost.map { "\($0.formatted(.currency(code: usage.currency ?? "USD").locale(locale))) so far" }
        details = [tokens] + (cost.map { [$0] } ?? [])
        spoken = ([title] + details).joined(separator: ", ")
        isHigh = usage.fraction >= 0.8
    }
}
