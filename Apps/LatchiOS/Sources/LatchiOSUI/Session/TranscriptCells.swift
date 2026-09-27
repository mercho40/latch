import LatchSessionKit
import UIKit

/// What every transcript cell is configured from, besides its message.
@MainActor
struct TranscriptCellContext {
    let agentTitle: String
    let renderer: MarkdownRenderer
    let cache: MarkdownCache
    var isExpanded: (UUID) -> Bool
    var toggle: (UUID) -> Void
}

/// A transcript row: no background, no selection, content running the readable width.
class TranscriptCell: UICollectionViewListCell {
    /// Space above and below the content, so tool calls in a row sit together as one burst.
    var verticalInsets: (top: CGFloat, bottom: CGFloat) { (8, 8) }
    private(set) var topConstraint: NSLayoutConstraint?
    private(set) var bottomConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        accessibilityRespondsToUserInteraction = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pins `view` to the content view's edges, inset vertically by `verticalInsets`.
    func pin(_ view: UIView, leading: Bool = true, trailing: Bool = true) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        let insets = verticalInsets
        let top = view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insets.top)
        let bottom = view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -insets.bottom)
        // Below required, so the estimated size a cell starts at never conflicts with its content.
        bottom.priority = .required - 1
        top.isActive = true
        bottom.isActive = true
        if leading { view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor).isActive = true }
        if trailing { view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor).isActive = true }
        topConstraint = top
        bottomConstraint = bottom
    }

    /// Called with the width the layout gives the cell, before it measures its height.
    func prepare(width: CGFloat) {}

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes {
        prepare(width: layoutAttributes.size.width)
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    static func copyAction(_ text: @escaping () -> String) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = text()
            return true
        }
    }
}

/// The user's prompt: a bubble in the tint's soft tone at the trailing edge, as wide as its
/// text up to four fifths of the row (and never wider than a phone's), with the images that
/// went with it listed above.
final class UserMessageCell: TranscriptCell {
    private let bubble = UIView()
    private let stack = UIStackView()
    private let chips = UIStackView()
    let textView = TranscriptTextView()
    private lazy var textWidth = textView.widthAnchor.constraint(equalToConstant: 0)
    private var text = ""
    private static let padding = NSDirectionalEdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.backgroundColor = LatchPalette.userBubble
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        stack.axis = .vertical
        stack.alignment = .trailing
        stack.spacing = 6
        chips.axis = .vertical
        chips.alignment = .trailing
        chips.spacing = 4
        stack.addArrangedSubview(chips)
        stack.addArrangedSubview(textView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(stack)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: padding.leading),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -padding.trailing),
            stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: padding.top),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -padding.bottom),
            textWidth,
        ])
        pin(bubble, leading: false)
        bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 40).isActive = true
        isAccessibilityElement = true
    }

    func configure(_ message: ChatMessage, context: TranscriptCellContext) {
        text = message.text
        let font = context.renderer.font(for: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        textView.setText(NSAttributedString(string: message.text, attributes: [
            .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
        ]))
        textView.isHidden = message.text.isEmpty
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in message.attachments {
            chips.addArrangedSubview(AttachmentChip(attachment, renderer: context.renderer))
        }
        chips.isHidden = message.attachments.isEmpty
        let names = message.attachments.map(\.name)
        accessibilityLabel = "You: " + ([message.text] + (names.isEmpty ? [] : ["Attached: " + names.joined(separator: ", ")]))
            .filter { !$0.isEmpty }.joined(separator: ". ")
        accessibilityCustomActions = [Self.copyAction { [weak self] in self?.text ?? "" }]
        setNeedsLayout()
    }

    override func prepare(width: CGFloat) {
        let padding = Self.padding
        let available = max(1, min(width * 0.8, width - 40, 520) - padding.leading - padding.trailing)
        let measured = textView.attributedText.boundingRect(
            with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width
        let chipWidth = chips.arrangedSubviews.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width }.max() ?? 0
        let content = min(available, max(textView.isHidden ? 0 : ceil(measured) + 1, chipWidth))
        textWidth.constant = content
        textView.prepare(width: content)
    }
}

/// An image or file that went with a prompt: its symbol and name. The bytes are not kept.
final class AttachmentChip: UIView {
    init(_ attachment: ChatAttachment, renderer: MarkdownRenderer) {
        super.init(frame: .zero)
        let symbol = UIImageView(image: UIImage(systemName: attachment.kind == .image ? "photo" : "doc"))
        symbol.preferredSymbolConfiguration = .init(textStyle: .footnote)
        symbol.tintColor = .secondaryLabel
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.text = attachment.name
        label.font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: renderer.traits)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingMiddle
        let row = UIStackView(arrangedSubviews: [symbol, label])
        row.spacing = 5
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(attachment.kind == .image ? "Image" : "File"), \(attachment.name)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The agent's reply: Markdown across the full width, selectable.
final class AssistantMessageCell: TranscriptCell {
    let markdown = MarkdownContentView()
    private var text = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        pin(markdown)
        isAccessibilityElement = true
    }

    func configure(_ message: ChatMessage, context: TranscriptCellContext) {
        text = message.text
        agentTitle = context.agentTitle
        let blocks = context.cache.blocks(for: message.id, text: message.text, traits: context.renderer.traits)
        markdown.show(blocks, renderer: context.renderer)
        setNeedsLayout()
    }

    private var agentTitle = ""

    // Worked out when VoiceOver asks, not on every streamed frame.
    override var accessibilityLabel: String? {
        get { "\(agentTitle): \(markdown.spokenText)" }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            var actions = [Self.copyAction { [weak self] in self?.text ?? "" }]
            let code = markdown.codeBlocks
            for (index, block) in code.prefix(4).enumerated() {
                let name = code.count == 1 ? "Copy Code" : "Copy \(block.language.map { "\($0) " } ?? "")Code \(index + 1)"
                actions.append(UIAccessibilityCustomAction(name: name, image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = block.code
                    return true
                })
            }
            for link in markdown.links.prefix(8) {
                actions.append(UIAccessibilityCustomAction(name: "Open \(link.title)", image: UIImage(systemName: "safari")) { _ in
                    UIApplication.shared.open(link.url)
                    return true
                })
            }
            return actions
        }
        set {}
    }

    override func prepare(width: CGFloat) {
        markdown.prepare(width: width)
    }

    /// Measured by hand: the reply knows its height once prepared, and asking Auto Layout
    /// would solve every block's constraints again on each streamed frame.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes {
        markdown.prepare(width: layoutAttributes.size.width)
        let fitted = layoutAttributes.copy() as? UICollectionViewLayoutAttributes ?? layoutAttributes
        let insets = verticalInsets
        fitted.size.height = markdown.preparedHeight + insets.top + insets.bottom
        return fitted
    }
}

/// A tool call: one compact row with its symbol, title and status, which expands to the
/// details in monospace.
final class ToolCallCell: TranscriptCell {
    /// The header's own 44 point height is the spacing, so a burst of calls sits together.
    override var verticalInsets: (top: CGFloat, bottom: CGFloat) { (0, 2) }
    let header = ToolCallHeader()
    private let detailsBox = UIView()
    let detailsView = TranscriptTextView()
    private let stack = UIStackView()
    private var text = ""
    private var id: UUID?
    private var toggle: ((UUID) -> Void)?
    private(set) var isExpanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        detailsBox.backgroundColor = LatchPalette.codeBackground
        detailsBox.layer.cornerRadius = 10
        detailsBox.layer.cornerCurve = .continuous
        detailsView.translatesAutoresizingMaskIntoConstraints = false
        detailsView.accessibilityLabel = "Details"
        detailsBox.addSubview(detailsView)
        NSLayoutConstraint.activate([
            detailsView.leadingAnchor.constraint(equalTo: detailsBox.leadingAnchor, constant: 12),
            detailsView.trailingAnchor.constraint(equalTo: detailsBox.trailingAnchor, constant: -12),
            detailsView.topAnchor.constraint(equalTo: detailsBox.topAnchor, constant: 10),
            detailsView.bottomAnchor.constraint(equalTo: detailsBox.bottomAnchor, constant: -10),
        ])
        stack.axis = .vertical
        stack.spacing = 4
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(detailsBox)
        pin(stack)
        header.addAction(UIAction { [weak self] _ in
            guard let self, let id else { return }
            toggle?(id)
        }, for: .primaryActionTriggered)
    }

    func configure(_ message: ChatMessage, context: TranscriptCellContext) {
        text = message.text
        id = message.id
        toggle = context.toggle
        let tool = ToolCallPresentation(text: message.text)
        isExpanded = context.isExpanded(message.id)
        header.show(tool, expanded: isExpanded, hasDetails: !tool.details.isEmpty, traits: context.renderer.traits)
        detailsBox.isHidden = !isExpanded || tool.details.isEmpty
        if !detailsBox.isHidden {
            let font = context.renderer.monospaced(12.5, for: .footnote)
            let bold = context.renderer.monospaced(12.5, for: .footnote, weight: .semibold)
            detailsView.setText(ToolCallPresentation.styledDetails(tool.details, font: font, boldFont: bold))
        }
        header.accessibilityCustomActions = [Self.copyAction { [weak self] in self?.text ?? "" }]
        setNeedsLayout()
    }

    override func prepare(width: CGFloat) {
        if !detailsBox.isHidden { detailsView.prepare(width: width - 24) }
    }
}

/// The tappable row of a tool call. Its whole width is the target. At accessibility text
/// sizes the title moves under the symbol and status and wraps, as a list cell's does.
final class ToolCallHeader: UIControl {
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let spacer = UIView()
    private let firstRow = UIStackView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbol.tintColor = .secondaryLabel
        symbol.contentMode = .center
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.textColor = .secondaryLabel
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        firstRow.spacing = 8
        firstRow.alignment = .center
        stack.spacing = 8
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            symbol.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var stacked: Bool?

    /// One row, or at accessibility sizes the symbol and status, with the chevron at the
    /// end, over the title.
    private func arrange(stacked: Bool) {
        guard stacked != self.stacked else { return }
        self.stacked = stacked
        (stack.arrangedSubviews + firstRow.arrangedSubviews).forEach { $0.removeFromSuperview() }
        if stacked {
            [symbol, statusLabel, spacer, chevron].forEach(firstRow.addArrangedSubview)
            stack.axis = .vertical
            stack.alignment = .fill
            stack.spacing = 4
            [firstRow, titleLabel].forEach(stack.addArrangedSubview)
            titleLabel.numberOfLines = 4
        } else {
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            [symbol, titleLabel, statusLabel, chevron].forEach(stack.addArrangedSubview)
            stack.setCustomSpacing(10, after: symbol)
            titleLabel.numberOfLines = 1
        }
        titleLabel.lineBreakMode = .byTruncatingMiddle
    }

    func show(_ tool: ToolCallPresentation, expanded: Bool, hasDetails: Bool, traits: UITraitCollection) {
        arrange(stacked: traits.preferredContentSizeCategory.isAccessibilityCategory)
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        symbol.image = UIImage(systemName: tool.symbolName)
        symbol.preferredSymbolConfiguration = .init(font: font)
        // A command is set in monospace, as the Mac sets it, without the backticks around it.
        titleLabel.font = tool.isCommand
            ? UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular),
                                                                    compatibleWith: traits)
            : font
        titleLabel.text = tool.displayTitle
        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        statusLabel.text = tool.statusText
        statusLabel.textColor = tool.statusColor
        statusLabel.isHidden = tool.statusText.isEmpty
        chevron.preferredSymbolConfiguration = .init(font: UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits),
                                                     scale: .medium)
        // Kept in place when there is nothing to show, so every status lines up.
        chevron.alpha = hasDetails ? 1 : 0
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        isEnabled = hasDetails
        accessibilityLabel = "Tool: \(tool.displayTitle)" + (tool.statusText.isEmpty ? "" : ", \(tool.statusText)")
        accessibilityHint = hasDetails ? (expanded ? "Hides the details." : "Shows the details.") : nil
        accessibilityValue = hasDetails ? (expanded ? "Expanded" : "Collapsed") : nil
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }
}

/// A line of Latch's own in the conversation, set apart in small italics.
final class NoticeCell: TranscriptCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        pin(label)
        isAccessibilityElement = true
    }

    func configure(_ message: ChatMessage, context: TranscriptCellContext) {
        let text = String(message.text.dropFirst().dropLast())
        let base = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: context.renderer.traits)
        label.font = base.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: 0) } ?? base
        label.text = text
        accessibilityLabel = text
    }
}

/// While a turn runs: a quiet line under the conversation. It never announces itself, so
/// VoiceOver is not interrupted as the reply streams.
final class WorkingCell: TranscriptCell {
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        // A larger spinner beside accessibility-sized text.
        spinner.style = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .large : .medium
    }

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.text = "Working…"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.spacing = 8
        row.alignment = .center
        pin(row, trailing: false)
        spinner.startAnimating()
        isAccessibilityElement = true
        accessibilityLabel = "Working"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.startAnimating()
    }
}
