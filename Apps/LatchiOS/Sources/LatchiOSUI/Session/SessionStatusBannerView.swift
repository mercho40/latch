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
}

/// A slim card under the navigation bar for the session's state: reconnecting, a failure
/// with what resolves it, an agent stopped on its server. It carries its own colour and
/// symbol, so nothing depends on seeing it arrive.
final class SessionStatusBannerView: UIView {
    var onAction: ((String) -> Void)?
    /// After the banner appears, changes or goes, so the transcript can make room for it.
    var onLayoutChange: (() -> Void)?

    private(set) var banner: SessionBanner?
    private var dismissedKey: String?
    private let card = UIView()
    /// The severity's colour over an opaque card, so the transcript never shows through it.
    private let wash = UIView()
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.backgroundColor = .systemBackground
        card.clipsToBounds = true
        wash.frame = card.bounds
        wash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(wash)
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
        actionRow.spacing = 8
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
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel, messageLabel, actionContainer])
        text.axis = .vertical
        text.alignment = .fill
        text.spacing = 3
        for view in [symbol, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leading.addSubview(view)
        }
        for view in [card, leading, text, dismissButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(card)
        card.addSubview(leading)
        card.addSubview(text)
        card.addSubview(dismissButton)
        NSLayoutConstraint.activate([
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
        titleLabel.accessibilityLabel = [banner.title, banner.detail, banner.message].filter { !$0.isEmpty }.joined(separator: ". ")
        titleLabel.accessibilityTraits = .staticText
        detailLabel.isAccessibilityElement = false
        messageLabel.isAccessibilityElement = false
        let wasHidden = isHidden
        setVisible(true)
        if wasHidden || !sameProblem {
            UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
        }
        onLayoutChange?()
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
        var configuration = UIButton.Configuration.tinted()
        configuration.title = action.title
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = LatchPalette.tint
        configuration.baseBackgroundColor = LatchPalette.tint
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        // The row is short; the target still reaches 44 points around the capsule.
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
        wash.backgroundColor = tint.withAlphaComponent(0.1)
        // An outline only with Increase Contrast; otherwise the wash is enough.
        card.layer.borderWidth = traitCollection.accessibilityContrast == .high ? 1 : 0
        card.layer.borderColor = tint.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
        symbol.tintColor = tint
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only the card takes touches; the margins around it pass them to the transcript.
        card.frame.contains(point)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: 0)
    }
}
