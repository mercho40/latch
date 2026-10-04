import LatchACP
import UIKit

/// How far the agent's plan has got, as the bar over the composer says it.
struct PlanSummary: Equatable {
    let completed: Int
    let total: Int
    /// The step in progress, or else the first one still to do.
    let current: String?
    /// Whether `current` is in progress rather than still to do.
    let isUnderway: Bool

    init(_ plan: [ACPPlanEntry]) {
        completed = plan.filter { $0.status == .completed }.count
        total = plan.count
        let underway = plan.first { $0.status == .inProgress }
        current = (underway ?? plan.first { $0.status == .pending })?.content
        isUnderway = underway != nil
    }

    /// "Plan · 2 of 5"
    var title: String { "Plan · \(completed) of \(total)" }

    /// "Plan, 2 of 5 done, now: Write the tests", or "next:" for a step not yet begun.
    var spoken: String {
        "Plan, \(completed) of \(total) done" + (current.map { ", \(isUnderway ? "now" : "next"): \($0)" } ?? "")
    }
}

/// The agent's plan in a slim card over the composer: how many of its steps are done, and the
/// one it is on. A tap opens the whole checklist under the summary, scrolling past a third of
/// the window, so the conversation keeps most of the screen; another tap closes it. Hidden
/// while the agent has no plan.
final class SessionPlanView: UIView {
    /// After the card opens, closes, appears or goes, so the transcript can make room for it.
    var onLayoutChange: (() -> Void)?
    private(set) var plan: [ACPPlanEntry] = []
    private(set) var isExpanded = false

    let header = UIControl()
    private let card = UIView()
    private let surface: UIView
    private let symbol = UIImageView(image: UIImage(systemName: "checklist"))
    private let titleLabel = UILabel()
    private let stepLabel = UILabel()
    private let headerText = UIStackView()
    private let headerRow = UIStackView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up"))
    private let scrollView = UIScrollView()
    private let list = UIStackView()
    /// The list's height and the space under it.
    private lazy var listHeight = scrollView.heightAnchor.constraint(equalTo: list.heightAnchor, constant: 10)
    private lazy var maximumListHeight = scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 200)
    private lazy var collapsedList = scrollView.heightAnchor.constraint(equalToConstant: 0)
    static let radius: CGFloat = 18

    override init(frame: CGRect) {
        surface = Self.surface()
        super.init(frame: frame)
        Self.mount(surface, in: card)

        symbol.tintColor = .secondaryLabel
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.textColor = .label
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stepLabel.textColor = .secondaryLabel
        stepLabel.lineBreakMode = .byTruncatingTail
        stepLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stepLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerText.addArrangedSubview(titleLabel)
        headerText.addArrangedSubview(stepLabel)
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerRow.addArrangedSubview(symbol)
        headerRow.addArrangedSubview(headerText)
        headerRow.addArrangedSubview(chevron)
        headerRow.spacing = 8
        headerRow.alignment = .center
        headerRow.isUserInteractionEnabled = false
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)
        header.isAccessibilityElement = true
        header.accessibilityTraits = .button
        header.showsLargeContentViewer = true
        header.largeContentImage = UIImage(systemName: "checklist")
        header.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: Self.radius))
        header.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .primaryActionTriggered)

        list.axis = .vertical
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(list)
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = false

        for view in [card, header, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(card)
        card.addSubview(header)
        card.addSubview(scrollView)
        // Below the steps' own resistance to being squeezed, so the list scrolls rather than
        // cutting a step short.
        listHeight.priority = .defaultHigh - 1
        collapsedList.isActive = true
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            headerRow.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
            list.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
            list.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            list.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -28),
        ])
        scrollView.isHidden = true
        isHidden = true
        accessibilityElements = [header, scrollView]
        updateBorder()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) {
            (view: SessionPlanView, _) in view.render()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: SessionPlanView, _) in view.updateBorder()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `plan`, or hides while it is empty. A new plan keeps the card open or closed.
    func show(_ plan: [ACPPlanEntry]) {
        guard plan != self.plan else { return }
        // The card's height changes when it comes or goes, or when the open list changes.
        let resizes = self.plan.isEmpty != plan.isEmpty || isExpanded
        self.plan = plan
        if plan.isEmpty { isExpanded = false }
        render()
        if resizes { onLayoutChange?() }
    }

    var summary: PlanSummary { PlanSummary(plan) }

    func toggle() {
        guard !plan.isEmpty else { return }
        isExpanded.toggle()
        render()
        onLayoutChange?()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.window?.layoutIfNeeded()
        }
        // The steps are read next, where VoiceOver's cursor already is.
        if isExpanded { UIAccessibility.post(notification: .layoutChanged, argument: header) }
    }

    private func render() {
        isHidden = plan.isEmpty
        guard !plan.isEmpty else { return }
        let traits = traitCollection
        let large = traits.preferredContentSizeCategory.isAccessibilityCategory
        let summary = summary
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        symbol.preferredSymbolConfiguration = .init(font: font)
        titleLabel.font = UIFont(descriptor: font.fontDescriptor.addingAttributes(
            [.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]]), size: 0)
        titleLabel.text = summary.title
        stepLabel.font = font
        stepLabel.text = summary.current
        stepLabel.isHidden = summary.current == nil
        // At accessibility sizes the step goes under the count, on up to two lines.
        headerText.axis = large ? .vertical : .horizontal
        headerText.alignment = large ? .leading : .firstBaseline
        headerRow.alignment = large ? .firstBaseline : .center
        headerText.spacing = large ? 2 : 6
        stepLabel.numberOfLines = large ? 2 : 1
        chevron.preferredSymbolConfiguration = .init(font: UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits),
                                                     scale: .medium)
        chevron.transform = isExpanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        header.accessibilityLabel = summary.spoken
        header.accessibilityHint = isExpanded ? "Hides the steps." : "Shows every step."
        header.accessibilityExpandedStatus = isExpanded ? .expanded : .collapsed
        header.largeContentTitle = summary.title

        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isExpanded {
            for entry in plan { list.addArrangedSubview(Self.row(for: entry, traits: traits)) }
        }
        scrollView.isHidden = !isExpanded
        collapsedList.isActive = !isExpanded
        listHeight.isActive = isExpanded
        maximumListHeight.isActive = isExpanded
        setNeedsLayout()
    }

    override func layoutSubviews() {
        // A third of the window at most, a quarter at accessibility sizes, whose summary is
        // taller, and room for a few steps however short the window is.
        let share: CGFloat = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 4 : 3
        maximumListHeight.constant = max(120, (window?.bounds.height ?? 600) / share)
        super.layoutSubviews()
    }

    private func updateBorder() { Self.outline(card, surface: surface, for: traitCollection) }

    /// The panel the plan and the queue over the composer sit on: glass from iOS 26, a grouped
    /// background with a hairline before it.
    static func surface() -> UIView {
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .corners(radius: .fixed(radius))
            return glass
        }
        let surface = UIView()
        surface.backgroundColor = .secondarySystemBackground
        surface.layer.cornerRadius = radius
        surface.layer.cornerCurve = .continuous
        surface.layer.borderWidth = 1 / max(1, UITraitCollection.current.displayScale)
        surface.layer.borderColor = UIColor.separator.cgColor
        return surface
    }

    /// `surface` behind everything in `card`, which clips to its corners.
    static func mount(_ surface: UIView, in card: UIView) {
        card.layer.cornerRadius = radius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        surface.isUserInteractionEnabled = false
        surface.frame = card.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.insertSubview(surface, at: 0)
    }

    /// With Increase Contrast an outline, where the panel alone is faint.
    static func outline(_ card: UIView, surface: UIView, for traits: UITraitCollection) {
        card.layer.borderWidth = traits.accessibilityContrast == .high ? 1 : 0
        card.layer.borderColor = UIColor.separator.resolvedColor(with: traits).cgColor
        if !(surface is UIVisualEffectView) {
            surface.layer.borderColor = UIColor.separator.resolvedColor(with: traits).cgColor
        }
    }

    /// The symbol for a step's state and how its text is set: still to do, a hollow circle;
    /// in progress, a filled one in the tint; done, a check, its text struck through.
    static func row(for entry: ACPPlanEntry, traits: UITraitCollection) -> UIView {
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let symbol = UIImageView()
        symbol.preferredSymbolConfiguration = .init(font: font)
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
        let label = UILabel()
        label.numberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        let state: String
        switch entry.status {
        case .pending:
            symbol.image = UIImage(systemName: "circle")
            symbol.tintColor = .tertiaryLabel
            state = "To do"
        case .inProgress:
            symbol.image = UIImage(systemName: "circle.inset.filled")
            symbol.tintColor = LatchPalette.tint
            state = "In progress"
        case .completed:
            symbol.image = UIImage(systemName: "checkmark.circle.fill")
            symbol.tintColor = .secondaryLabel
            attributes[.foregroundColor] = UIColor.secondaryLabel
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            state = "Done"
        }
        label.attributedText = NSAttributedString(string: entry.content, attributes: attributes)
        let row = UIStackView(arrangedSubviews: [symbol, label])
        row.spacing = 8
        row.alignment = .firstBaseline
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = .init(top: 5, leading: 0, bottom: 5, trailing: 0)
        row.isAccessibilityElement = true
        row.accessibilityLabel = entry.content
        row.accessibilityValue = state
        return row
    }
}
