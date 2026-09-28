import UIKit

/// What the banner under the navigation bar says. `key` names the problem: a refresh with
/// the same key leaves the banner as it is, and a dismissed key stays dismissed.
struct SessionBanner: Equatable {
    enum Severity: Equatable {
        case info, warning, error

        var tint: UIColor {
            switch self {
            case .info: .secondaryLabel
            case .warning: .systemOrange
            case .error: .systemRed
            }
        }

        var symbol: String {
            switch self {
            case .info: "clock.arrow.circlepath"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "exclamationmark.octagon.fill"
            }
        }

        /// Said before the title, since VoiceOver does not describe the symbol.
        var spokenPrefix: String {
            switch self {
            case .info: ""
            case .warning: "Warning: "
            case .error: "Error: "
            }
        }
    }

    struct Action: Equatable {
        let title: String
        let id: String
    }

    var key: String
    var title: String
    /// Latch's advice, in its own words.
    var message = ""
    /// What the agent or server said, set off in monospace so it reads as their report.
    var detail = ""
    var severity = Severity.error
    /// In place of the severity's symbol, for a state rather than a fault.
    var symbol: String?
    /// A spinner in place of the symbol, while something is being waited for.
    var isWaiting = false
    var actions: [Action] = []
    /// Whether VoiceOver's cursor moves to the banner when it appears, rather than hearing it
    /// read out: by default only for a failure, or a warning with something to do about it.
    /// Reconnecting, which comes and goes on its own, never takes the cursor.
    var takesFocus: Bool?

    var movesFocus: Bool {
        takesFocus ?? (!isWaiting && (severity == .error || (severity == .warning && !actions.isEmpty)))
    }
}

/// A slim card under the navigation bar for the session's state: reconnecting, a failure
/// with what resolves it, an agent stopped on its server. One neutral card whatever the
/// severity, glass from iOS 26 like the composer and the slash suggestions; only the symbol
/// carries the colour, so nothing depends on seeing it arrive.
final class SessionStatusBannerView: UIView, UIContextMenuInteractionDelegate {
    var onAction: ((String) -> Void)?
    /// After the banner appears, changes or goes, so the transcript can make room for it.
    var onLayoutChange: (() -> Void)?

    private(set) var banner: SessionBanner?
    private var dismissedKey: String?
    private let card = UIView()
    /// The card's surface: glass, or before iOS 26 the grouped background's second step.
    private let surface: UIView
    /// Before iOS 26, the page's own colour behind the gap over the card, so nothing scrolled
    /// under the navigation bar shows between the two. From iOS 26 the scroll edge does that.
    private let backdrop = UIView()
    private let text = UIStackView()
    private let symbol = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionRow = UIStackView()
    /// Sets the actions 10 points below whichever line of text is last.
    private let actionContainer = UIView()
    private let leading = UIView()
    /// The symbol's column, as wide as the symbol at the current text size.
    private lazy var leadingWidth = leading.widthAnchor.constraint(equalToConstant: 22)
    private let dismissButton = UIButton(type: .system)

    static let radius: CGFloat = 22

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .corners(radius: .fixed(Self.radius))
            surface = glass
        } else {
            surface = UIView()
            surface.backgroundColor = .secondarySystemBackground
            surface.layer.cornerRadius = Self.radius
            surface.layer.cornerCurve = .continuous
        }
        super.init(frame: frame)
        card.layer.cornerRadius = Self.radius
        card.layer.cornerCurve = .continuous
        surface.isUserInteractionEnabled = false
        surface.frame = card.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(surface)
        backdrop.backgroundColor = .systemBackground
        backdrop.isUserInteractionEnabled = false
        if #available(iOS 26.0, *) { backdrop.isHidden = true }
        symbol.preferredSymbolConfiguration = .init(textStyle: .subheadline, scale: .medium)
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        spinner.hidesWhenStopped = true
        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        detailLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 4
        detailLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        actionRow.axis = .horizontal
        actionRow.spacing = 12
        actionRow.alignment = .center
        var dismiss = UIButton.Configuration.plain()
        dismiss.image = UIImage(systemName: "xmark")
        dismiss.preferredSymbolConfigurationForImage = .init(textStyle: .caption1, scale: .medium)
        dismiss.baseForegroundColor = .secondaryLabel
        dismissButton.configuration = dismiss
        dismissButton.accessibilityLabel = "Dismiss"
        dismissButton.addAction(UIAction { [weak self] _ in self?.dismiss() }, for: .primaryActionTriggered)

        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionContainer.addSubview(actionRow)
        NSLayoutConstraint.activate([
            actionRow.leadingAnchor.constraint(equalTo: actionContainer.leadingAnchor),
            actionRow.trailingAnchor.constraint(lessThanOrEqualTo: actionContainer.trailingAnchor),
            actionRow.topAnchor.constraint(equalTo: actionContainer.topAnchor, constant: 7),
            actionRow.bottomAnchor.constraint(equalTo: actionContainer.bottomAnchor, constant: 2),
        ])
        [titleLabel, detailLabel, messageLabel, actionContainer].forEach(text.addArrangedSubview)
        text.axis = .vertical
        text.alignment = .fill
        text.spacing = 3
        for view in [symbol, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leading.addSubview(view)
        }
        for view in [backdrop, card, leading, text, dismissButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(backdrop)
        addSubview(card)
        card.addSubview(leading)
        card.addSubview(text)
        card.addSubview(dismissButton)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: card.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            leading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            leading.topAnchor.constraint(equalTo: card.topAnchor),
            leadingWidth,
            text.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 8),
            text.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            text.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            text.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            dismissButton.topAnchor.constraint(equalTo: card.topAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 44),
            dismissButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // Level with the title's first line, however large the text.
        for view in [symbol, spinner] {
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -titleLabel.font.capHeight / 2),
            ])
        }
        isHidden = true
        card.isAccessibilityElement = false
        accessibilityElements = [text, dismissButton]
        text.isAccessibilityElement = false
        // A long press on the words copies them: at four lines the agent's may be cut short.
        text.addInteraction(UIContextMenuInteraction(delegate: self))
        dismissButton.isPointerInteractionEnabled = true
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: SessionStatusBannerView, _) in
            view.updateColors()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: SessionStatusBannerView, _) in
            view.arrangeActions()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `banner`, or hides when it is nil. Returns without touching the view when the
    /// same banner is already showing, or its key was dismissed.
    func show(_ banner: SessionBanner?) {
        guard let banner else {
            guard self.banner != nil else { return }
            self.banner = nil
            setVisible(false)
            return
        }
        guard banner != self.banner else { return }
        let sameProblem = banner.key == self.banner?.key
        self.banner = banner
        guard banner.key != dismissedKey else {
            setVisible(false)
            return
        }
        titleLabel.text = banner.title
        detailLabel.text = banner.detail
        detailLabel.isHidden = banner.detail.isEmpty
        messageLabel.text = banner.message
        messageLabel.isHidden = banner.message.isEmpty
        symbol.image = UIImage(systemName: banner.symbol ?? banner.severity.symbol)
        symbol.isHidden = banner.isWaiting
        if banner.isWaiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        actionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in banner.actions { actionRow.addArrangedSubview(button(for: action)) }
        arrangeActions()
        actionContainer.isHidden = banner.actions.isEmpty
        updateColors()
        titleLabel.accessibilityLabel = banner.severity.spokenPrefix + fullText
        titleLabel.accessibilityTraits = .staticText
        detailLabel.isAccessibilityElement = false
        messageLabel.isAccessibilityElement = false
        let wasHidden = isHidden
        setVisible(true)
        if wasHidden || !sameProblem {
            // A failure to act on takes VoiceOver's cursor; anything else is read out after
            // what is being read, and the cursor stays in the composer or the conversation.
            if banner.movesFocus {
                UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
            } else {
                UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                    string: banner.severity.spokenPrefix + banner.title, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
            }
        }
        onLayoutChange?()
    }

    /// Everything the banner says, in reading order.
    private var fullText: String {
        guard let banner else { return "" }
        return [banner.title, banner.detail, banner.message].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard banner != nil else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = self?.fullText
            }])
        })
    }

    /// Side by side, or at accessibility sizes one above the other, so neither title is cut.
    private func arrangeActions() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        leadingWidth.constant = ceil(UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 22, compatibleWith: traitCollection))
        detailLabel.numberOfLines = stacked ? 10 : 4
        actionRow.axis = stacked ? .vertical : .horizontal
        actionRow.alignment = stacked ? .leading : .center
    }

    /// Clears what was dismissed, so a failure after a Retry can report itself again.
    func resetDismissal() { dismissedKey = nil }

    var displayedActions: [String] { banner.map { _ in actionRow.arrangedSubviews.compactMap { ($0 as? UIButton)?.configuration?.title } } ?? [] }
    /// Whether a banner is showing or on its way in; false from the moment one starts to go.
    private(set) var isShowing = false

    private func dismiss() {
        dismissedKey = banner?.key
        setVisible(false)
    }

    private func button(for action: SessionBanner.Action) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = action.title
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
            return attributes
        }
        let button = BannerActionButton(configuration: configuration)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        button.isPointerInteractionEnabled = true
        button.addAction(UIAction { [weak self] _ in self?.onAction?(action.id) }, for: .primaryActionTriggered)
        return button
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isShowing else { return }
        isShowing = visible
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let offset = CGAffineTransform(translationX: 0, y: -8)
        if visible {
            if isHidden {
                isHidden = false
                alpha = 0
                transform = reduceMotion ? .identity : offset
            }
            onLayoutChange?()
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
                self.alpha = 1
                self.transform = .identity
            }
        } else {
            onLayoutChange?()
            UIView.animate(withDuration: 0.2, animations: {
                self.alpha = 0
                if !reduceMotion { self.transform = offset }
            }, completion: { _ in
                // A banner shown again while this one faded out stays.
                guard !self.isShowing else { return }
                self.isHidden = true
                self.transform = .identity
            })
        }
    }

    private func updateColors() {
        let tint = (banner?.severity ?? .info).tint
        // An outline in the severity's colour only with Increase Contrast.
        card.layer.borderWidth = traitCollection.accessibilityContrast == .high ? 1 : 0
        card.layer.borderColor = tint.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
        symbol.tintColor = tint
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only the card takes touches; the margins around it pass them to the transcript.
        card.frame.contains(point)
    }
}

/// A small capsule whose target still reaches 44 points: the row is short, and the spacing
/// between buttons keeps the enlarged areas apart.
private final class BannerActionButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -4, dy: -max(0, 44 - bounds.height) / 2).contains(point)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: 0)
    }
}
