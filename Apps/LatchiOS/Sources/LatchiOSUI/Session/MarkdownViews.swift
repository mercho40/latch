import UIKit

/// A rendered reply: its blocks one above the other. Streaming reuses the views already
/// there, so a growing answer only resets the block that changed, and only that block is
/// measured again. The blocks are placed by hand rather than by a stack view: a long reply has
/// hundreds of blocks, and solving a stack of them took some 200 ms a frame.
final class MarkdownContentView: UIView {
    private(set) var blocks: [MarkdownBlock] = []
    private(set) var blockViews: [UIView & MarkdownBlockView] = []
    private var heights: [CGFloat] = []
    /// Blocks whose height is not yet known for `measuredWidth`.
    private var unmeasured = IndexSet()
    private var measuredWidth: CGFloat = -1
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    static let spacing: CGFloat = 12

    init() {
        super.init(frame: .zero)
        // Below required, so the estimated size a cell starts at never conflicts with it.
        height.priority = .required - 1
        height.isActive = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ blocks: [MarkdownBlock], renderer: MarkdownRenderer) {
        guard blocks != self.blocks || blockViews.count != blocks.count else { return }
        for (index, block) in blocks.enumerated() {
            let existing = index < blockViews.count ? blockViews[index] : nil
            if index < self.blocks.count, self.blocks[index] == block, existing != nil { continue }
            unmeasured.insert(index)
            if let existing, existing.accepts(block) {
                existing.show(block, renderer: renderer)
                continue
            }
            let view = Self.makeView(for: block)
            view.show(block, renderer: renderer)
            if let existing {
                existing.removeFromSuperview()
                blockViews[index] = view
            } else {
                blockViews.append(view)
            }
            addSubview(view)
        }
        while blockViews.count > blocks.count {
            blockViews.removeLast().removeFromSuperview()
        }
        heights = Array(heights.prefix(blocks.count)) + Array(repeating: 0, count: max(0, blocks.count - heights.count))
        unmeasured = unmeasured.filteredIndexSet { $0 < blocks.count }
        self.blocks = blocks
        setNeedsLayout()
    }

    /// Space after block `index`: more above a heading than below it, so a heading reads
    /// with the text it introduces.
    private func spacing(after index: Int) -> CGFloat {
        func heading(_ block: MarkdownBlock, atEnd: Bool) -> Bool {
            guard case let .text(text) = block, text.length > 0 else { return false }
            return text.attribute(.markdownHeading, at: atEnd ? text.length - 1 : 0, effectiveRange: nil) != nil
        }
        if heading(blocks[index + 1], atEnd: false) { return 20 }
        return heading(blocks[index], atEnd: true) ? 6 : Self.spacing
    }

    /// Measures what changed for `width` and fixes the reply's height. A self-sizing cell
    /// calls this with the width it is given, before it measures itself.
    func prepare(width: CGFloat) {
        guard width > 0 else { return }
        if width != measuredWidth {
            measuredWidth = width
            unmeasured = IndexSet(blockViews.indices)
        }
        for index in unmeasured {
            heights[index] = ceil(blockViews[index].height(forWidth: width))
        }
        unmeasured = []
        var total: CGFloat = 0
        for index in heights.indices {
            total += heights[index] + (index + 1 < heights.count ? spacing(after: index) : 0)
        }
        if height.constant != total { height.constant = total }
    }

    /// The height `prepare(width:)` fixed.
    var preparedHeight: CGFloat { height.constant }

    override func layoutSubviews() {
        super.layoutSubviews()
        prepare(width: bounds.width)
        var y: CGFloat = 0
        for (index, view) in blockViews.enumerated() {
            let frame = CGRect(x: 0, y: y, width: bounds.width, height: heights[index])
            if view.frame != frame { view.frame = frame }
            y += heights[index] + (index + 1 < blockViews.count ? spacing(after: index) : 0)
        }
    }

    /// The reply's text as VoiceOver reads it.
    var spokenText: String {
        blocks.map { block in
            switch block {
            case let .text(text), let .quote(text): text.string.replacingOccurrences(of: "\u{2028}", with: "\n")
            case let .code(language, code): "\(language.map { "\($0) code" } ?? "Code"): \(code)"
            case let .table(table):
                ([table.header] + table.rows).map { $0.map(\.string).joined(separator: ", ") }.joined(separator: ". ")
            case .rule: ""
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The links a reply offers, for VoiceOver's actions: in prose, quotes and table cells.
    var links: [(title: String, url: URL)] {
        var result: [(String, URL)] = []
        func collect(_ text: NSAttributedString) {
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let url = value as? URL { result.append(((text.string as NSString).substring(with: range), url)) }
            }
        }
        for block in blocks {
            switch block {
            case let .text(text), let .quote(text): collect(text)
            case let .table(table): ([table.header] + table.rows).joined().forEach(collect)
            case .code, .rule: break
            }
        }
        return result
    }

    /// The reply's code blocks, each of which VoiceOver can copy on its own.
    var codeBlocks: [(language: String?, code: String)] {
        blocks.compactMap { if case let .code(language, code) = $0 { (language, code) } else { nil } }
    }

    private static func makeView(for block: MarkdownBlock) -> UIView & MarkdownBlockView {
        switch block {
        case .text: MarkdownTextBlockView()
        case .quote: QuoteBlockView()
        case .code: CodeBlockView()
        case .table: TableBlockView()
        case .rule: RuleBlockView()
        }
    }
}

@MainActor
protocol MarkdownBlockView: AnyObject {
    func accepts(_ block: MarkdownBlock) -> Bool
    func show(_ block: MarkdownBlock, renderer: MarkdownRenderer)
    /// The block's height at `width`, for the reply to place it.
    func height(forWidth width: CGFloat) -> CGFloat
}

extension MarkdownBlockView where Self: UIView {
    func height(forWidth width: CGFloat) -> CGFloat {
        systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }
}

/// Selectable, non-editable text that sizes to its content and opens only the links the
/// renderer allowed. Data detectors stay off: nothing in a reply becomes a link by guessing.
/// Links are underlined when Differentiate Without Color is on, and inline code is drawn on
/// a rounded panel.
final class TranscriptTextView: UITextView, UITextViewDelegate, NSTextLayoutManagerDelegate {
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    private var preparedWidth: CGFloat = -1

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        dataDetectorTypes = []
        adjustsFontForContentSizeCategory = false
        updateLinkStyle()
        delegate = self
        textLayoutManager?.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(updateLinkStyle),
                                               name: UIAccessibility.differentiateWithoutColorDidChangeNotification, object: nil)
        setContentCompressionResistancePriority(.required, for: .vertical)
        height.priority = .required - 1
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setText(_ text: NSAttributedString) {
        guard !attributedText.isEqual(to: text) else { return }
        attributedText = text
        preparedWidth = -1
        invalidateIntrinsicContentSize()
    }

    func prepare(width: CGFloat) {
        guard width > 0, width != preparedWidth else { return }
        preparedWidth = width
        height.constant = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    /// The height `prepare(width:)` fixed.
    var preparedHeight: CGFloat { height.constant }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        return MarkdownRenderer.isAllowed(url) ? defaultAction : nil
    }

    @objc private func updateLinkStyle() {
        let underline: NSUnderlineStyle = UIAccessibility.shouldDifferentiateWithoutColor ? .single : []
        linkTextAttributes = [.foregroundColor: LatchPalette.tint, .underlineStyle: underline.rawValue]
    }

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        guard let paragraph = textElement as? NSTextParagraph,
              InlineCodeLayoutFragment.hasInlineCode(paragraph.attributedString) else {
            return NSTextLayoutFragment(textElement: textElement, range: range)
        }
        return InlineCodeLayoutFragment(textElement: textElement, range: range)
    }
}

/// A paragraph with inline code: each code run on a rounded panel a little wider than its
/// text, the way Notes sets off a monospaced run, then the text over it.
final class InlineCodeLayoutFragment: NSTextLayoutFragment {
    private static let outset = CGSize(width: 3, height: 1)

    static func hasInlineCode(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.inlineCodeBackground, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.insetBy(dx: -Self.outset.width - 1, dy: -Self.outset.height - 1)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        for line in textLineFragments {
            let text = line.attributedString
            let bounds = line.typographicBounds
            let lineRange = NSIntersectionRange(line.characterRange, NSRange(location: 0, length: text.length))
            text.enumerateAttribute(.inlineCodeBackground, in: lineRange) { value, range, _ in
                guard let color = value as? UIColor, range.length > 0 else { return }
                let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
                    ?? .preferredFont(forTextStyle: .body)
                // Trailing spaces at a wrap have no panel.
                var end = NSMaxRange(range)
                let string = text.string as NSString
                while end > range.location, string.character(at: end - 1) == 0x20 { end -= 1 }
                guard end > range.location else { return }
                let startX = line.locationForCharacter(at: range.location).x
                let endX = line.locationForCharacter(at: end).x
                let baseline = bounds.minY + line.glyphOrigin.y
                let rect = CGRect(x: point.x + bounds.minX + startX - Self.outset.width,
                                  y: point.y + baseline - font.ascender - Self.outset.height,
                                  width: endX - startX + Self.outset.width * 2,
                                  height: font.ascender - font.descender + Self.outset.height * 2)
                context.setFillColor(color.resolvedColor(with: UITraitCollection.current).cgColor)
                let radius = min(5, rect.height / 3)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }
        super.draw(at: point, in: context)
    }
}

final class MarkdownTextBlockView: UIView, MarkdownBlockView {
    let textView = TranscriptTextView()

    init() {
        super.init(frame: .zero)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func accepts(_ block: MarkdownBlock) -> Bool {
        if case .text = block { true } else { false }
    }

    func show(_ block: MarkdownBlock, renderer: MarkdownRenderer) {
        guard case let .text(text) = block else { return }
        textView.setText(text)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        textView.prepare(width: width)
        return textView.preparedHeight
    }
}

/// A block quote: its text beside a rounded bar, the way Mail sets off quoted text.
final class QuoteBlockView: UIView, MarkdownBlockView {
    private let bar = UIView()
    let textView = TranscriptTextView()
    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 12

    init() {
        super.init(frame: .zero)
        bar.backgroundColor = .tertiaryLabel
        bar.layer.cornerRadius = Self.barWidth / 2
        bar.layer.cornerCurve = .continuous
        for view in [bar, textView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: Self.barWidth),
            textView.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Self.gap),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func accepts(_ block: MarkdownBlock) -> Bool {
        if case .quote = block { true } else { false }
    }

    func show(_ block: MarkdownBlock, renderer: MarkdownRenderer) {
        guard case let .quote(text) = block else { return }
        textView.setText(text)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        textView.prepare(width: width - Self.barWidth - Self.gap)
        return textView.preparedHeight
    }
}

final class RuleBlockView: UIView, MarkdownBlockView {
    private let line = UIView()

    init() {
        super.init(frame: .zero)
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1 / max(1, UITraitCollection.current.displayScale)),
            heightAnchor.constraint(equalToConstant: 12),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func accepts(_ block: MarkdownBlock) -> Bool { block == .rule }
    func show(_ block: MarkdownBlock, renderer: MarkdownRenderer) {}
    func height(forWidth width: CGFloat) -> CGFloat { 12 }
}

/// Code as written: monospaced, never wrapped, scrolling sideways when a line is long, with
/// a Copy button at its top corner and its language, when the fence gave one, beside it.
final class CodeBlockView: UIView, MarkdownBlockView {
    private let languageLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let codeView = TranscriptTextView()
    private lazy var codeWidth = codeView.widthAnchor.constraint(equalToConstant: 0)
    private lazy var codeHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
    /// Below the header row when there is a language to show; otherwise the code starts at
    /// the top and the Copy button sits over its first line's end.
    private lazy var belowHeader = scrollView.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: -6)
    private lazy var atTop = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding)
    private(set) var code = ""
    /// What the block shows: `code` with any line too long to lay out cut short.
    private(set) var displayedCode = ""
    private var copyReset: Task<Void, Never>?
    private static let padding: CGFloat = 12
    /// The widest a line is laid out, in points. A single unbroken line (minified JSON, a
    /// log line) would otherwise make a view hundreds of thousands of points wide; Copy
    /// still copies all of it.
    static let maximumLineWidth: CGFloat = 4_000

    init() {
        super.init(frame: .zero)
        backgroundColor = LatchPalette.codeBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        languageLabel.font = .preferredFont(forTextStyle: .caption1)
        languageLabel.adjustsFontForContentSizeCategory = true
        languageLabel.textColor = .secondaryLabel

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "doc.on.doc")
        configuration.preferredSymbolConfigurationForImage = .init(textStyle: .footnote)
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .init(top: 10, leading: 12, bottom: 10, trailing: 12)
        copyButton.configuration = configuration
        copyButton.accessibilityLabel = "Copy Code"
        copyButton.showsLargeContentViewer = true
        copyButton.largeContentTitle = "Copy Code"
        copyButton.addAction(UIAction { [weak self] _ in self?.copyCode() }, for: .primaryActionTriggered)

        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInset = .init(top: 0, left: Self.padding, bottom: 0, right: Self.padding)
        codeView.textContainer.lineBreakMode = .byClipping
        codeView.textContainer.widthTracksTextView = false
        codeView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        codeView.accessibilityLabel = "Code"

        // The button over the code, for when it sits on the first line.
        for view in [scrollView, languageLabel, copyButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        codeView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(codeView)
        NSLayoutConstraint.activate([
            languageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            languageLabel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            languageLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            copyButton.topAnchor.constraint(equalTo: topAnchor),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            copyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            belowHeader,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            bottomAnchor.constraint(greaterThanOrEqualTo: copyButton.bottomAnchor),
            codeHeight,
            codeView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            codeView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            codeView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            codeView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            codeView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            codeWidth,
        ])
        accessibilityElements = [codeView, copyButton]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func accepts(_ block: MarkdownBlock) -> Bool {
        if case .code = block { true } else { false }
    }

    func show(_ block: MarkdownBlock, renderer: MarkdownRenderer) {
        guard case let .code(language, code) = block else { return }
        self.code = code
        languageLabel.text = language
        languageLabel.isHidden = language == nil
        let hasHeader = language != nil
        if belowHeader.isActive != hasHeader {
            belowHeader.isActive = hasHeader
            atTop.isActive = !hasHeader
        }
        // Without a header the button covers the first line's end: the code can scroll out from under it.
        scrollView.contentInset.right = hasHeader ? Self.padding : 44
        let font = renderer.codeBlockFont
        let limit = max(40, Int(Self.maximumLineWidth / (font.pointSize * 0.62)))
        displayedCode = Self.cutting(code, toLinesOf: limit)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 2
        let text = NSAttributedString(string: displayedCode, attributes: [
            .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
        ])
        codeView.setText(text)
        // Measured unwrapped: a line is as long as it is, and the scroll view pans across it.
        let size = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
        codeWidth.constant = ceil(max(size.width, 1)) + 2
        codeHeight.constant = ceil(max(size.height, font.lineHeight))
        codeView.prepare(width: codeWidth.constant)
    }

    /// `code` with every line longer than `limit` characters cut to it and ended with "…".
    static func cutting(_ code: String, toLinesOf limit: Int) -> String {
        guard code.utf16.count > limit else { return code }
        var cut = false
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard line.count > limit else { return line }
            cut = true
            return line.prefix(limit) + "…"
        }
        return cut ? lines.joined(separator: "\n") : code
    }

    private func copyCode() {
        UIPasteboard.general.string = code
        var configuration = copyButton.configuration
        configuration?.image = UIImage(systemName: "checkmark")
        copyButton.configuration = configuration
        copyButton.accessibilityLabel = "Copied"
        UIAccessibility.post(notification: .announcement, argument: "Copied")
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            var configuration = copyButton.configuration
            configuration?.image = UIImage(systemName: "doc.on.doc")
            copyButton.configuration = configuration
            copyButton.accessibilityLabel = "Copy Code"
        }
    }
}

/// A real grid: columns as wide as their content up to a limit, cells wrapping inside it,
/// the header set in semibold on a tinted row, hairlines between cells. A table wider than
/// the reply scrolls sideways rather than squeezing its columns.
final class TableBlockView: UIView, MarkdownBlockView {
    private let scrollView = UIScrollView()
    private let grid = TableGridView()
    private lazy var gridWidth = grid.widthAnchor.constraint(equalToConstant: 0)
    private lazy var gridHeight = grid.heightAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.clipsToBounds = true
        grid.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(grid)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalTo: grid.heightAnchor),
            grid.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            grid.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            gridWidth, gridHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func accepts(_ block: MarkdownBlock) -> Bool {
        if case .table = block { true } else { false }
    }

    func show(_ block: MarkdownBlock, renderer: MarkdownRenderer) {
        guard case let .table(table) = block else { return }
        let size = grid.show(table, renderer: renderer)
        gridWidth.constant = size.width
        gridHeight.constant = size.height
    }

    /// Whether the table is wider than the reply and pans sideways.
    var scrolls: Bool { gridWidth.constant > scrollView.bounds.width + 0.5 }
}

final class TableGridView: UIView {
    private var labels: [[UILabel]] = []
    private var columnWidths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private let header = UIView()
    private let lines = CAShapeLayer()
    private static let padding = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / max(1, UITraitCollection.current.displayScale)
        clipsToBounds = true
        header.backgroundColor = LatchPalette.codeBackground
        addSubview(header)
        lines.fillColor = nil
        lines.lineWidth = layer.borderWidth
        layer.addSublayer(lines)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: TableGridView, _) in
            view.updateColors()
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openLink)))
    }

    /// A tap on a cell with a link opens its first one; labels have no links of their own.
    @objc private func openLink(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        guard let text = labels.joined().first(where: { $0.frame.insetBy(dx: -8, dy: -6).contains(point) })?.attributedText,
              let url = Self.firstLink(in: text) else { return }
        UIApplication.shared.open(url)
    }

    static func firstLink(in text: NSAttributedString) -> URL? {
        var link: URL?
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let url = value as? URL, MarkdownRenderer.isAllowed(url) { link = url; stop.pointee = true }
        }
        return link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateColors() {
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        lines.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    /// Lays the table out and returns its size, which depends only on its content.
    func show(_ table: MarkdownTable, renderer: MarkdownRenderer) -> CGSize {
        labels.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        let rows = [table.header] + table.rows
        let bodyFont = renderer.font(for: .tableCell)
        // Wide enough for a phrase, narrow enough that a paragraph in one cell wraps.
        let maximum = round(bodyFont.pointSize * 16)
        let minimum = round(bodyFont.pointSize * 2.5)
        labels = rows.enumerated().map { rowIndex, row in
            row.enumerated().map { column, text in
                let label = UILabel()
                label.numberOfLines = 0
                let cell = NSMutableAttributedString(attributedString: text)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = switch table.alignments[column] {
                case .leading: .natural
                case .center: .center
                case .trailing: .right
                }
                paragraph.lineBreakMode = .byWordWrapping
                cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
                if cell.length == 0 {
                    cell.setAttributedString(NSAttributedString(string: " ", attributes: renderer.attributes(for: rowIndex == 0 ? .tableHeader : .tableCell)))
                }
                label.attributedText = cell
                label.accessibilityTraits = rowIndex == 0 ? .header : .staticText
                if Self.firstLink(in: cell) != nil {
                    cell.enumerateAttribute(.link, in: NSRange(location: 0, length: cell.length)) { value, range, _ in
                        guard value != nil else { return }
                        cell.addAttribute(.foregroundColor, value: LatchPalette.tint, range: range)
                    }
                    label.attributedText = cell
                    label.accessibilityTraits.insert(.link)
                }
                addSubview(label)
                return label
            }
        }
        let padding = Self.padding
        columnWidths = table.alignments.indices.map { column in
            let natural = labels.map { row in
                ceil(row[column].attributedText?.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width ?? 0)
            }.max() ?? 0
            return min(max(natural, minimum), maximum) + padding.left + padding.right
        }
        rowHeights = labels.map { row in
            row.enumerated().map { column, label in
                ceil(label.sizeThatFits(CGSize(width: columnWidths[column] - padding.left - padding.right,
                                               height: .greatestFiniteMagnitude)).height)
            }.max().map { $0 + padding.top + padding.bottom } ?? 0
        }
        setNeedsLayout()
        return CGSize(width: columnWidths.reduce(0, +), height: rowHeights.reduce(0, +))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding = Self.padding
        let path = UIBezierPath()
        var y: CGFloat = 0
        for (rowIndex, row) in labels.enumerated() {
            var x: CGFloat = 0
            for (column, label) in row.enumerated() {
                let width = columnWidths[column]
                label.frame = CGRect(x: x + padding.left, y: y + padding.top,
                                     width: width - padding.left - padding.right,
                                     height: rowHeights[rowIndex] - padding.top - padding.bottom)
                if rowIndex == 0, column > 0 {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: bounds.height))
                }
                x += width
            }
            if rowIndex == 0 { header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: rowHeights[0]) }
            y += rowHeights[rowIndex]
            if rowIndex < labels.count - 1 {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: bounds.width, y: y))
            }
        }
        lines.frame = bounds
        lines.path = path.cgPath
    }
}
