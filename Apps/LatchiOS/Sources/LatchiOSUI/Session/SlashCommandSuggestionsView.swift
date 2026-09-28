import LatchACP
import UIKit

/// The agent's slash commands, over the composer while the draft is a bare `/query`. Tapping
/// one puts `/name ` in the draft; the keyboard stays with the composer throughout. On a
/// hardware keyboard the arrows move a highlight through them, as on the Mac.
final class SlashCommandSuggestionsView: UIView {
    var onChoose: ((ACPAvailableCommand) -> Void)?
    private(set) var matches: [ACPAvailableCommand] = []
    /// The row the arrows have reached, if they have moved.
    private(set) var highlightedIndex: Int?
    private var commands: [ACPAvailableCommand] = []
    private var query = ""
    private let background: UIVisualEffectView
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    static let maximumVisibleRows = 5
    private static let radius: CGFloat = 22

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .corners(radius: .fixed(Self.radius))
            background = glass
        } else {
            let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            material.layer.cornerRadius = Self.radius
            material.layer.cornerCurve = .continuous
            material.clipsToBounds = true
            background = material
        }
        super.init(frame: frame)
        // Glass has depth of its own; the material before it needs a shadow to float.
        if background.effect is UIBlurEffect {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 16
            layer.shadowOffset = CGSize(width: 0, height: 4)
        }
        stack.axis = .vertical
        scrollView.showsVerticalScrollIndicator = true
        scrollView.layer.cornerRadius = Self.radius
        scrollView.layer.cornerCurve = .continuous
        for view in [background, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Inset, so a highlighted row sits inside the rounded panel.
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -12),
            height,
        ])
        accessibilityLabel = "Commands"
        shouldGroupAccessibilityChildren = true
        // The rows' fonts are fixed when they are made: a new text size makes them again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: SlashCommandSuggestionsView, _) in
            view.matches = []
            view.show(view.commands, query: view.query)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Name prefixes first, then names containing the query, then descriptions; each group
    /// keeps the agent's order. An empty query lists everything. As on the Mac.
    static func filter(_ commands: [ACPAvailableCommand], query: String) -> [ACPAvailableCommand] {
        guard !query.isEmpty else { return commands }
        var prefix: [ACPAvailableCommand] = [], inName: [ACPAvailableCommand] = [], inDescription: [ACPAvailableCommand] = []
        for command in commands {
            if command.name.range(of: query, options: [.caseInsensitive, .anchored]) != nil { prefix.append(command) }
            else if command.name.range(of: query, options: .caseInsensitive) != nil { inName.append(command) }
            else if command.description.range(of: query, options: .caseInsensitive) != nil { inDescription.append(command) }
        }
        return prefix + inName + inDescription
    }

    /// The query while `draft` is a bare `/query`: one token, nothing after it yet.
    static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    /// Returns whether anything matched.
    @discardableResult
    func show(_ commands: [ACPAvailableCommand], query: String) -> Bool {
        self.commands = commands
        self.query = query
        let next = Self.filter(commands, query: query)
        if next != matches {
            matches = next
            highlightedIndex = nil
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for command in matches { stack.addArrangedSubview(row(for: command)) }
        }
        stack.layoutIfNeeded()
        let rows = stack.arrangedSubviews.prefix(Self.maximumVisibleRows)
        let fitting = rows.reduce(0) { $0 + $1.systemLayoutSizeFitting(
            CGSize(width: max(bounds.width, 280), height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height }
        height.constant = matches.isEmpty ? 0 : fitting + 12
        return !matches.isEmpty
    }

    /// The command Return or Tab takes: the highlighted one, or else the first.
    var highlighted: ACPAvailableCommand? {
        highlightedIndex.flatMap { matches.indices.contains($0) ? matches[$0] : nil } ?? matches.first
    }

    /// Moves the highlight, from none to the first or last row, and keeps it in view.
    func moveHighlight(by offset: Int) {
        guard !matches.isEmpty else { return }
        let next = highlightedIndex.map { min(max(0, $0 + offset), matches.count - 1) } ?? (offset > 0 ? 0 : matches.count - 1)
        highlightedIndex = next
        for (index, row) in stack.arrangedSubviews.enumerated() {
            let on = index == next
            (row as? UIButton)?.configuration?.background.backgroundColor = on ? LatchPalette.tint.withAlphaComponent(0.15) : .clear
            row.accessibilityTraits = on ? [.button, .selected] : .button
        }
        layoutIfNeeded()
        let row = stack.arrangedSubviews[next]
        scrollView.scrollRectToVisible(row.convert(row.bounds, to: scrollView), animated: false)
    }

    private func row(for command: ACPAvailableCommand) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        var title = AttributeContainer()
        title.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .medium),
                                                                  compatibleWith: traitCollection)
        title.foregroundColor = UIColor.label
        configuration.attributedTitle = AttributedString("/" + command.name, attributes: title)
        if !command.description.isEmpty {
            var subtitle = AttributeContainer()
            subtitle.font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection)
            subtitle.foregroundColor = UIColor.secondaryLabel
            configuration.attributedSubtitle = AttributedString(command.description, attributes: subtitle)
        }
        configuration.titleAlignment = .leading
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.subtitleLineBreakMode = .byTruncatingTail
        configuration.titlePadding = 2
        configuration.contentInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.background.cornerRadius = 14
        let button = UIButton(configuration: configuration)
        button.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 14))
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityLabel = "/" + command.name
        button.accessibilityValue = command.description
        button.addAction(UIAction { [weak self] _ in self?.onChoose?(command) }, for: .primaryActionTriggered)
        return button
    }
}
