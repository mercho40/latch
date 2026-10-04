import AppKit
import LatchSessionKit

/// A session-local, selectable transcript. The composer and connection status belong to the parent.
@MainActor
final class ChatTranscriptView: NSView {
    /// The one side margin: text, the banner and the composer all sit this far from the sidebar
    /// and from the window's edge.
    static let horizontalInset: CGFloat = 20
    static let rowSpacing: CGFloat = 12
    static let groupedRowSpacing: CGFloat = 2
    /// How far each level of a subagent's rows sits in from the row of its call.
    static let nestingIndent: CGFloat = 20

    let scrollView = NSScrollView()
    var messageCount: Int { order.count }
    /// Row geometry in transcript order, so a layout test can compare what the
    /// viewport-limited resize path produced against a full measurement.
    var rowFrames: [NSRect] { order.compactMap { rows[$0] }.filter { !$0.isHidden }.map(\.frame) }

    private let document = TranscriptDocumentView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let jump = FloatingRoundButton.make(symbol: "arrow.down", label: "Jump to Latest")
    private var rows: [UUID: TranscriptMessageView] = [:]
    /// Display order: each subagent's rows directly under the row of its call, depth first,
    /// wherever the main agent's own messages fell between them.
    private var order: [UUID] = []
    /// The row of the subagent each nested row belongs to, among the rows shown.
    private var parents: [UUID: UUID] = [:]
    private var working = false
    private var followsBottom = true
    private var arranging = false
    private let findBar = TranscriptFindBar()
    private var matches: [(id: UUID, range: NSRange)] = []
    private var matchIndex = 0
    private var findTerm = ""

    override var isFlipped: Bool { true }

    /// Rows dissolve into the toolbar: an opacity ramp over the top of the scroll view. The bottom is
    /// not faded, because there the rows pass under the composer and are blurred, not removed. The
    /// scroller's strip is masked fully opaque, so the scroll bar itself never fades.
    private func updateEdgeMask() {
        scrollView.wantsLayer = true
        guard let layer = scrollView.layer else { return }
        if layer.mask !== maskContainer {
            maskContainer.addSublayer(edgeMask)
            scrollerStrip.backgroundColor = NSColor.black.cgColor
            maskContainer.addSublayer(scrollerStrip)
            layer.mask = maskContainer
        }
        let height = max(1, scrollView.bounds.height)
        let fadeTop = findBar.isHidden ? Self.topFade / height : 0
        let strip = scrollerStripWidth
        // The scroller stops above the composer instead of running under the glass.
        // Only on a change: setting it retiles the scroll view, and this runs on every layout.
        if abs(scrollView.scrollerInsets.bottom - bottomOverlay) > 0.5 {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomOverlay, right: 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskContainer.frame = scrollView.bounds
        edgeMask.frame = NSRect(x: 0, y: 0, width: max(0, scrollView.bounds.width - strip), height: scrollView.bounds.height)
        scrollerStrip.frame = NSRect(x: scrollView.bounds.width - strip, y: 0, width: strip, height: scrollView.bounds.height)
        // The scroll view's layer sits in a flipped hierarchy, so which end of the gradient is the
        // top depends on the layer, not on intuition.
        if layer.contentsAreFlipped() {
            edgeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
            edgeMask.locations = [0, NSNumber(value: fadeTop), 1]
        } else {
            edgeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            edgeMask.locations = [0, NSNumber(value: max(0, 1 - fadeTop)), 1]
        }
        CATransaction.commit()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        document.addSubview(status)
        jump.target = self
        jump.action = #selector(jumpToLatest)
        jump.isHidden = true
        addSubview(bottomBlur, positioned: .above, relativeTo: scrollView)
        addSubview(deepBlur, positioned: .above, relativeTo: bottomBlur)
        addSubview(topBlur, positioned: .above, relativeTo: scrollView)
        addSubview(jump)
        findBar.isHidden = true
        findBar.onSearch = { [weak self] term in self?.search(term) }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose = { [weak self] in self?.endFind() }
        addSubview(findBar)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        update(messages: [], isWorking: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private struct Anchor {
        let id: UUID?
        let offset: CGFloat
        let origin: CGFloat
    }

    private func anchor() -> Anchor {
        let y = scrollView.contentView.bounds.minY
        let id = order.first { rows[$0].map { !$0.isHidden && $0.frame.maxY > y } ?? false }
        return Anchor(id: id, offset: y - (id.flatMap { rows[$0]?.frame.minY } ?? 0), origin: y)
    }

    func update(messages: [ChatMessage], isWorking: Bool) {
        let saved = anchor()
        // Ignore duplicate IDs defensively; upstream ChatHistory normally guarantees uniqueness.
        var seen = Set<UUID>()
        let retained = messages.suffix(ChatHistory.maximumMessageCount).filter { seen.insert($0.id).inserted }
        let ids = Set(retained.map(\.id))
        for id in Array(rows.keys) where !ids.contains(id) {
            rows.removeValue(forKey: id)?.removeFromSuperview()
        }
        let nesting = Self.nesting(of: retained)
        order = nesting.order
        parents = nesting.parents
        let progress = Self.subagentProgress(of: retained, parents: parents)
        for message in retained {
            if let row = rows[message.id], row.role == message.role {
                row.update(text: message.text, tool: message.tool)
            } else {
                rows.removeValue(forKey: message.id)?.removeFromSuperview()
                let row = TranscriptMessageView(message: message)
                row.onDisclosure = { [weak self] in
                    guard let self else { return }
                    self.refreshVisibility()
                    if !self.findTerm.isEmpty { self.recomputeMatches() }
                    self.arrange(restoring: self.anchor())
                }
                rows[message.id] = row
                document.addSubview(row)
            }
            rows[message.id]?.subagentProgress = progress[message.id]
        }
        refreshVisibility()
        if !findTerm.isEmpty { recomputeMatches() }
        working = isWorking
        let label = working ? "Working…" : ""
        // No live-region announcements or restarting animations on each streaming token.
        if status.stringValue != label { status.stringValue = label }
        status.isHidden = label.isEmpty
        arrange(restoring: saved)
    }

    override func layout() {
        super.layout()
        guard !arranging else { return }
        arrange(restoring: anchor())
    }

    /// Display order and parents. A message whose parent is not shown, or that would close a
    /// loop, stays at the top level in its own place.
    static func nesting(of messages: [ChatMessage]) -> (order: [UUID], parents: [UUID: UUID]) {
        let ids = Set(messages.map(\.id))
        var parents: [UUID: UUID] = [:]
        for message in messages {
            guard let parent = message.parentID, parent != message.id, ids.contains(parent) else { continue }
            parents[message.id] = parent
        }
        // A loop has no top to hang from; cut it at the message that closes it.
        for message in messages where parents[message.id] != nil {
            var seen: Set<UUID> = [message.id]
            var current = parents[message.id]
            while let ancestor = current {
                if !seen.insert(ancestor).inserted { parents[message.id] = nil; break }
                current = parents[ancestor]
            }
        }
        var children: [UUID: [UUID]] = [:]
        for message in messages { if let parent = parents[message.id] { children[parent, default: []].append(message.id) } }
        var order: [UUID] = []
        order.reserveCapacity(messages.count)
        func visit(_ id: UUID) {
            order.append(id)
            for child in children[id] ?? [] { visit(child) }
        }
        for message in messages where parents[message.id] == nil { visit(message.id) }
        return (order, parents)
    }

    /// For each subagent's row, how many tool calls are under it, at any depth, and the
    /// title of the latest of them.
    fileprivate static func subagentProgress(of messages: [ChatMessage], parents: [UUID: UUID]) -> [UUID: TranscriptMessageView.SubagentProgress] {
        let subagents = Set(messages.filter { $0.tool?.runsSubagent == true }.map(\.id))
        guard !subagents.isEmpty else { return [:] }
        var progress: [UUID: TranscriptMessageView.SubagentProgress] = [:]
        // Every streaming frame comes through here: only rows under a parent count.
        for message in messages where message.role == .tool && parents[message.id] != nil {
            let title = TranscriptMessageView.toolTitle(message.text)
            var current = parents[message.id]
            while let ancestor = current {
                if subagents.contains(ancestor) {
                    progress[ancestor, default: .init(steps: 0, latest: nil)].steps += 1
                    progress[ancestor]?.latest = title
                }
                current = parents[ancestor]
            }
        }
        return progress
    }

    /// Rows under a folded subagent are hidden, and the rest sit in by their depth.
    private func refreshVisibility() {
        for id in order {
            guard let row = rows[id] else { continue }
            var depth = 0
            var hidden = false
            var current = parents[id]
            while let ancestor = current {
                depth += 1
                if rows[ancestor]?.isExpanded == false { hidden = true }
                current = parents[ancestor]
            }
            row.depth = depth
            if row.isHidden != hidden { row.isHidden = hidden }
        }
    }

    /// While the window edge is being dragged, only the rows the reader can see are
    /// re-measured; the rest keep the height they had until the drag ends. Re-wrapping
    /// every row's text on every step cost 30ms a frame at the history bound, which is two
    /// dropped frames at 60Hz and four on a ProMotion display.
    ///
    /// Internal because no unit test can enter a real AppKit resize loop.
    var limitsMeasurementToViewport = false
    /// How much of the bottom of this view something floats over, the composer. The rows scroll
    /// under it, and the conversation's end stops this far up so the last message stays in view.
    var bottomOverlay: CGFloat = 0 {
        didSet { if abs(bottomOverlay - oldValue) > 0.5 { needsLayout = true } }
    }
    /// Rows dissolve into the toolbar over this height, and into the page over the overlay.
    static let topFade: CGFloat = 20
    private let edgeMask = CAGradientLayer()
    private let scrollerStrip = CALayer()
    private let maskContainer = CALayer()
    /// The vertical scroller's thickness, which the edge effects leave alone.
    private var scrollerStripWidth: CGFloat {
        guard let scroller = scrollView.verticalScroller else { return 0 }
        return type(of: scroller).scrollerWidth(for: scroller.controlSize, scrollerStyle: scrollView.scrollerStyle)
    }
    /// Behind the composer the rows are blurred, more so toward the window's edge, the way a
    /// messaging app lets a conversation run under its input bar.
    private let bottomBlur = EdgeBlurView(opaqueEdge: .bottom, lead: 24, radius: 4)
    /// Behind the composer itself the blur deepens, so what shows in the margins around it is a
    /// wash rather than readable text. Stacked on the band above, it makes the blur progressive.
    private let deepBlur = EdgeBlurView(opaqueEdge: .bottom, lead: 16, radius: 12)
    /// Under the toolbar the rows blur as well as fade, so they leave the view rather than being cut.
    private let topBlur = EdgeBlurView(opaqueEdge: .top, lead: 30, radius: 4)

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        limitsMeasurementToViewport = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        limitsMeasurementToViewport = false
        // Settle every deferred row against the width the reader actually stopped at.
        arrange(restoring: anchor())
    }

    private func arrange(restoring saved: Anchor) {
        guard !arranging else { return }
        arranging = true
        defer { arranging = false }
        let barHeight = findBar.isHidden ? 0 : TranscriptFindBar.height
        findBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        scrollView.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: max(1, bounds.height - barHeight))
        scrollView.tile()
        let width = max(1, scrollView.contentSize.width)
        let sideInset = min(Self.horizontalInset, width / 12)
        let columnWidth = max(1, width - sideInset * 2)
        let inset = (width - columnWidth) / 2
        // Clear of the fade into the toolbar, so the first row is never dimmed at rest.
        var y: CGFloat = Self.topFade + 6
        // A screen either side of the viewport, so a row that scrolls in mid-drag is
        // already exact. Rows are deferred against their previous height, so this window
        // drifts as it goes — that is what the margin is for.
        let viewport = scrollView.contentView.bounds
        let measured = viewport.insetBy(dx: 0, dy: -max(viewport.height, 1))
        let shown = order.compactMap { rows[$0] }.filter { !$0.isHidden }
        for (position, row) in shown.enumerated() {
            // A nested row starts its guide line half an indent in from its parent's content.
            let leading = row.depth > 0 ? CGFloat(row.depth) * Self.nestingIndent - TranscriptMessageView.guideWidth : 0
            let rowWidth = max(1, columnWidth - leading)
            let deferrable = limitsMeasurementToViewport && row.frame.height > 0
                && !measured.intersects(NSRect(x: inset + leading, y: y, width: rowWidth, height: row.frame.height))
            let height = deferrable ? row.deferArrange(width: rowWidth) : row.arrange(width: rowWidth)
            row.frame.origin = NSPoint(x: inset + leading, y: y)
            // A run of collapsed tool calls is one burst of activity, so its rows sit together as a
            // group; the ordinary gap is what separates that group from the messages around it.
            let next = position + 1 < shown.count ? shown[position + 1] : nil
            y += height + (row.isCollapsedTool && next?.isCollapsedTool == true ? Self.groupedRowSpacing : Self.rowSpacing)
        }
        if !status.isHidden {
            let size = status.sizeThatFits(NSSize(width: columnWidth, height: .greatestFiniteMagnitude))
            status.frame = NSRect(x: inset, y: y, width: columnWidth, height: max(24, ceil(size.height)))
            y = status.frame.maxY + 16
        }
        // Reserve space for the floating jump control, never over the last message.
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y + 40 + bottomOverlay))
        let bottom = max(0, document.frame.height - scrollView.contentView.bounds.height)
        let restored = saved.id.flatMap { rows[$0] }.map { $0.frame.minY + saved.offset } ?? saved.origin
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: followsBottom ? bottom : min(bottom, max(0, restored))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // A glass button's fitted size is its glyph's, which made a disc too small to hit or see.
        jump.setFrameSize(NSSize(width: FloatingRoundButton.diameter, height: FloatingRoundButton.diameter))
        jump.frame.origin = NSPoint(x: max(0, (bounds.width - jump.frame.width) / 2), y: max(0, bounds.height - bottomOverlay - jump.frame.height - 12))
        updateEdgeMask()
        // From a little above the composer to the bottom edge, so the blur starts before the glass does.
        topBlur.isHidden = !findBar.isHidden
        let bandWidth = max(0, bounds.width - scrollerStripWidth)
        topBlur.frame = NSRect(x: 0, y: scrollView.frame.minY, width: bandWidth, height: 36)
        let blurHeight = bottomOverlay > 0 ? bottomOverlay + bottomBlur.lead : 0
        bottomBlur.isHidden = blurHeight == 0
        bottomBlur.frame = NSRect(x: 0, y: bounds.height - blurHeight, width: bandWidth, height: blurHeight)
        // From the composer's top edge down; the 12-point gap above it is the band above's alone.
        let deepHeight = max(0, bottomOverlay - 12)
        deepBlur.isHidden = deepHeight == 0
        deepBlur.frame = NSRect(x: 0, y: bounds.height - deepHeight, width: bandWidth, height: deepHeight)
        jump.isHidden = followsBottom || bottom == 0
    }

    @objc private func scrolled() {
        guard !arranging else { return }
        let clip = scrollView.contentView.bounds
        followsBottom = document.frame.height - clip.maxY <= 24
        jump.isHidden = followsBottom
    }

    /// Opens or folds a tool call, thinking or a subagent, as its disclosure triangle does.
    func toggleDisclosure(of id: UUID) {
        rows[id]?.toggleDisclosure()
    }

    /// Where a row is in the document, or nil while it is hidden under a folded subagent.
    func visibleFrame(of id: UUID) -> NSRect? {
        rows[id].flatMap { $0.isHidden ? nil : $0.frame }
    }

    @objc func jumpToLatest() {
        followsBottom = true
        arrange(restoring: anchor())
    }

    // MARK: Find

    var isFindBarVisible: Bool { !findBar.isHidden }
    var matchCount: Int { matches.count }
    var currentMatch: Int { matches.isEmpty ? 0 : matchIndex + 1 }
    var canStepMatches: Bool { !matches.isEmpty }

    func beginFind() {
        let opening = findBar.isHidden
        findBar.isHidden = false
        if opening { arrange(restoring: anchor()) }
        window?.makeFirstResponder(findBar.field)
        findBar.field.currentEditor()?.selectAll(nil)
    }

    /// Escape closes the bar from anywhere in the conversation. It is deliberately not a
    /// key equivalent on the Done button: AppKit would then fire it on ⌘. as well, which
    /// belongs to Stop.
    override func cancelOperation(_ sender: Any?) {
        guard !findBar.isHidden else { return }
        endFind()
    }

    func endFind() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findBar.field.stringValue = ""
        findTerm = ""
        matches = []
        matchIndex = 0
        findBar.setStatus(index: 0, total: 0)
        if window?.firstResponder === findBar.field.currentEditor() { window?.makeFirstResponder(self) }
        arrange(restoring: anchor())
    }

    /// Collapsed tool rows are not searched: there is nothing on screen to reveal.
    func search(_ term: String) {
        findTerm = term
        recomputeMatches()
        matchIndex = 0
        if matches.isEmpty {
            findBar.setStatus(index: 0, total: 0)
        } else {
            reveal(0)
        }
    }

    func findNext() {
        guard !matches.isEmpty else { return }
        reveal((matchIndex + 1) % matches.count)
    }

    func findPrevious() {
        guard !matches.isEmpty else { return }
        reveal((matchIndex - 1 + matches.count) % matches.count)
    }

    private func recomputeMatches() {
        let previous = matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
        matches = []
        guard !findTerm.isEmpty else { return }
        for id in order {
            guard let row = rows[id], !row.isHidden, !row.textView.isHidden else { continue }
            let haystack = row.textView.string as NSString
            var location = 0
            while location < haystack.length {
                let scope = NSRange(location: location, length: haystack.length - location)
                let found = haystack.range(of: findTerm, options: [.caseInsensitive, .diacriticInsensitive], range: scope)
                guard found.location != NSNotFound, found.length > 0 else { break }
                matches.append((id, found))
                location = found.location + found.length
            }
        }
        // Stay on the same match across a streaming update where possible.
        matchIndex = previous.flatMap { match in
            matches.firstIndex { $0.id == match.id && $0.range == match.range }
        } ?? min(matchIndex, max(0, matches.count - 1))
        findBar.setStatus(index: matches.isEmpty ? 0 : matchIndex + 1, total: matches.count)
    }

    private func reveal(_ index: Int) {
        guard matches.indices.contains(index), let row = rows[matches[index].id] else { return }
        matchIndex = index
        let range = matches[index].range
        let text = row.textView
        text.setSelectedRange(range)
        findBar.setStatus(index: index + 1, total: matches.count)
        guard let manager = text.layoutManager, let container = text.textContainer else { return }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = text.convert(manager.boundingRect(forGlyphRange: glyphs, in: container), to: document)
        followsBottom = false
        let visible = scrollView.contentView.bounds.height
        let bottom = max(0, document.frame.height - visible)
        let target = min(bottom, max(0, rect.midY - visible / 2))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        jump.isHidden = bottom == 0
        text.showFindIndicator(for: range)
    }

    /// Focused real-AppKit checks; uses a separate view and never changes the displayed conversation.
    func smokeTest() throws {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func require(_ value: Bool, _ description: String) throws {
            if !value { throw Failure(description: description) }
        }
        let geometry = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        let short = ChatMessage(role: .user, text: "**Literal**")
        let long = ChatMessage(role: .user, text: String(repeating: "Long user message. ", count: 40))
        var markdown = ChatMessage(role: .assistant, text: "# Heading\n\n```swift\nlet value = 42")
        geometry.update(messages: [short, long, markdown], isWorking: true)
        let shortRow = geometry.rows[short.id]!, longRow = geometry.rows[long.id]!
        let plainRow = geometry.rows[markdown.id]!
        try require(shortRow.frame.width == geometry.scrollView.contentSize.width - Self.horizontalInset * 2,
                    "Transcript does not fill the available pane width")
        try require(abs(shortRow.frame.midX - geometry.scrollView.contentSize.width / 2) < 1, "Wide column is not centered in scroll content")
        try require(shortRow.frame.minX >= Self.horizontalInset - 1, "Missing side inset")
        try require(shortRow.bubble.width < longRow.bubble.width && longRow.bubble.width <= longRow.frame.width * 0.8, "User bubbles are not content-sized/capped")
        try require(shortRow.bubble.maxX == shortRow.bounds.maxX && shortRow.textView.string == short.text, "User text is not literal/right aligned")
        try require(plainRow.bubble == .zero && plainRow.textView.frame.minX == 0 && plainRow.textView.frame.width == plainRow.bounds.width && plainRow.textView.frame.minY == 0, "Assistant is boxed or has a role header")
        try require(!plainRow.textView.string.contains("```") && !plainRow.textView.string.contains("# Heading"), "Markdown markers/fences remain visible")
        let incompleteCode = (plainRow.textView.string as NSString).range(of: "let value")
        try require(incompleteCode.location != NSNotFound, "Incomplete fence lost code")
        plainRow.textView.setSelectedRange(incompleteCode)
        markdown.text += "\n```\nMore **output**"
        geometry.update(messages: [short, long, markdown], isWorking: false)
        try require(plainRow.textView.selectedRange() == incompleteCode, "Closing fence lost rendered selection")
        try require(plainRow.rawText == markdown.text && plainRow.textView.source?() == markdown.text, "Raw Markdown copy source changed")
        let copyControl = plainRow.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Copy" }!
        try require(!copyControl.isHidden && copyControl.acceptsFirstResponder && copyControl.accessibilityLabel() != nil && copyControl.frame.minY >= plainRow.textView.frame.maxY, "Copy metadata is not below text or keyboard/AX discoverable")
        let unchangedStorage = plainRow.textView.textStorage!
        let unchangedContent = NSAttributedString(attributedString: unchangedStorage)
        geometry.update(messages: [short, long, markdown], isWorking: false)
        try require(unchangedStorage.isEqual(to: unchangedContent) && plainRow.textView.selectedRange() == incompleteCode, "Unchanged update changed content/selection")
        markdown.text = "**Selected words"
        geometry.update(messages: [markdown], isWorking: true)
        plainRow.textView.setSelectedRange((plainRow.textView.string as NSString).range(of: "Selected words"))
        markdown.text += "** and more"
        geometry.update(messages: [markdown], isWorking: false)
        try require((plainRow.textView.string as NSString).substring(with: plainRow.textView.selectedRange()) == "Selected words", "Completing inline Markdown lost rendered selection")
        markdown.text = "**a a"
        geometry.update(messages: [markdown], isWorking: true)
        plainRow.textView.setSelectedRange(NSRange(location: 2, length: 1))
        markdown.text += "**"
        geometry.update(messages: [markdown], isWorking: false)
        try require(plainRow.textView.selectedRange() == NSRange(location: 0, length: 1), "Completing Markdown moved selection to a repeated word")
        let probe = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        var messages = (0..<12).map {
            ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
                        text: "Message \($0)\n" + String(repeating: "Long wrapping text with selectable content. ", count: 8))
        }
        probe.update(messages: messages, isWorking: true)
        let row = probe.rows[messages[11].id]!
        let identity = ObjectIdentifier(row)
        row.textView.setSelectedRange(NSRange(location: 2, length: 8))
        messages[11].text += "\n```swift\nlet value = 42\n```"
        probe.update(messages: messages, isWorking: true)
        try require(ObjectIdentifier(probe.rows[messages[11].id]!) == identity, "Streaming replaced a row")
        try require(row.textView.selectedRange() == NSRange(location: 2, length: 8), "Streaming lost selection")
        try require(row.rawText == messages[11].text && !row.textView.string.contains("```"), "Streaming lost raw source or showed fences")
        let codeRange = (row.textView.string as NSString).range(of: "let value")
        try require(codeRange.location != NSNotFound, "Rendered code is missing")
        let codeFont = row.textView.textStorage?.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        try require(codeFont == NSFont.monospacedSystemFont(ofSize: ChatMarkdown.codeFontSize, weight: .regular), "Fenced code is not monospaced")
        messages[11].text += "\n\n| Step | Result |\n| --- | ---: |\n| build | ok |"
        probe.update(messages: messages, isWorking: true)
        let cellRange = (row.textView.string as NSString).range(of: "build")
        try require(cellRange.location != NSNotFound && !row.textView.string.contains("| Step |"), "Table markup is still visible")
        let cellStyle = row.textView.textStorage?.attribute(.paragraphStyle, at: cellRange.location, effectiveRange: nil) as? NSParagraphStyle
        try require(cellStyle?.textBlocks.first is NSTextTableBlock, "A table cell is not laid out in a text table")
        try require(abs(probe.document.frame.height - probe.scrollView.contentView.bounds.maxY) < 2, "Did not follow bottom")
        probe.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        probe.scrolled()
        let before = probe.scrollView.contentView.bounds.minY
        messages[11].text += String(repeating: "\nMore output", count: 20)
        probe.update(messages: messages, isWorking: true)
        try require(abs(probe.scrollView.contentView.bounds.minY - before) < 2, "Streaming moved a scrolled-up reader")
        try require(!probe.jump.isHidden, "Missing Jump to Latest")
        probe.update(messages: messages, isWorking: false)
        try require(probe.rows.count == messages.count && probe.rows.values.allSatisfy { !$0.textView.isHidden }, "Conversation contains unexpected or collapsed rows")
        let wideHeight = row.frame.height
        let resizeAnchor = probe.anchor()
        probe.frame.size.width = 180
        probe.layoutSubtreeIfNeeded()
        probe.arrange(restoring: probe.anchor())
        try require(row.frame.height > wideHeight, "Narrow resize did not remeasure wrapping")
        try require(probe.anchor().id == resizeAnchor.id && abs(probe.anchor().offset - resizeAnchor.offset) < 2, "Resize lost the reading anchor")
        try require(row.textView.selectedRange() == NSRange(location: 2, length: 8), "Resize lost selection")
        for item in probe.rows.values where !item.textView.isHidden {
            let manager = item.textView.layoutManager!
            let container = item.textView.textContainer!
            manager.ensureLayout(for: container)
            let measured = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
            try require(item.textView.frame.height >= ceil(measured), "Narrow layout clips text vertically")
            try require(item.frame.maxX <= probe.document.bounds.width + 1, "Narrow layout overflows horizontally")
            try require(manager.usedRect(for: container).maxX <= item.textView.bounds.width + 1, "Narrow text is clipped horizontally")
        }
        probe.jumpToLatest()
        try require(abs(probe.document.frame.height - probe.scrollView.contentView.bounds.maxY) < 2, "Jump did not reach bottom")
        let longCommand = "echo \"=== tree ===\" && " + String(repeating: "find . -name '*.swift' -not -path './.build/*' | wc -l && ", count: 12)
        let longTool = ChatMessage(role: .tool, text: longCommand + "true · completed\nOutput")
        probe.update(messages: [longTool], isWorking: false)
        probe.layoutSubtreeIfNeeded()
        if let header = probe.rows[longTool.id]?.subviews.compactMap({ $0 as? NSTextField }).first(where: { !$0.isHidden }), let cell = header.cell {
            let oneLine = ceil(header.font?.boundingRectForFont.height ?? 18)
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: header.bounds.width, height: .greatestFiniteMagnitude)).height
            try require(needed <= oneLine + 1, "A long tool title wraps instead of truncating, and its status is lost")
        } else {
            try require(false, "Missing tool header")
        }
        var tool = ChatMessage(role: .tool, text: "Read Sources · running\nFull tool details")
        probe.update(messages: [tool], isWorking: false)
        let toolRow = probe.rows[tool.id]!
        let toolIdentity = ObjectIdentifier(toolRow)
        let toolHeight = toolRow.frame.height
        try require(toolRow.textView.isHidden && toolRow.bubble == .zero && toolHeight == 24, "Tool is not a compact collapsed unboxed row")
        toolRow.toggleDisclosure()
        try require(!toolRow.textView.isHidden && toolRow.frame.height > toolHeight && toolRow.textView.string == TranscriptMessageView.toolBody(tool.text), "Tool disclosure lost its details")
        tool.text = "Read Sources · completed\nUpdated tool details"
        probe.update(messages: [tool], isWorking: false)
        try require(ObjectIdentifier(probe.rows[tool.id]!) == toolIdentity && !toolRow.textView.isHidden && toolRow.textView.string == TranscriptMessageView.toolBody(tool.text), "Tool update replaced/collapsed row or lost details")
        try require(toolRow.subviews.compactMap { $0 as? NSButton }.contains { !$0.isHidden && $0.accessibilityLabel()?.contains("completed") == true }, "Tool status update is not accessibility discoverable")
        toolRow.toggleDisclosure()
        try require(toolRow.textView.isHidden && toolRow.frame.height == toolHeight, "Tool did not collapse")
        let thought = ChatMessage(role: .thought, text: "Where does it start?\nProbably in main.")
        let subagent = ChatMessage(role: .tool, text: "Explore the code · in_progress\n\nFind the entry point",
                                   tool: ToolSummary(callID: "a", kind: "think", status: "in_progress", toolName: "Agent", runsSubagent: true))
        let step = ChatMessage(role: .tool, text: "Read main.swift · completed", tool: ToolSummary(callID: "r", kind: "read", status: "completed"),
                               parentID: subagent.id)
        let words = ChatMessage(role: .assistant, text: "It starts in main.", parentID: subagent.id)
        probe.update(messages: [thought, subagent, step, words], isWorking: true)
        let thoughtRow = probe.rows[thought.id]!, subagentRow = probe.rows[subagent.id]!
        try require(thoughtRow.textView.isHidden && thoughtRow.headerText == "Thinking: Where does it start?", "Thinking is not a folded row titled by its first line")
        try require(probe.rows[step.id]!.isHidden && probe.rows[words.id]!.isHidden, "A folded subagent shows its rows")
        try require(subagentRow.headerText.hasSuffix(" · 1 step — Read main.swift"), "A running subagent's header does not say how far it has got")
        subagentRow.toggleDisclosure()
        let stepRow = probe.rows[step.id]!
        try require(!stepRow.isHidden && stepRow.depth == 1 && stepRow.frame.minX > subagentRow.frame.minX, "An opened subagent's rows are not shown indented under it")
        probe.update(messages: (0..<405).map { ChatMessage(role: .tool, text: "Tool \($0)") }, isWorking: false)
        try require(probe.messageCount == 400 && probe.rows.count == 400, "Transcript exceeded history bound")
        probe.update(messages: [], isWorking: false)
        try require(probe.messageCount == 0 && probe.status.isHidden && probe.status.stringValue.isEmpty, "Idle empty chat shows placeholder text")
        probe.update(messages: [], isWorking: true)
        try require(probe.messageCount == 0 && !probe.status.isHidden && probe.status.stringValue == "Working…", "Prompting lost its working indicator")
        probe.update(messages: [], isWorking: false)
        try require(probe.status.isHidden && probe.status.stringValue.isEmpty, "Working indicator remains after prompting")
    }
}

/// The guide line's width, for tests; the row type itself is private.
enum TranscriptMessageViewGuide {
    static let width: CGFloat = 10
}

@MainActor
private final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class TranscriptMessageView: NSView {
    let role: ChatMessage.Role
    /// Built by hand so the layout manager and container are ours from the start. A text view made
    /// this way does not own its storage, so the row does.
    private let storage = NSTextStorage()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private(set) lazy var textView: TranscriptTextView = {
        let manager = TranscriptLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return TranscriptTextView(frame: .zero, textContainer: container)
    }()
    var onDisclosure: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let copy = TranscriptCopyButton(title: "Copy", target: nil, action: nil)
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private(set) var rawText: String?
    /// A sent message's files and images, listed above its text. Set once: a user message never changes.
    private var attachments: [ChatAttachment] = []
    /// Resumable Markdown state for this row, so a streaming answer re-parses from its
    /// first changed line instead of from the top on every frame. Unused by other roles.
    private let markdown = ChatMarkdown.Cache()
    private var expanded = false
    private(set) var bubble = NSRect.zero
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0
    private var naturalTextWidth: CGFloat = 0
    private var bubbleRadius: CGFloat = 12
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    private var isDisclosure: Bool { role == .tool || role == .thought }
    var isCollapsedTool: Bool { isDisclosure && !expanded }
    /// What a subagent's row holds: rows under a folded one are hidden.
    var isExpanded: Bool { !isDisclosure || expanded }
    /// Clears the 20pt disclosure triangle drawn at the row's leading edge.
    static let disclosureIndent: CGFloat = 24
    /// A nested row's guide line, and the gap after it, before its content.
    static let guideWidth = TranscriptMessageViewGuide.width
    private(set) var tool: ToolSummary?
    /// How many levels of subagent this row is under; a nested row draws a guide line at its
    /// leading edge, and sits in one indent further for each level.
    var depth = 0 {
        didSet { if depth != oldValue { needsDisplay = true } }
    }

    struct SubagentProgress: Equatable {
        var steps: Int
        /// The title of the latest call under the subagent.
        var latest: String?
    }
    /// For a subagent's row: its calls so far, shown in the header so it need not be opened.
    var subagentProgress: SubagentProgress? {
        didSet { if subagentProgress != oldValue { refreshHeader() } }
    }
    /// The header as words, for the tooltip and accessibility; the label also carries a symbol.
    private(set) var headerText = ""

    override var isFlipped: Bool { true }

    init(message: ChatMessage) {
        role = message.role
        attachments = message.attachments
        super.init(frame: .zero)
        label.stringValue = switch role {
        case .user: "You"
        case .assistant: "Assistant"
        case .tool: "Tool"
        case .thought: "Thinking"
        }
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = !isDisclosure
        addSubview(label)
        copy.bezelStyle = .inline
        copy.font = .systemFont(ofSize: 11)
        copy.target = self
        copy.action = #selector(copyMessage)
        copy.setAccessibilityLabel("Copy \(label.stringValue.lowercased()) message")
        copy.isHidden = isDisclosure
        copy.shouldDraw = { [weak self] in
            guard let self else { return false }
            let focus = self.window?.firstResponder
            return self.hovered || focus === self.textView || focus === self.copy
        }
        textView.onFocusChange = { [weak self] in self?.copy.needsDisplay = true }
        textView.source = { [weak self] in self?.rawText ?? "" }
        addSubview(copy)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.target = self
        disclosure.action = #selector(toggleDisclosure)
        disclosure.isHidden = !isDisclosure
        addSubview(disclosure)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        // Code panels and quote bars are drawn behind the text; see TranscriptLayoutManager. Prose
        // runs the width of the row like everything else in it.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.setAccessibilityLabel("\(label.stringValue) message")
        textView.isHidden = isDisclosure
        addSubview(textView)
        update(text: message.text, tool: message.tool)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String, tool: ToolSummary? = nil) {
        if tool != self.tool {
            self.tool = tool
            if rawText == text { refreshHeader() }
        }
        guard rawText != text else { return }
        rawText = text
        measuredWidth = -1
        let previous = textView.string as NSString
        let selection = textView.selectedRanges
        let content: NSAttributedString
        if role == .assistant {
            content = ChatMarkdown.render(text, into: markdown)
        } else if role == .tool {
            // The header label already carries the title line; repeating it as the body's first line
            // made every expanded row say the same thing twice.
            content = ToolTranscriptStyle.render(Self.toolBody(text), titled: false)
        } else if role == .thought {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 2
            content = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: ChatMarkdown.bodyFontSize - 1),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ])
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 3
            let font = NSFont.systemFont(ofSize: ChatMarkdown.bodyFontSize)
            let body = NSMutableAttributedString(attributedString: Self.attachmentLine(attachments, paragraph: paragraph))
            if body.length > 0, !text.isEmpty { body.append(NSAttributedString(string: "\n")) }
            body.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]))
            content = body
        }
        let next = content.string as NSString
        let shared = Self.sharedPrefix(previous, next)
        // Streaming only ever appends, and an append moves nothing that is already
        // selected. The diff below is for the rarer case of a rewrite.
        let restored = shared == previous.length ? selection : Self.remap(selection, from: previous, to: next)
        if let storage = textView.textStorage {
            // An assistant row renders through a cache that already knows how much output
            // it carried over untouched, so there is nothing to rediscover.
            Self.apply(content, to: storage, sharedPrefix: shared,
                       reusing: role == .assistant ? markdown.reusedLength : nil)
        }
        textView.selectedRanges = restored
        if role == .user {
            // Measure once per source update, not on every viewport layout.
            naturalTextWidth = ceil(content.size().width)
        }
        if isDisclosure { refreshHeader() }
    }

    /// A tool call's header: a symbol for its kind, "title · status", and for a subagent how far
    /// it has got. Thinking reads "Thinking" and its first words.
    private func refreshHeader() {
        guard isDisclosure, let text = rawText else { return }
        // Claude titles its thinking in bold; the header shows the words, not the markers.
        let firstLine = role == .thought ? Self.firstLine(of: text).trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
            : Self.firstLine(of: text)
        let font = label.font ?? .systemFont(ofSize: 12)
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = role == .thought ? .byTruncatingTail : .byTruncatingMiddle
        let quiet: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: oneLine]
        let header = NSMutableAttributedString(attributedString: Self.symbol(role == .thought ? "brain" : Self.symbolName(for: tool, title: firstLine),
                                                                          font: font, paragraph: oneLine))
        if role == .thought {
            header.append(NSAttributedString(string: "Thinking", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: oneLine,
            ]))
            if !firstLine.isEmpty { header.append(NSAttributedString(string: "  " + firstLine, attributes: quiet)) }
            headerText = "Thinking: " + firstLine
        } else {
            let line = firstLine.isEmpty ? "Tool activity" : firstLine
            header.append(Self.toolHeader(line, font: font))
            headerText = line
            if let progress = subagentProgress, progress.steps > 0 {
                var extra = " · \(progress.steps) \(progress.steps == 1 ? "step" : "steps")"
                // While it works, its latest call says what it is doing now.
                if Self.isRunning(tool?.status), let latest = progress.latest { extra += " — " + latest }
                header.append(NSAttributedString(string: extra, attributes: quiet))
                headerText += extra
            }
        }
        label.attributedStringValue = header
        label.toolTip = headerText
        updateDisclosureAccessibility()
    }

    /// The text up to its first line break, without walking a long message's whole text.
    static func firstLine(of text: String) -> String {
        String(text.prefix { !$0.isNewline })
    }

    static func isRunning(_ status: String?) -> Bool {
        ["pending", "in_progress", "running"].contains(status?.lowercased() ?? "")
    }

    /// The title of a tool row's text, without its status.
    static func toolTitle(_ text: String) -> String {
        let firstLine = firstLine(of: text)
        guard let separator = firstLine.range(of: " · ", options: .backwards) else { return firstLine }
        return String(firstLine[..<separator.lowerBound])
    }

    /// A symbol for what kind of thing a call does, from ACP's kinds; a subagent's has its own.
    static func symbolName(for tool: ToolSummary?, title: String = "") -> String {
        if tool?.runsSubagent == true { return "person.2" }
        return switch tool?.kind ?? Self.guessedKind(title) {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.left.arrow.right"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "lightbulb"
        case "fetch": "globe"
        case "switch_mode": "arrow.triangle.branch"
        default: "wrench.and.screwdriver"
        }
    }

    /// A row saved before calls carried their kind says it by its title's first word, as
    /// Claude Code's titles do: "Read …", "Edit …", "Search …".
    static func guessedKind(_ title: String) -> String? {
        switch title.prefix { !$0.isWhitespace }.lowercased() {
        case "read", "view", "list": "read"
        case "edit", "write", "update", "create": "edit"
        case "delete", "remove": "delete"
        case "move", "rename": "move"
        case "search", "grep", "glob", "find": "search"
        case "run", "bash", "execute", "terminal": "execute"
        case "fetch", "websearch", "webfetch": "fetch"
        default: title.hasPrefix("`") ? "execute" : nil
        }
    }

    /// A symbol sat on the text's baseline, in the secondary colour, and a space after it.
    private static func symbol(_ name: String, font: NSFont, paragraph: NSParagraphStyle) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return NSAttributedString()
        }
        let glyph = NSTextAttachment()
        glyph.image = image
        // Sized to the capitals and centred on them: a symbol at the font's point size stands
        // taller than the line, and the header then no longer fits in one.
        let height = ceil(font.capHeight * 1.4)
        let width = image.size.width * height / max(1, image.size.height)
        glyph.bounds = NSRect(x: 0, y: (font.capHeight - height) / 2, width: width, height: height)
        let piece = NSMutableAttributedString(attachment: glyph)
        piece.append(NSAttributedString(string: " "))
        piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
        return piece
    }

    /// Each attachment as a symbol and its name, in the secondary colour, on the line above the text.
    static func attachmentLine(_ attachments: [ChatAttachment], paragraph: NSParagraphStyle) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: ChatMarkdown.bodyFontSize - 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]
        let line = NSMutableAttributedString()
        for (index, attachment) in attachments.enumerated() {
            if index > 0 { line.append(NSAttributedString(string: "    ", attributes: attributes)) }
            let symbol = attachment.kind == .image ? "photo" : "doc"
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
                .applying(.init(hierarchicalColor: .secondaryLabelColor))
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: attachment.kind == .image ? "Image" : "File")?
                .withSymbolConfiguration(configuration) {
                let glyph = NSTextAttachment()
                glyph.image = image
                // Sit the symbol on the text's baseline rather than above it.
                glyph.bounds = NSRect(x: 0, y: font.descender / 2, width: image.size.width, height: image.size.height)
                let piece = NSMutableAttributedString(attachment: glyph)
                piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
                line.append(piece)
            }
            line.append(NSAttributedString(string: " " + attachment.name, attributes: attributes))
        }
        return line
    }

    /// "Title · status", with the status coloured when it is one a reader should not skim past.
    /// Colour backs up the word, never replaces it, so nothing depends on seeing red.
    static func toolHeader(_ line: String, font: NSFont?) -> NSAttributedString {
        // An attributed title brings its own paragraph style, and without one it wraps by word:
        // a long shell command lost its tail and its status to the clipped second line. Cutting
        // the middle keeps what ran and how it went; the tooltip has the whole line.
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingMiddle
        let base: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: oneLine]
        let result = NSMutableAttributedString(string: line, attributes: base)
        guard let separator = line.range(of: " · ", options: .backwards) else { return result }
        let status = line[separator.upperBound...].lowercased()
        let color: NSColor? = switch status {
        case "failed", "error", "cancelled", "canceled": .systemRed
        case "running", "in_progress", "pending": .labelColor
        default: nil
        }
        if let color {
            result.addAttribute(.foregroundColor, value: color, range: NSRange(separator.upperBound..<line.endIndex, in: line))
        }
        return result
    }

    /// A tool message is its title line, then its details. Copy still takes the whole message.
    static func toolBody(_ text: String) -> String {
        guard let lineEnd = text.firstIndex(where: \.isNewline) else { return "" }
        return String(text[lineEnd...].drop(while: \.isNewline))
    }

    /// Write only what changed. `setAttributedString` invalidates the whole layout, so a
    /// streaming answer re-laid out its entire text on every frame — 68ms per frame at the
    /// 200,000-character history bound. An edit confined to the changed range lets
    /// `NSLayoutManager` keep the layout it already has, which measures at 3ms.
    private static func apply(_ content: NSAttributedString, to storage: NSTextStorage,
                              sharedPrefix: Int, reusing reusable: Int?) {
        // Characters agreeing is not enough: closing a Markdown construct restyles text
        // that is already on screen, and a table rebuilds the cells above its new row, so
        // the styling has to match too. What a renderer carried over verbatim is known to
        // match and can be skipped; the rest is found by walking the attribute runs, which
        // is what carries an answer the renderer could not resume — one long line.
        let known = min(reusable ?? 0, sharedPrefix)
        let shared = styledPrefix(storage, content, from: known, upTo: sharedPrefix)
        let replaced = NSRange(location: shared, length: storage.length - shared)
        let inserted = NSRange(location: shared, length: content.length - shared)
        guard replaced.length > 0 || inserted.length > 0 else { return }
        storage.replaceCharacters(in: replaced, with: content.attributedSubstring(from: inserted))
    }

    /// Length of the common UTF-16 prefix. Compared in blocks through `getCharacters` —
    /// bridging either string to `[UInt16]` costs more than the comparison it feeds.
    private static func sharedPrefix(_ old: NSString, _ new: NSString) -> Int {
        let limit = min(old.length, new.length)
        var matched = 0
        let block = 4096
        var left = [unichar](repeating: 0, count: block)
        var right = [unichar](repeating: 0, count: block)
        while matched < limit {
            let count = min(block, limit - matched)
            let range = NSRange(location: matched, length: count)
            old.getCharacters(&left, range: range)
            new.getCharacters(&right, range: range)
            var index = 0
            while index < count, left[index] == right[index] { index += 1 }
            matched += index
            if index < count { break }
        }
        return matched
    }

    /// How much of that common prefix also carries identical attributes. Walks attribute
    /// runs rather than characters, and starts at the point the caller already knows to be
    /// identical — for densely marked-up text those runs are the bulk of the work.
    private static func styledPrefix(_ old: NSAttributedString, _ new: NSAttributedString,
                                     from start: Int, upTo limit: Int) -> Int {
        var location = start
        while location < limit {
            let scope = NSRange(location: location, length: limit - location)
            var oldRun = NSRange()
            var newRun = NSRange()
            let oldAttributes = old.attributes(at: location, longestEffectiveRange: &oldRun, in: scope)
            let newAttributes = new.attributes(at: location, longestEffectiveRange: &newRun, in: scope)
            guard NSDictionary(dictionary: oldAttributes).isEqual(to: newAttributes) else { return location }
            location = min(NSMaxRange(oldRun), NSMaxRange(newRun))
        }
        return limit
    }

    /// Diff rendered UTF-16, never source offsets: closing Markdown can change earlier glyphs.
    private static func remap(_ selections: [NSValue], from old: NSString, to new: NSString) -> [NSValue] {
        let a = Array((old as String).utf16), b = Array((new as String).utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        func position(_ value: Int) -> Int {
            if value <= prefix { return value }
            if value >= a.count - suffix { return max(0, value + b.count - a.count) }
            return min(value, b.count - suffix)
        }
        return selections.map {
            let range = $0.rangeValue
            let start = min(new.length, max(0, position(range.location)))
            let end = min(new.length, max(start, position(NSMaxRange(range))))
            let mapped = NSRange(location: start, length: end - start)
            if range.length > 0, NSMaxRange(range) <= old.length {
                let selected = old.substring(with: range)
                // Preserve the same occurrence when a shared prefix/suffix identifies it.
                if mapped.length == range.length, new.substring(with: mapped) == selected {
                    return NSValue(range: mapped)
                }
                let forward = new.range(of: selected, options: .literal, range: NSRange(location: start, length: new.length - start))
                let backward = new.range(of: selected, options: [.literal, .backwards], range: NSRange(location: 0, length: min(new.length, start + range.length)))
                let candidates = [forward, backward].filter { $0.location != NSNotFound }
                if let nearest = candidates.min(by: { abs($0.location - start) < abs($1.location - start) }) {
                    return NSValue(range: nearest)
                }
            }
            return NSValue(range: mapped)
        }
    }

    /// Keep the height measured at the previous width, and mark the row for re-measurement
    /// the next time it is arranged exactly. Only for rows that are off screen.
    func deferArrange(width: CGFloat) -> CGFloat {
        measuredWidth = -1
        frame.size.width = width
        return frame.height
    }

    func arrange(width: CGFloat) -> CGFloat {
        // A nested row's content starts after its guide line.
        let lead: CGFloat = depth > 0 ? Self.guideWidth : 0
        let contentWidth = max(1, width - lead)
        let user = role == .user
        let padding: CGFloat = user ? min(12, contentWidth * 0.08) : 0
        let bubbleWidth = user ? min(contentWidth * 0.8, max(1, naturalTextWidth) + padding * 2) : contentWidth
        let x = lead + (user ? contentWidth - bubbleWidth : 0)
        // Expanded tool text lines up with its header title, not with the disclosure triangle.
        let bodyIndent: CGFloat = isDisclosure ? Self.disclosureIndent : 0
        let textWidth = max(1, bubbleWidth - padding * 2 - bodyIndent)
        let headerHeight: CGFloat = isDisclosure ? 24 : 0
        if !textView.isHidden && measuredWidth != textWidth {
            // Deliberately TextKit 1: reaching for `layoutManager` is what drops this view
            // out of TextKit 2, and that is the right trade here. A row is sized to its
            // whole message, so viewport layout buys nothing, and `NSTextLayoutManager`
            // has to lay out the full document for each height — measured at 1.57ms per
            // append over 2,000 lines against 0.072ms here, and it does not flatten out.
            let container = textView.textContainer!
            container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
            let manager = textView.layoutManager!
            manager.ensureLayout(for: container)
            measuredHeight = ceil(max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)) + 2
            measuredWidth = textWidth
        }
        let bodyHeight = textView.isHidden ? 0 : measuredHeight + padding * 2
        let height = headerHeight + bodyHeight + (isDisclosure && !expanded ? 0 : 24)
        frame.size = NSSize(width: width, height: height)
        let newBubble = user ? NSRect(x: x, y: 0, width: bubbleWidth, height: bodyHeight) : .zero
        if bubbleRadius != padding { bubbleRadius = padding; needsDisplay = true }
        if bubble != newBubble {
            bubble = newBubble
            needsDisplay = true
        }
        label.frame = NSRect(x: lead + Self.disclosureIndent, y: 3,
                             width: max(1, contentWidth - Self.disclosureIndent), height: 18)
        // Trailing edge under the bubble text, not under the bubble's rounded edge.
        let copyX = user ? max(0, width - padding - 40) : lead + bodyIndent
        copy.frame = NSRect(x: copyX, y: headerHeight + bodyHeight + 2, width: min(40, contentWidth), height: 20)
        disclosure.frame = NSRect(x: lead, y: 2, width: min(20, contentWidth), height: 20)
        let textFrame = NSRect(x: x + padding + bodyIndent, y: headerHeight + padding,
                               width: textWidth, height: measuredHeight)
        if textView.frame != textFrame { textView.frame = textFrame }
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if depth > 0 {
            NSColor.separatorColor.setFill()
            NSRect(x: 3, y: 0, width: 1, height: bounds.height).fill()
        }
        guard role == .user else { return }
        NSColor.quaternaryLabelColor.setFill()
        // Concentric with the text inside: the corner never cuts closer than the padding.
        NSBezierPath(roundedRect: bubble, xRadius: bubbleRadius, yRadius: bubbleRadius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        textView.needsDisplay = true
    }

    @objc private func copyMessage() {
        guard let rawText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawText, forType: .string)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        copy.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        copy.needsDisplay = true
    }

    private func updateDisclosureAccessibility() {
        disclosure.setAccessibilityLabel("\(expanded ? "Collapse" : "Expand") \(headerText)")
        disclosure.toolTip = headerText
    }

    @objc func toggleDisclosure() {
        guard isDisclosure else { return }
        expanded.toggle()
        disclosure.state = expanded ? .on : .off
        updateDisclosureAccessibility()
        textView.isHidden = !expanded
        copy.isHidden = !expanded
        onDisclosure?()
    }
}

/// Drawing, not hiding/removing, keeps the metadata control in keyboard and AX navigation.
@MainActor
private final class TranscriptCopyButton: NSButton {
    var shouldDraw: (() -> Bool)?
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if shouldDraw?() == true { super.draw(dirtyRect) }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }
}

@MainActor
private final class TranscriptTextView: NSTextView {
    var source: (() -> String)?
    var onFocusChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        onFocusChange?()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        onFocusChange?()
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        menu.addItem(.separator())
        let item = menu.addItem(withTitle: "Copy Message Source", action: #selector(copySource), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source?() ?? "", forType: .string)
    }
}

/// A round button that floats over content, the way Messages returns to the newest message. The
/// wide labelled button it replaces covered the text it was about to uncover. It draws its own
/// disc because a system bezel has no surface of its own here, and an arrow with nothing behind
/// it is lost against a transcript; the shadow, not a heavier border, is what lifts it.
@MainActor
final class FloatingRoundButton: NSButton {
    static let diameter: CGFloat = 32

    /// On macOS 26 a glass button is a surface of its own, which is what this control lacked, and
    /// it has to be a plain NSButton: a subclass that overrides `draw` is not given the glass. The
    /// drawn disc below is for the systems before it.
    static func make(symbol: String, label: String) -> NSButton {
        guard #available(macOS 26.0, *) else { return FloatingRoundButton(symbol: symbol, label: label) }
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: nil, action: nil)
        button.bezelStyle = .glass
        button.borderShape = .circle
        button.controlSize = .large
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    init(symbol: String, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            return shadow
        }()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }
    override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    override func draw(_ dirtyRect: NSRect) {
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.controlBackgroundColor.setFill()
        disc.fill()
        NSColor.separatorColor.setStroke()
        disc.lineWidth = 1
        disc.stroke()
        super.draw(dirtyRect)
    }
}

/// A band that blurs and dims whatever scrolls behind it, both ramping from nothing at one edge to
/// full at the other, so rows sink out of focus rather than stopping at a line. It is a plain
/// Gaussian blur of the backdrop, not a vibrancy material: materials are tinted close to opaque in
/// dark mode, and the point is that the rows stay faintly legible as they pass under the composer.
/// It is decoration: clicks, scrolling and selection pass straight through to the rows behind it.
@MainActor
final class EdgeBlurView: NSView {
    enum Edge { case top, bottom }

    /// The distance from the band's clear edge over which rows go from sharp to nearly fully
    /// blurred; they are fully blurred at its far edge.
    let lead: CGFloat
    private let edge: Edge
    private let dim = CAGradientLayer()
    private let ramp = CAGradientLayer()

    init(opaqueEdge: Edge, lead: CGFloat, radius: CGFloat) {
        edge = opaqueEdge
        self.lead = lead
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        backgroundFilters = [blur]
        layer?.addSublayer(dim)
        // The same ramp masks the blur and the dimming, so both fade in together.
        ramp.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.5).cgColor, NSColor.black.cgColor]
        layer?.mask = ramp
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        ramp.frame = bounds
        // Start at the clear edge. Which way up that is depends on whether the layer is flipped.
        let clearAtTop = (edge == .bottom) != (layer?.contentsAreFlipped() ?? false)
        let (start, end) = clearAtTop ? (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)) : (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
        ramp.startPoint = start; ramp.endPoint = end
        dim.startPoint = start; dim.endPoint = end
        let lead = NSNumber(value: min(1, self.lead / max(1, bounds.height)))
        ramp.locations = [0, lead, 1]
        dim.locations = [0, lead, 1]
        CATransaction.commit()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let page = LatchPalette.page
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            dim.colors = [page.withAlphaComponent(0).cgColor, page.withAlphaComponent(dark ? 0.1 : 0.08).cgColor,
                          page.withAlphaComponent(dark ? 0.3 : 0.25).cgColor]
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}
