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
    /// The pictures kept for a prompt's attachments, in order; nil where there is none.
    var thumbnails: (UUID) -> [UIImage?] = { _ in [] }
    /// Where a row sits among subagents, and what happened under it.
    var row: (UUID) -> TranscriptRowInfo = { _ in TranscriptRowInfo() }
}

/// A transcript row: no background, no selection, content running the readable width. A row
/// under a subagent's is indented a step for each subagent above it, with a thin line down
/// each step, so a run of them reads as one branch.
class TranscriptCell: UICollectionViewListCell {
    /// Space above and below the content, so tool calls in a row sit together as one burst.
    var verticalInsets: (top: CGFloat, bottom: CGFloat) { (8, 8) }
    private(set) var topConstraint: NSLayoutConstraint?
    private(set) var bottomConstraint: NSLayoutConstraint?
    private var leadingConstraint: NSLayoutConstraint?
    /// One step of nesting under a subagent.
    static let indentWidth: CGFloat = 16
    /// How far the content is indented.
    private(set) var indent: CGFloat = 0
    private let guides = IndentGuidesView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        accessibilityRespondsToUserInteraction = true
        guides.frame = contentView.bounds
        guides.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(guides)
    }

    /// Indents the content for `depth` subagents above it.
    func setDepth(_ depth: Int) {
        guides.depth = depth
        let indent = CGFloat(depth) * Self.indentWidth
        guard indent != self.indent else { return }
        self.indent = indent
        leadingConstraint?.constant = indent
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Text views that Select Text makes selectable, in reading order.
    var textViews: [TranscriptTextView] { [] }

    /// Select Text: the text nearest `point`, in the cell's coordinates, becomes selectable
    /// and wholly selected. Every other text view in the cell becomes selectable too, so a
    /// selection can be started again in any of them.
    func beginSelecting(near point: CGPoint) {
        let views = textViews.filter { !$0.isHidden && $0.window != nil }
        guard !views.isEmpty else { return }
        let nearest = views.min { distance($0, point) < distance($1, point) } ?? views[0]
        views.forEach { $0.isSelectable = true }
        nearest.beginSelecting()
    }

    private func distance(_ view: UIView, _ point: CGPoint) -> CGFloat {
        let frame = view.convert(view.bounds, to: self)
        if frame.contains(point) { return 0 }
        return abs(frame.midY - point.y)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textViews.forEach { $0.endSelecting() }
    }

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
        if leading {
            let constraint = view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: indent)
            constraint.isActive = true
            leadingConstraint = constraint
        }
        if trailing { view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor).isActive = true }
        topConstraint = top
        bottomConstraint = bottom
    }

    /// Called with the width the layout gives the content, past its indent, before the cell
    /// measures its height.
    func prepare(width: CGFloat) {}

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes {
        prepare(width: layoutAttributes.size.width - indent)
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    static func copyAction(_ name: String = "Copy", _ text: @escaping () -> String) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name, image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = text()
            return true
        }
    }
}

/// The thin lines down a nested row's indent, one for each subagent above it. Each runs the
/// row's full height, so the rows of one subagent join into one line.
final class IndentGuidesView: UIView {
    var depth = 0 {
        didSet {
            guard depth != oldValue else { return }
            while lines.count < depth {
                let line = UIView()
                line.backgroundColor = .separator
                addSubview(line)
                lines.append(line)
            }
            for (level, line) in lines.enumerated() { line.isHidden = level >= depth }
            setNeedsLayout()
        }
    }
    private var lines: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (level, line) in lines.enumerated() {
            // A point wide, in the middle of its step of the indent.
            let x = CGFloat(level) * TranscriptCell.indentWidth + TranscriptCell.indentWidth / 2 - 0.5
            line.frame = CGRect(x: x, y: 0, width: 1, height: bounds.height)
        }
    }
}

/// The user's prompt: a bubble in the tint's soft tone at the trailing edge, as wide as its
/// text up to four fifths of the row (and never wider than a phone's). Photos sent from this
/// device sit above it as pictures, as in Messages; any other attachment, or a photo whose
/// picture is not kept here, is listed by name inside it.
final class UserMessageCell: TranscriptCell {
    let bubble = UIView()
    private let column = UIStackView()
    private let pictures = UIStackView()
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
        pictures.axis = .horizontal
        pictures.spacing = 4
        column.axis = .vertical
        column.alignment = .trailing
        column.spacing = 4
        column.addArrangedSubview(pictures)
        column.addArrangedSubview(bubble)
        pin(column, leading: false)
        column.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 40).isActive = true
        isAccessibilityElement = true
    }

    override var textViews: [TranscriptTextView] { [textView] }

    /// A photo's side, square as in Messages.
    static let pictureSide: CGFloat = 64
    /// The most pictures in the row; any more are counted in a last tile.
    static let maximumPictures = 4

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
        pictures.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let kept = context.thumbnails(message.id)
        var shown: [UIImage] = []
        for (index, attachment) in message.attachments.enumerated() {
            if attachment.kind == .image, index < kept.count, let picture = kept[index] {
                shown.append(picture)
            } else {
                chips.addArrangedSubview(AttachmentChip(attachment, renderer: context.renderer))
            }
        }
        for picture in shown.prefix(shown.count > Self.maximumPictures ? Self.maximumPictures - 1 : Self.maximumPictures) {
            pictures.addArrangedSubview(Self.tile(image: picture, extra: nil))
        }
        if shown.count > Self.maximumPictures {
            pictures.addArrangedSubview(Self.tile(image: shown[Self.maximumPictures - 1],
                                                  extra: shown.count - Self.maximumPictures + 1))
        }
        pictures.isHidden = shown.isEmpty
        chips.isHidden = chips.arrangedSubviews.isEmpty
        // Photos alone need no empty bubble under them.
        bubble.isHidden = textView.isHidden && chips.isHidden
        let names = message.attachments.map(\.name)
        accessibilityLabel = "You: " + ([message.text] + (names.isEmpty ? [] : ["Attached: " + names.joined(separator: ", ")]))
            .filter { !$0.isEmpty }.joined(separator: ". ")
        accessibilityCustomActions = [Self.copyAction { [weak self] in self?.text ?? "" }]
        setNeedsLayout()
    }

    /// A picture in the row: square, filled, on the content panels' 12 point corners. The
    /// last one may carry how many more there are.
    private static func tile(image: UIImage, extra: Int?) -> UIView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.accessibilityIgnoresInvertColors = true
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: pictureSide),
            view.heightAnchor.constraint(equalToConstant: pictureSide),
        ])
        if let extra {
            let dim = UILabel()
            dim.text = "+\(extra)"
            dim.font = ChromeFont.preferred(.headline, weight: .semibold)
            dim.textColor = .white
            dim.textAlignment = .center
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            dim.frame = CGRect(x: 0, y: 0, width: pictureSide, height: pictureSide)
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(dim)
        }
        return view
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

/// The agent's reply: Markdown across the full width.
final class AssistantMessageCell: TranscriptCell {
    let markdown = MarkdownContentView()
    private(set) var text = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        pin(markdown)
        isAccessibilityElement = true
    }

    func configure(_ message: ChatMessage, context: TranscriptCellContext) {
        text = message.text
        agentTitle = context.agentTitle
        setDepth(context.row(message.id).depth)
        let blocks = context.cache.blocks(for: message.id, text: message.text, traits: context.renderer.traits)
        markdown.show(blocks, renderer: context.renderer)
        setNeedsLayout()
    }

    private var agentTitle = ""

    override var textViews: [TranscriptTextView] { markdown.textViews }

    // Worked out when VoiceOver asks, not on every streamed frame.
    override var accessibilityLabel: String? {
        get { "\(agentTitle): \(markdown.spokenText)" }
        set {}
    }

    /// The same words, with code read out symbol by symbol: in a command, `~/` and `&&` matter.
    override var accessibilityAttributedLabel: NSAttributedString? {
        get {
            let label = NSMutableAttributedString(string: "\(agentTitle): ")
            label.append(markdown.spokenAttributedText)
            return label
        }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            var actions = [Self.copyAction { [weak self] in self?.markdown.plainText ?? "" },
                           Self.copyAction("Copy as Markdown") { [weak self] in self?.text ?? "" }]
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
        markdown.prepare(width: layoutAttributes.size.width - indent)
        let fitted = layoutAttributes.copy() as? UICollectionViewLayoutAttributes ?? layoutAttributes
        let insets = verticalInsets
        fitted.size.height = markdown.preparedHeight + insets.top + insets.bottom
        return fitted
    }
}

/// A row that folds away what it holds behind a header: a tool call, a subagent, a thought.
@MainActor
protocol DisclosureCell: TranscriptCell {
    var header: ToolCallHeader { get }
    var isExpanded: Bool { get }
}

/// A tool call: one compact row with its symbol, title and status, which expands to the
/// details in monospace. A subagent's row also counts the steps under it, names the latest
/// while it runs, and expanding it shows those rows too, under it.
final class ToolCallCell: TranscriptCell, DisclosureCell {
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
        detailsBox.layer.cornerRadius = 12
        detailsBox.layer.cornerCurve = .continuous
        registerForTraitChanges([UITraitAccessibilityContrast.self]) { (cell: ToolCallCell, _) in cell.updateBorder() }
        updateBorder()
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

    /// A hairline round the details with Increase Contrast, where the panel alone is faint.
    private func updateBorder() {
        let high = traitCollection.accessibilityContrast == .high
        detailsBox.layer.borderWidth = high ? 1 : 0
        detailsBox.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    override var textViews: [TranscriptTextView] { detailsBox.isHidden ? [] : [detailsView] }

    private(set) var tool = ToolCallPresentation(text: "")

    func configure(_ message: ChatMessage, context: TranscriptCellContext) {
        text = message.text
        id = message.id
        toggle = context.toggle
        let tool = ToolCallPresentation(message)
        self.tool = tool
        let row = context.row(message.id)
        setDepth(row.depth)
        isExpanded = context.isExpanded(message.id)
        header.show(tool, expanded: isExpanded, hasDetails: !tool.details.isEmpty, traits: context.renderer.traits, row: row)
        detailsBox.isHidden = !isExpanded || tool.details.isEmpty
        if !detailsBox.isHidden {
            let font = context.renderer.monospaced(12.5, for: .footnote)
            let bold = context.renderer.monospaced(12.5, for: .footnote, weight: .semibold)
            let details = NSMutableAttributedString(attributedString: ToolCallPresentation.styledDetails(
                tool.details, font: font, boldFont: bold))
            // Read symbol by symbol, as code is.
            details.addAttribute(.accessibilitySpeechPunctuation, value: true, range: NSRange(location: 0, length: details.length))
            detailsView.setText(details)
        }
        header.accessibilityCustomActions = [Self.copyAction { [weak self] in self?.text ?? "" }]
        setNeedsLayout()
    }

    override func prepare(width: CGFloat) {
        if !detailsBox.isHidden { detailsView.prepare(width: width - 24) }
    }
}

/// What the agent thought on the way, folded to one line: "Thinking" and its first words.
/// Open, the whole thought follows in the secondary colour as plain text, under the title.
final class ThoughtCell: TranscriptCell, DisclosureCell {
    override var verticalInsets: (top: CGFloat, bottom: CGFloat) { (0, 2) }
    let header = ToolCallHeader()
    let textView = TranscriptTextView()
    private let textBox = UIView()
    private lazy var textLeading = textView.leadingAnchor.constraint(equalTo: textBox.leadingAnchor)
    private let stack = UIStackView()
    private(set) var text = ""
    private var id: UUID?
    private var toggle: ((UUID) -> Void)?
    private(set) var isExpanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textBox.addSubview(textView)
        NSLayoutConstraint.activate([
            textLeading,
            textView.trailingAnchor.constraint(equalTo: textBox.trailingAnchor),
            textView.topAnchor.constraint(equalTo: textBox.topAnchor),
            textView.bottomAnchor.constraint(equalTo: textBox.bottomAnchor, constant: -8),
        ])
        stack.axis = .vertical
        stack.spacing = 0
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(textBox)
        pin(stack)
        header.addAction(UIAction { [weak self] _ in
            guard let self, let id else { return }
            toggle?(id)
        }, for: .primaryActionTriggered)
    }

    override var textViews: [TranscriptTextView] { textBox.isHidden ? [] : [textView] }

    func configure(_ message: ChatMessage, context: TranscriptCellContext) {
        text = message.text
        id = message.id
        toggle = context.toggle
        setDepth(context.row(message.id).depth)
        isExpanded = context.isExpanded(message.id)
        let traits = context.renderer.traits
        header.showThought(ThoughtPresentation.preview(message.text), expanded: isExpanded, traits: traits)
        textBox.isHidden = !isExpanded
        if isExpanded {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            textView.setText(NSAttributedString(string: message.text.trimmingCharacters(in: .whitespacesAndNewlines), attributes: [
                .font: UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits),
                .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: paragraph,
            ]))
        }
        // Under the title, past the symbol.
        textLeading.constant = header.titleInset
        header.accessibilityCustomActions = [Self.copyAction { [weak self] in self?.text ?? "" }]
        setNeedsLayout()
    }

    override func prepare(width: CGFloat) {
        if !textBox.isHidden { textView.prepare(width: width - textLeading.constant) }
    }
}

/// The tappable row of a tool call, a subagent or a thought. Its whole width is the target.
/// At accessibility text sizes the status and chevron move under the symbol and title, which
/// wraps, as a list cell's does. While the tool runs its symbol is faint and its status says
/// so: "Working…" under the conversation already spins, and one spinner on screen is enough.
final class ToolCallHeader: UIControl {
    private let symbol = UIImageView()
    private let symbolColumn = UIView()
    private var symbolWidth: NSLayoutConstraint?
    private let titleLabel = UILabel()
    /// A second line under the title: the step a subagent is on.
    private let subtitleLabel = UILabel()
    private let titleColumn = UIStackView()
    private let statusLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let spacer = UIView()
    private let firstRow = UIStackView()
    private let stack = UIStackView()

    /// What a header shows, and how VoiceOver reads it.
    private struct Content {
        var symbol: String
        var title: String
        /// After the title, quieter, on the same line.
        var preview = ""
        var isCommand = false
        /// Words, such as a subagent's task, which are cut at their end rather than their middle.
        var isProse = false
        var status = ""
        var statusColor = UIColor.secondaryLabel
        var subtitle: String?
        var isRunning = false
        var canExpand: Bool
        /// The label VoiceOver reads; a command in it symbol by symbol.
        var spoken: NSAttributedString
        var spokenValue: String?
        var hint: (show: String, hide: String)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbol.tintColor = .secondaryLabel
        symbol.contentMode = .center
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbolColumn.addSubview(symbol)
        let width = symbolColumn.widthAnchor.constraint(equalToConstant: 22)
        symbolWidth = width
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: symbolColumn.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: symbolColumn.centerYAnchor),
            width,
            symbolColumn.heightAnchor.constraint(greaterThanOrEqualTo: symbol.heightAnchor),
        ])
        symbolColumn.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.textColor = .secondaryLabel
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleColumn.axis = .vertical
        titleColumn.spacing = 1
        titleColumn.addArrangedSubview(titleLabel)
        titleColumn.addArrangedSubview(subtitleLabel)
        titleColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var stacked: Bool?
    private weak var secondRow: UIStackView?

    /// Where the title starts, past the symbol's column.
    var titleInset: CGFloat { (symbolWidth?.constant ?? 22) + (stacked == true ? 8 : 10) }

    /// One row, or at accessibility sizes the symbol and title, which wraps, over the status
    /// with the chevron at the end, so the row reads in the order it is spoken.
    private func arrange(stacked: Bool) {
        guard stacked != self.stacked else { return }
        self.stacked = stacked
        (stack.arrangedSubviews + firstRow.arrangedSubviews).forEach { $0.removeFromSuperview() }
        if stacked {
            firstRow.alignment = .firstBaseline
            [symbolColumn, titleColumn].forEach(firstRow.addArrangedSubview)
            let secondRow = UIStackView(arrangedSubviews: [statusLabel, spacer, chevron])
            secondRow.spacing = 8
            secondRow.alignment = .center
            secondRow.isLayoutMarginsRelativeArrangement = true
            secondRow.directionalLayoutMargins = .init(top: 0, leading: (symbolWidth?.constant ?? 22) + 8,
                                                       bottom: 0, trailing: 0)
            self.secondRow = secondRow
            stack.axis = .vertical
            stack.alignment = .fill
            stack.spacing = 4
            [firstRow, secondRow].forEach(stack.addArrangedSubview)
            titleLabel.numberOfLines = 4
            subtitleLabel.numberOfLines = 3
            // "4 steps · Running" wraps rather than be cut short.
            statusLabel.numberOfLines = 2
            statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        } else {
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            [symbolColumn, titleColumn, statusLabel, chevron].forEach(stack.addArrangedSubview)
            stack.setCustomSpacing(10, after: symbolColumn)
            titleLabel.numberOfLines = 1
            subtitleLabel.numberOfLines = 1
            statusLabel.numberOfLines = 1
            statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
    }

    /// A tool call. With `row`, a subagent's: how many steps are under it and, while it runs,
    /// the latest of them.
    func show(_ tool: ToolCallPresentation, expanded: Bool, hasDetails: Bool, traits: UITraitCollection,
              row: TranscriptRowInfo = TranscriptRowInfo()) {
        let steps = row.steps == 0 ? nil : row.steps == 1 ? "1 step" : "\(row.steps) steps"
        let status = [steps, tool.statusText].compactMap { $0 }.filter { !$0.isEmpty }
        let live = tool.state == .running || tool.state == .pending
        let subtitle = (tool.runsSubagent || row.hasChildren) && live ? row.latestStep : nil
        let spoken = NSMutableAttributedString(string: tool.runsSubagent ? "Subagent: " : "Tool: ")
        spoken.append(NSAttributedString(string: tool.displayTitle,
                                          attributes: tool.isCommand ? [.accessibilitySpeechPunctuation: true] : [:]))
        if !status.isEmpty { spoken.append(NSAttributedString(string: ", " + status.joined(separator: ", "))) }
        show(Content(symbol: tool.symbolName, title: tool.displayTitle, isCommand: tool.isCommand, isProse: tool.runsSubagent,
                     status: status.joined(separator: " · "), statusColor: tool.statusColor, subtitle: subtitle,
                     isRunning: tool.state == .running, canExpand: hasDetails || row.hasChildren, spoken: spoken,
                     spokenValue: subtitle.map { "Latest step: \($0)" }, hint: Self.hint(details: hasDetails, steps: row.hasChildren)),
             expanded: expanded, traits: traits)
    }

    private static func hint(details: Bool, steps: Bool) -> (show: String, hide: String) {
        switch (details, steps) {
        case (true, true): ("Shows its details and steps.", "Hides its details and steps.")
        case (false, true): ("Shows its steps.", "Hides its steps.")
        default: ("Shows the details.", "Hides the details.")
        }
    }

    /// A thought: "Thinking", and the start of it.
    func showThought(_ preview: String, expanded: Bool, traits: UITraitCollection) {
        show(Content(symbol: "brain", title: "Thinking", preview: preview, canExpand: true,
                     spoken: NSAttributedString(string: "Thinking"), spokenValue: preview.isEmpty ? nil : preview,
                     hint: ("Shows the whole thought.", "Hides the thought.")),
             expanded: expanded, traits: traits)
    }

    private func show(_ content: Content, expanded: Bool, traits: UITraitCollection) {
        arrange(stacked: traits.preferredContentSizeCategory.isAccessibilityCategory)
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        symbol.image = UIImage(systemName: content.symbol)
        symbol.preferredSymbolConfiguration = .init(font: font)
        // The column grows with the symbol, so a large one never runs into the title.
        let column = UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 22, compatibleWith: traits).rounded()
        symbolWidth?.constant = column
        secondRow?.directionalLayoutMargins.leading = column + 8
        // A command is set in monospace, as the Mac sets it, without the backticks around it.
        let titleFont = content.isCommand
            ? UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular),
                                                                    compatibleWith: traits)
            : font
        // Never hyphenated: a file name or a command broken at a hyphen reads as two words.
        // Wrapped, a path or command breaks between words or where a path or option would
        // have one, never mid-name. VoiceOver reads the title as it is.
        let paragraph = NSMutableParagraphStyle()
        paragraph.hyphenationFactor = 0
        paragraph.usesDefaultHyphenation = false
        paragraph.lineBreakMode = stacked == true ? .byWordWrapping
            : content.preview.isEmpty && !content.isProse ? .byTruncatingMiddle : .byTruncatingTail
        let shown = stacked == true ? Self.breakable(content.title, command: content.isCommand) : content.title
        let title = NSMutableAttributedString(string: shown, attributes: [
            .font: titleFont, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: paragraph,
        ])
        if !content.preview.isEmpty {
            title.append(NSAttributedString(string: "  " + content.preview, attributes: [
                .font: titleFont, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: paragraph,
            ]))
        }
        titleLabel.font = titleFont
        titleLabel.attributedText = title
        titleLabel.lineBreakMode = paragraph.lineBreakMode
        // The latest step's title, which breaks as a title does.
        let step = NSMutableParagraphStyle()
        step.hyphenationFactor = 0
        step.usesDefaultHyphenation = false
        step.lineBreakMode = stacked == true ? .byWordWrapping : .byTruncatingMiddle
        let subtitle = content.subtitle ?? ""
        subtitleLabel.attributedText = NSAttributedString(
            string: stacked == true ? Self.breakable(subtitle, command: false) : subtitle,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
                         .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: step])
        subtitleLabel.lineBreakMode = step.lineBreakMode
        subtitleLabel.isHidden = subtitle.isEmpty
        symbol.alpha = content.isRunning ? 0.5 : 1
        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        statusLabel.text = content.status
        statusLabel.textColor = content.statusColor
        statusLabel.isHidden = content.status.isEmpty
        chevron.preferredSymbolConfiguration = .init(font: UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits),
                                                     scale: .medium)
        // Kept in place when there is nothing to show, so every status lines up.
        chevron.alpha = content.canExpand ? 1 : 0
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        isEnabled = content.canExpand
        // A command is read symbol by symbol: `rm -rf ~/` and `rm -rf .` differ by one.
        var punctuated = false
        content.spoken.enumerateAttribute(.accessibilitySpeechPunctuation, in: NSRange(location: 0, length: content.spoken.length)) {
            value, _, _ in if value != nil { punctuated = true }
        }
        if punctuated {
            accessibilityAttributedLabel = content.spoken
        } else {
            accessibilityAttributedLabel = nil
            accessibilityLabel = content.spoken.string
        }
        accessibilityValue = content.spokenValue
        // Only a row with something to show is a control; one without is a line of text.
        accessibilityTraits = content.canExpand ? .button : .staticText
        accessibilityHint = content.canExpand ? (expanded ? content.hint.hide : content.hint.show) : nil
        accessibilityExpandedStatus = content.canExpand ? (expanded ? .expanded : .collapsed) : .unsupported
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }

    /// `text` with a zero-width space where a line may break inside a word: after a slash, an
    /// underscore or a dot, before a run of hyphens, and in a command after an equals sign. A
    /// name still too long for a line may break where a lower-case letter meets a capital. No
    /// line breaks after a hyphen, which would leave `--` at the end of one line.
    static func breakable(_ text: String, command: Bool) -> String {
        let zeroWidthSpace: Character = "\u{200B}"
        var result = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if !result.isEmpty { result.append(" ") }
            var previous: Character?
            var run = 0
            for character in word {
                if character == "-", let previous, previous != "-" { result.append(zeroWidthSpace) }
                if character.isUppercase, previous?.isLowercase == true, run >= 8 {
                    result.append(zeroWidthSpace)
                    run = 0
                }
                result.append(character)
                run += 1
                if character == "-" {
                    result.append("\u{2060}")
                } else if character == "/" || character == "_" || character == "." || (command && character == "=") {
                    result.append(zeroWidthSpace)
                    run = 0
                }
                previous = character
            }
        }
        return result
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

/// While a turn runs: a quiet line under the conversation, "Stopping…" once Stop is chosen
/// and until the agent ends the turn. It never announces itself, so VoiceOver is not
/// interrupted as the reply streams.
final class WorkingCell: TranscriptCell {
    func configure(stopping: Bool) {
        label.text = stopping ? "Stopping…" : "Working…"
        accessibilityLabel = stopping ? "Stopping" : "Working"
    }

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
