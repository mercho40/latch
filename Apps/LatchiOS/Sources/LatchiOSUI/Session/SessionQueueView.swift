import LatchSessionKit
import UIKit

/// Messages written while the agent works, in a card over the composer, in the order they will
/// go: a line for each, which Edit puts back in the composer and × takes out without sending.
/// Hidden while there are none. Many scroll, past a quarter of the window, as the plan does.
final class SessionQueueView: UIView {
    struct Row {
        let id: UUID
        /// The message's first line, or its photos when it has no text; VoiceOver reads both.
        let label: UILabel
        /// "+ 2 photos" after the text, kept whole while the text is cut short.
        let photos: UILabel
        let edit: UIButton
        let remove: UIButton
    }

    /// Puts a message back in the composer.
    var onEdit: ((UUID) -> Void)?
    /// Takes a message out without sending it.
    var onRemove: ((UUID) -> Void)?
    /// After the card appears, goes or changes height, so the transcript can make room for it.
    var onLayoutChange: (() -> Void)?
    private(set) var prompts: [QueuedPrompt] = []
    /// Each message's line and buttons, in order.
    private(set) var rows: [Row] = []

    let headingLabel = UILabel()
    private let card = UIView()
    private let surface = SessionPlanView.surface()
    private let scrollView = UIScrollView()
    private let list = UIStackView()
    private lazy var fitHeight = scrollView.heightAnchor.constraint(equalTo: list.heightAnchor)
    private lazy var maximumHeight = scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 160)

    override init(frame: CGRect) {
        super.init(frame: frame)
        SessionPlanView.mount(surface, in: card)
        headingLabel.textColor = .secondaryLabel
        headingLabel.numberOfLines = 0
        headingLabel.accessibilityTraits = .header
        list.axis = .vertical
        list.spacing = 0
        list.isLayoutMarginsRelativeArrangement = true
        list.directionalLayoutMargins = .init(top: 10, leading: 14, bottom: 4, trailing: 4)
        list.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(list)
        scrollView.alwaysBounceVertical = false
        for view in [card, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(card)
        card.addSubview(scrollView)
        // Below what the rows need, so a long queue scrolls rather than squeezing a row.
        fitHeight.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            list.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            fitHeight, maximumHeight,
        ])
        isHidden = true
        updateBorder()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) {
            (view: SessionQueueView, _) in view.render()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: SessionQueueView, _) in view.updateBorder()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `prompts`, or hides while there are none.
    func show(_ prompts: [QueuedPrompt]) {
        guard prompts.map(\.id) != self.prompts.map(\.id) else { return }
        self.prompts = prompts
        render()
        onLayoutChange?()
    }

    /// "Sends when the agent finishes", or for more than one, that they go one after another.
    static func heading(count: Int) -> String {
        count == 1 ? "Sends when the agent finishes" : "\(count) messages send in turn when the agent finishes"
    }

    /// A message on one line: its first line, then its photos, such as "Run it again + 2 photos".
    static func line(text: String, photos: Int) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let count = switch photos {
        case 0: ""
        case 1: "1 photo"
        default: "\(photos) photos"
        }
        if count.isEmpty { return first }
        return first.isEmpty ? count : "\(first) + \(count)"
    }

    /// The draft once messages are back in the composer, before what it held: each one's text,
    /// then the draft, with a blank line between them.
    static func draft(returning texts: [String], before draft: String) -> String {
        (texts + [draft]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    private static let largestButtonSize = UIContentSizeCategory.accessibilityMedium

    private func render() {
        isHidden = prompts.isEmpty
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        guard !prompts.isEmpty else { return }
        let traits = traitCollection
        // A caption over the messages, which at the largest sizes would take most of the card.
        headingLabel.font = .preferredFont(forTextStyle: .footnote, compatibleWith: UITraitCollection(
            preferredContentSizeCategory: min(traits.preferredContentSizeCategory, Self.largestButtonSize)))
        headingLabel.text = Self.heading(count: prompts.count)
        list.addArrangedSubview(headingLabel)
        list.setCustomSpacing(2, after: headingLabel)
        for prompt in prompts {
            let row = makeRow(prompt, traits: traits)
            list.addArrangedSubview(row.view)
            rows.append(row.parts)
        }
        setNeedsLayout()
    }

    private func makeRow(_ prompt: QueuedPrompt, traits: UITraitCollection) -> (view: UIView, parts: Row) {
        let large = traits.preferredContentSizeCategory.isAccessibilityCategory
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let symbol = UIImageView(image: UIImage(systemName: "clock"))
        symbol.preferredSymbolConfiguration = .init(font: font, scale: .small)
        symbol.tintColor = .secondaryLabel
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
        let label = UILabel()
        label.font = font
        let line = Self.line(text: prompt.text, photos: prompt.attachments.count)
        let first = Self.line(text: prompt.text, photos: 0)
        label.text = first.isEmpty ? line : first
        label.accessibilityLabel = line
        label.textColor = .label
        // At accessibility sizes a message keeps a few of its words, wrapped, beside the buttons.
        label.numberOfLines = large ? 3 : 1
        label.lineBreakMode = .byTruncatingTail
        // The photos take the room left over, so they follow the text rather than the buttons;
        // the text gives way first.
        label.setContentHuggingPriority(.defaultLow + 1, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let photos = UILabel()
        photos.font = font
        photos.textColor = .secondaryLabel
        photos.text = first.isEmpty || prompt.attachments.isEmpty ? nil
            : "+ " + Self.line(text: "", photos: prompt.attachments.count)
        photos.isHidden = photos.text == nil
        photos.isAccessibilityElement = false
        photos.numberOfLines = large ? 2 : 1
        photos.setContentHuggingPriority(.defaultLow, for: .horizontal)
        photos.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        // The buttons stay a size that leaves the message room; held down, they show large.
        let buttonFont = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: UITraitCollection(
            preferredContentSizeCategory: min(traits.preferredContentSizeCategory, Self.largestButtonSize)))
        var editStyle = UIButton.Configuration.plain()
        editStyle.title = "Edit"
        editStyle.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 8)
        let editFont = buttonFont.withWeight(.semibold)
        editStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = editFont
            return attributes
        }
        let edit = UIButton(configuration: editStyle, primaryAction: UIAction { [weak self] _ in self?.onEdit?(prompt.id) })
        edit.accessibilityHint = "Puts the message back in the composer."
        let remove = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in self?.onRemove?(prompt.id) })
        remove.configuration?.image = UIImage(systemName: "xmark.circle.fill")
        remove.configuration?.preferredSymbolConfigurationForImage = .init(font: buttonFont)
        remove.configuration?.baseForegroundColor = .tertiaryLabel
        remove.accessibilityLabel = "Remove"
        remove.accessibilityHint = "Takes the message out without sending it."
        for button in [edit, remove] {
            button.showsLargeContentViewer = true
            button.isPointerInteractionEnabled = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        edit.largeContentTitle = "Edit"
        remove.largeContentTitle = "Remove"
        remove.largeContentImage = UIImage(systemName: "xmark.circle.fill")
        remove.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // At accessibility sizes the photos go under the text, so neither crowds the other out.
        let words = UIStackView(arrangedSubviews: [label, photos])
        words.axis = large ? .vertical : .horizontal
        words.alignment = large ? .leading : .firstBaseline
        words.spacing = large ? 2 : 4
        let row = UIStackView(arrangedSubviews: [symbol, words, edit, remove])
        row.spacing = 8
        row.alignment = .center
        return (row, Row(id: prompt.id, label: label, photos: photos, edit: edit, remove: remove))
    }

    override func layoutSubviews() {
        // A quarter of the window at most, a third at accessibility sizes, where each row is
        // taller, and room for two rows however short the window is.
        let share: CGFloat = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 3 : 4
        maximumHeight.constant = max(120, (window?.bounds.height ?? 600) / share)
        super.layoutSubviews()
    }

    private func updateBorder() { SessionPlanView.outline(card, surface: surface, for: traitCollection) }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: 0)
    }
}
