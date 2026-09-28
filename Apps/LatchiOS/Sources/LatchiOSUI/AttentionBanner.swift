import UIKit
import UserNotifications

/// A small banner at the top of the window when a session that is not on screen finishes a
/// turn or wants a decision, while the app is active. Not a notification: nothing reaches the
/// system, and it goes by itself. Tapping it opens the session.
@MainActor
final class AttentionBannerPresenter {
    private weak var host: UIView?
    private(set) var current: AttentionBannerView?
    private var dismissal: Task<Void, Never>?
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    /// How long a banner stays; VoiceOver users get longer to reach it.
    var duration: Duration { fixedDuration ?? (UIAccessibility.isVoiceOverRunning ? .seconds(8) : .seconds(4)) }
    /// Holds banners up for screenshots.
    var fixedDuration: Duration?

    init(host: UIView) { self.host = host }

    func show(title: String, message: String, symbol: String, tint: UIColor, onTap: @escaping () -> Void) {
        guard let host else { return }
        dismiss(animated: false)
        let banner = AttentionBannerView(title: title, message: message, symbol: symbol, tint: tint)
        banner.onTap = { [weak self] in
            self?.dismiss(animated: true)
            onTap()
        }
        banner.onSwipeAway = { [weak self] in self?.dismiss(animated: true) }
        banner.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(banner)
        // Over the navigation bar, a little wider than its buttons, so none shows at a corner.
        let guide = host.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: guide.topAnchor, constant: -2),
            banner.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -8),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        let fill = banner.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -16)
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
        feedback.impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "\(title). \(message)")
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
        guard animated else { return banner.removeFromSuperview() }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: 0.25, animations: {
            banner.alpha = 0
            if !reduceMotion { banner.transform = CGAffineTransform(translationX: 0, y: -24) }
        }, completion: { _ in banner.removeFromSuperview() })
    }
}

/// A rounded material card: a symbol, the session's title, and one line on what happened.
final class AttentionBannerView: UIControl {
    var onTap: (() -> Void)?
    var onSwipeAway: (() -> Void)?
    let titleLabel = UILabel()
    let messageLabel = UILabel()

    init(title: String, message: String, symbol: String, tint: UIColor) {
        super.init(frame: .zero)
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        background.isUserInteractionEnabled = false
        background.layer.cornerRadius = 24
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

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

    /// Monospaced, for paths, commands and addresses, scaled like `style`.
    static func monospaced(_ style: UIFont.TextStyle) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        return UIFontMetrics(forTextStyle: style).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    /// Tabular digits, so a ticking time does not shuffle as it counts.
    static func digits(_ style: UIFont.TextStyle) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        return UIFontMetrics(forTextStyle: style).scaledFont(for: .monospacedDigitSystemFont(ofSize: size, weight: .regular))
    }
}
