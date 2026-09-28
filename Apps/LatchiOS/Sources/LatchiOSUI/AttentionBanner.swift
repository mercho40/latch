import UIKit
import UserNotifications

/// A small banner near the top of the window when a session that is not on screen finishes a
/// turn or wants a decision, while the app is active. Not a notification: nothing reaches the
/// system, and it goes by itself. Tapping it opens the session.
@MainActor
final class AttentionBannerPresenter {
    private weak var host: UIView?
    private(set) var current: AttentionBannerView?
    private var dismissal: Task<Void, Never>?
    private var urgent = false
    /// How long a banner stays: longer for a decision, which holds the agent up, and for
    /// VoiceOver users, who take longer to reach it.
    var duration: Duration {
        fixedDuration ?? (urgent || UIAccessibility.isVoiceOverRunning ? .seconds(8) : .seconds(4))
    }
    /// Holds banners up for screenshots.
    var fixedDuration: Duration?
    /// Where the banner goes, in the host's coordinates: under the navigation bar's buttons,
    /// and across the column it belongs to, which on iPad is the session's rather than the
    /// sidebar's, so the sidebar's buttons stay in reach. Nil puts it under the safe area's top.
    var placement: () -> (top: CGFloat, column: CGRect)? = { nil }

    init(host: UIView) { self.host = host }

    /// `urgent` is a decision waiting: it stays longer and taps a warning. Anything else is
    /// quiet, since a finished turn needs nothing done.
    func show(title: String, message: String, symbol: String, tint: UIColor, urgent: Bool = false,
              onTap: @escaping () -> Void) {
        guard let host else { return }
        dismiss(animated: false)
        self.urgent = urgent
        let banner = AttentionBannerView(title: title, message: message, symbol: symbol, tint: tint)
        banner.onTap = { [weak self] in
            self?.dismiss(animated: true)
            onTap()
        }
        banner.onSwipeAway = { [weak self] in self?.dismiss(animated: true) }
        // It stays while VoiceOver reads it, and gets its whole time again once left.
        banner.onFocusChange = { [weak self] focused in
            if focused { self?.dismissal?.cancel() } else { self?.scheduleDismissal() }
        }
        banner.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(banner)
        let guide = host.safeAreaLayoutGuide
        let place = placement()
        let column = UILayoutGuide()
        host.addLayoutGuide(column)
        banner.layoutGuide = column
        if let place {
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: place.column.minX),
                column.widthAnchor.constraint(equalToConstant: place.column.width),
                banner.topAnchor.constraint(equalTo: host.topAnchor, constant: place.top),
            ])
        } else {
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                banner.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            ])
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.heightAnchor.constraint(equalToConstant: 1),
            banner.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -8),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -8),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        let fill = banner.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16)
        fill.priority = .defaultHigh
        fill.isActive = true
        current = banner
        host.layoutIfNeeded()
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        banner.alpha = 0
        banner.transform = reduceMotion ? .identity : CGAffineTransform(translationX: 0, y: -24)
        UIView.animate(withDuration: reduceMotion ? 0.2 : 0.35, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0) {
            banner.alpha = 1
            banner.transform = .identity
        }
        if urgent { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: "\(title). \(message)", attributes: [.accessibilitySpeechQueueAnnouncement: true]))
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        let duration = duration
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool) {
        dismissal?.cancel()
        dismissal = nil
        guard let banner = current else { return }
        current = nil
        if let guide = banner.layoutGuide { banner.superview?.removeLayoutGuide(guide) }
        guard animated else { return banner.removeFromSuperview() }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: 0.25, animations: {
            banner.alpha = 0
            if !reduceMotion { banner.transform = CGAffineTransform(translationX: 0, y: -24) }
        }, completion: { _ in banner.removeFromSuperview() })
    }
}

/// A rounded card: a symbol, the session's title, and a line on what happened. Glass from
/// iOS 26, as the other floating surfaces are; a material with a shadow before it.
final class AttentionBannerView: UIControl {
    var onTap: (() -> Void)?
    var onSwipeAway: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    let titleLabel = UILabel()
    let messageLabel = UILabel()
    /// The column the presenter placed it in.
    fileprivate var layoutGuide: UILayoutGuide?
    static let radius: CGFloat = 22

    init(title: String, message: String, symbol: String, tint: UIColor) {
        super.init(frame: .zero)
        let background: UIVisualEffectView
        if #available(iOS 26.0, *) {
            // Tinted with the page's colour, so a large title under it does not read through.
            // Dark glass lets white text through its tint, so there it lies on a fill a shade
            // above black, which the glass then lights as it would the page.
            let glass = UIGlassEffect()
            glass.tintColor = UIColor.systemBackground.withAlphaComponent(0.6)
            background = UIVisualEffectView(effect: glass)
            background.cornerConfiguration = .corners(radius: .fixed(Self.radius))
            let fill = UIView()
            fill.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.secondarySystemBackground.resolvedColor(with: traits).withAlphaComponent(0.9) : .clear
            }
            fill.layer.cornerRadius = Self.radius
            fill.layer.cornerCurve = .continuous
            fill.isUserInteractionEnabled = false
            fill.frame = bounds
            fill.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(fill)
        } else {
            background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            background.layer.cornerRadius = Self.radius
            background.layer.cornerCurve = .continuous
            background.clipsToBounds = true
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: 4)
        }
        background.isUserInteractionEnabled = false
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = tint
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.text = title
        titleLabel.font = ChromeFont.preferred(.subheadline, weight: .semibold)
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        for label in [titleLabel, messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
        }
        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 1
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
        swipe.direction = .up
        addGestureRecognizer(swipe)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(title). \(message)"
        accessibilityHint = "Opens the session."
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Dismiss") { [weak self] _ in
            self?.onSwipeAway?()
            return true
        }]
        hoverStyle = UIHoverStyle(effect: .lift, shape: .rect(cornerRadius: Self.radius))
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        onFocusChange?(true)
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        onFocusChange?(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func swiped() { onSwipeAway?() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.8 : 1 }
    }
}

/// The app icon's badge: how many sessions wait for a decision. Badging needs notification
/// permission, asked for the first time the count would be more than zero, never at launch.
@MainActor
final class ApprovalBadge {
    typealias Authorize = @MainActor () async -> Bool
    typealias Apply = @MainActor (Int) async -> Void
    /// Whether badges are allowed already, without asking: nil when never asked.
    typealias Current = @MainActor () async -> Bool?

    private let authorize: Authorize
    private let apply: Apply
    private let current: Current
    private var authorized: Bool?
    private var pending: Task<Void, Never>?
    private(set) var count = 0

    init(authorize: @escaping Authorize = ApprovalBadge.requestBadgeAuthorization,
         apply: @escaping Apply = ApprovalBadge.setBadgeCount,
         current: @escaping Current = ApprovalBadge.currentBadgeAuthorization) {
        self.authorize = authorize
        self.apply = apply
        self.current = current
    }

    /// Sets the badge to `count` if badges are already allowed, zero included, so one left by
    /// a run that ended while a session waited does not stay. Asks for nothing: the launch
    /// calls this.
    func sync(_ count: Int) {
        self.count = count
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if self.authorized == nil { self.authorized = await self.current() }
            guard self.authorized == true, self.count == count else { return }
            await self.apply(count)
        }
    }

    /// Sets the badge, asking first whether badges are allowed the first time there is one to
    /// show and `mayAsk` says the moment suits: not while the request is on screen, where the
    /// system's question would cover it.
    func update(_ count: Int, mayAsk: Bool = true) {
        self.count = count
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value
            guard let self, self.count == count else { return }
            if self.authorized == nil {
                // Zero needs no badge, so it asks for nothing.
                guard count > 0, mayAsk else { return }
                self.authorized = await self.authorize()
            }
            guard self.authorized == true else { return }
            await self.apply(count)
        }
    }

    /// Waits for the badge to be applied, for tests.
    func settled() async { await pending?.value }

    static func requestBadgeAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])) ?? false
    }

    static func currentBadgeAuthorization() async -> Bool? {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return nil
        case .denied: return false
        default: return settings.badgeSetting == .enabled
        }
    }

    static func setBadgeCount(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// Fonts for the app's lists and forms, all following Dynamic Type.
enum ChromeFont {
    /// A text style at another weight.
    static func preferred(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// Monospaced, for paths, commands and addresses, scaled like `style`, heavier with Bold Text.
    static func monospaced(_ style: UIFont.TextStyle) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let weight = UIFont.Weight.regular.adjusted(for: UITraitCollection.current)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: weight))
    }

    /// Tabular digits, so a ticking time does not shuffle as it counts.
    static func digits(_ style: UIFont.TextStyle) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let weight = UIFont.Weight.regular.adjusted(for: UITraitCollection.current)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: .monospacedDigitSystemFont(ofSize: size, weight: weight))
    }
}
