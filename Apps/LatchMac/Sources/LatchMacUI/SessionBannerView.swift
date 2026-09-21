import AppKit

/// A label that reports the height its text actually needs at the width it was given.
/// Plain `NSTextField` wrapping labels report a single line until they are laid out, which
/// clips the first frame and leaves the stack a line short.
@MainActor
final class WrappingLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        guard bounds.width > 0, let cell else { return super.intrinsicContentSize }
        let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude))
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(measured.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// A connection problem, shown above the transcript with the actions that resolve it.
///
/// This replaces a permanent error label: a banner is keyed on the problem it reports, so
/// dismissing one failure does not hide the next, and the same failure does not re-nag
/// after the user has read it. It carries its own colour and icon, so nothing here depends
/// on motion to be understood.
@MainActor
final class SessionBannerView: NSView {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    enum Severity {
        case info, warning, error

        var tint: NSColor {
            switch self {
            case .info: .secondaryLabelColor
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

    /// Identifies the problem on screen. A refresh carrying the same key leaves the banner
    /// exactly as it is, so a re-render never resurrects something already dismissed.
    private(set) var key: String?
    private var dismissedKey: String?
    private var severity: Severity = .error

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = WrappingLabel(wrappingLabelWithString: "")
    private let actionRow = NSStackView()
    private let dismiss = NSButton()
    private let content = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private func build() {
        setAccessibilityRole(.group)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 12
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismiss.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        dismiss.isBordered = false
        dismiss.bezelStyle = .accessoryBarAction
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.target = self
        dismiss.action = #selector(dismissBanner)
        dismiss.setAccessibilityLabel("Dismiss")
        dismiss.setContentHuggingPriority(.required, for: .horizontal)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.addArrangedSubview(titleLabel)
        content.addArrangedSubview(messageLabel)
        content.addArrangedSubview(actionRow)

        for view in [icon, content, dismiss] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            content.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -8),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismiss.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dismiss.widthAnchor.constraint(equalToConstant: 18),
            dismiss.heightAnchor.constraint(equalToConstant: 18),
        ])
        messageLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    /// Show `problem`, or hide when it is nil. Returns without touching the view when the
    /// same problem is already on screen or has been dismissed.
    func update(key: String?, title: String, message: String, severity: Severity, actions: [Action]) {
        guard let key else {
            self.key = nil
            isHidden = true
            return
        }
        guard key != self.key else { return }
        self.key = key
        guard key != dismissedKey else {
            isHidden = true
            return
        }
        self.severity = severity
        icon.image = NSImage(systemSymbolName: severity.symbol, accessibilityDescription: nil)
        icon.contentTintColor = severity.tint
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        messageLabel.toolTip = message
        actionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions { actionRow.addArrangedSubview(button(for: action)) }
        actionRow.isHidden = actions.isEmpty
        setAccessibilityLabel("\(title). \(message)")
        needsDisplay = true
        guard isHidden else { return }
        isHidden = false
        // Infrequent, and never the only cue: the tint and icon carry the state on their
        // own, so this fade only softens the arrival.
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            animator().alphaValue = 1
        }
    }

    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    private func button(for action: Action) -> NSButton {
        let button = NSButton(title: action.title, target: self, action: #selector(runAction(_:)))
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(
            string: action.title,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                         .foregroundColor: NSColor.controlAccentColor])
        handlers[ObjectIdentifier(button)] = action.handler
        return button
    }

    @objc private func runAction(_ sender: NSButton) {
        handlers[ObjectIdentifier(sender)]?()
    }

    @objc private func dismissBanner() {
        dismissedKey = key
        isHidden = true
    }

    /// Reconnecting clears the record of what was dismissed: a failure the user dismissed
    /// before a retry must be able to report itself again if it happens again.
    func resetDismissal() { dismissedKey = nil }

    /// Drives the real dismiss button so a smoke run exercises the production path.
    func performDismissForSmokeTest() { dismiss.performClick(nil) }

    /// What the banner is currently telling the user, for tests and accessibility checks.
    var displayedTitle: String { titleLabel.stringValue }
    var displayedMessage: String { messageLabel.stringValue }
    var displayedSeverity: Severity { severity }
    var displayedActions: [String] { actionRow.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Concentric with the composer box below it: 10pt inside 12pt of inset.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        severity.tint.withAlphaComponent(0.08).setFill()
        path.fill()
        severity.tint.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
