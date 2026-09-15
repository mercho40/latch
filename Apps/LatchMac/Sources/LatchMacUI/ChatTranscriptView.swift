import AppKit

/// A session-local, selectable transcript. The composer and connection status belong to the parent.
@MainActor
final class ChatTranscriptView: NSView {
    static let horizontalInset: CGFloat = 16

    let scrollView = NSScrollView()
    var messageCount: Int { order.count }

    private let document = TranscriptDocumentView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let jump = NSButton(title: "Jump to Latest", target: nil, action: nil)
    private var rows: [UUID: TranscriptMessageView] = [:]
    private var order: [UUID] = []
    private var working = false
    private var followsBottom = true
    private var arranging = false
    private let findBar = TranscriptFindBar()
    private var matches: [(id: UUID, range: NSRange)] = []
    private var matchIndex = 0
    private var findTerm = ""

    override var isFlipped: Bool { true }

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
        jump.bezelStyle = .rounded
        jump.target = self
        jump.action = #selector(jumpToLatest)
        jump.isHidden = true
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
        let id = order.first { (rows[$0]?.frame.maxY ?? 0) > y }
        return Anchor(id: id, offset: y - (id.flatMap { rows[$0]?.frame.minY } ?? 0), origin: y)
    }

    func update(messages: [ChatMessage], isWorking: Bool) {
        let saved = anchor()
        // Ignore duplicate IDs defensively; upstream ChatHistory normally guarantees uniqueness.
        var seen = Set<UUID>()
        let retained = messages.suffix(ChatHistory.maximumMessageCount).filter { seen.insert($0.id).inserted }
        let ids = Set(retained.map(\.id))
        for id in order where !ids.contains(id) {
            rows.removeValue(forKey: id)?.removeFromSuperview()
        }
        order = retained.map(\.id)
        for message in retained {
            if let row = rows[message.id], row.role == message.role {
                row.update(text: message.text)
            } else {
                rows.removeValue(forKey: message.id)?.removeFromSuperview()
                let row = TranscriptMessageView(message: message)
                row.onDisclosure = { [weak self] in
                    guard let self else { return }
                    self.arrange(restoring: self.anchor())
                }
                rows[message.id] = row
                document.addSubview(row)
            }
        }
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
        var y: CGFloat = 16
        for id in order {
            guard let row = rows[id] else { continue }
            let height = row.arrange(width: columnWidth)
            row.frame.origin = NSPoint(x: inset, y: y)
            y += height + 12
        }
        if !status.isHidden {
            let size = status.sizeThatFits(NSSize(width: columnWidth, height: .greatestFiniteMagnitude))
            status.frame = NSRect(x: inset, y: y, width: columnWidth, height: max(24, ceil(size.height)))
            y = status.frame.maxY + 16
        }
        // Reserve space for the floating jump control, never over the last message.
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y + 40))
        let bottom = max(0, document.frame.height - scrollView.contentView.bounds.height)
        let restored = saved.id.flatMap { rows[$0] }.map { $0.frame.minY + saved.offset } ?? saved.origin
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: followsBottom ? bottom : min(bottom, max(0, restored))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        jump.sizeToFit()
        jump.frame.origin = NSPoint(x: max(0, (bounds.width - jump.frame.width) / 2), y: max(0, bounds.height - jump.frame.height - 8))
        jump.isHidden = followsBottom || bottom == 0
    }

    @objc private func scrolled() {
        guard !arranging else { return }
        let clip = scrollView.contentView.bounds
        followsBottom = document.frame.height - clip.maxY <= 24
        jump.isHidden = followsBottom
    }

    @objc private func jumpToLatest() {
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
            guard let row = rows[id], !row.textView.isHidden else { continue }
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
        try require(shortRow.frame.minX >= 16, "Missing side inset")
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
        try require(codeFont == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), "Fenced code is not monospaced")
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
        var tool = ChatMessage(role: .tool, text: "Read Sources · running\nFull tool details")
        probe.update(messages: [tool], isWorking: false)
        let toolRow = probe.rows[tool.id]!
        let toolIdentity = ObjectIdentifier(toolRow)
        let toolHeight = toolRow.frame.height
        try require(toolRow.textView.isHidden && toolRow.bubble == .zero && toolHeight == 24, "Tool is not a compact collapsed unboxed row")
        toolRow.toggleDisclosure()
        try require(!toolRow.textView.isHidden && toolRow.frame.height > toolHeight && toolRow.textView.string == tool.text, "Tool disclosure lost full content")
        tool.text = "Read Sources · completed\nUpdated tool details"
        probe.update(messages: [tool], isWorking: false)
        try require(ObjectIdentifier(probe.rows[tool.id]!) == toolIdentity && !toolRow.textView.isHidden && toolRow.textView.string == tool.text, "Tool update replaced/collapsed row or lost details")
        try require(toolRow.subviews.compactMap { $0 as? NSButton }.contains { !$0.isHidden && $0.accessibilityLabel()?.contains("completed") == true }, "Tool status update is not accessibility discoverable")
        toolRow.toggleDisclosure()
        try require(toolRow.textView.isHidden && toolRow.frame.height == toolHeight, "Tool did not collapse")
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

@MainActor
private final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class TranscriptMessageView: NSView {
    let role: ChatMessage.Role
    let textView = TranscriptTextView(frame: .zero)
    var onDisclosure: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let copy = TranscriptCopyButton(title: "Copy", target: nil, action: nil)
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private(set) var rawText: String?
    private var expanded = false
    private(set) var bubble = NSRect.zero
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0
    private var naturalTextWidth: CGFloat = 0
    private var bubbleRadius: CGFloat = 12
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    private var isDisclosure: Bool { role == .tool }
    /// Clears the 20pt disclosure triangle drawn at the row's leading edge.
    static let disclosureIndent: CGFloat = 24

    override var isFlipped: Bool { true }

    init(message: ChatMessage) {
        role = message.role
        super.init(frame: .zero)
        label.stringValue = switch role {
        case .user: "You"
        case .assistant: "Assistant"
        case .tool: "Tool"
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
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.setAccessibilityLabel("\(label.stringValue) message")
        textView.isHidden = isDisclosure
        addSubview(textView)
        update(text: message.text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String) {
        guard rawText != text else { return }
        rawText = text
        measuredWidth = -1
        let previous = textView.string as NSString
        let selection = textView.selectedRanges
        let content: NSAttributedString
        if role == .assistant {
            content = ChatMarkdown.render(text)
        } else if role == .tool {
            content = ToolTranscriptStyle.render(text)
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 3
            let font = NSFont.systemFont(ofSize: ChatMarkdown.bodyFontSize)
            content = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ])
        }
        let restored = Self.remap(selection, from: previous, to: content.string as NSString)
        textView.textStorage?.setAttributedString(content)
        textView.selectedRanges = restored
        if role == .user {
            // Measure once per source update, not on every viewport layout.
            naturalTextWidth = ceil(content.size().width)
        }
        if isDisclosure {
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            label.stringValue = firstLine.isEmpty ? "Tool activity" : firstLine
            label.toolTip = firstLine
            updateDisclosureAccessibility()
        }
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

    func arrange(width: CGFloat) -> CGFloat {
        let user = role == .user
        let padding: CGFloat = user ? min(12, width * 0.08) : 0
        let bubbleWidth = user ? min(width * 0.8, max(1, naturalTextWidth) + padding * 2) : width
        let x = user ? width - bubbleWidth : 0
        // Expanded tool text lines up with its header title, not with the disclosure triangle.
        let bodyIndent: CGFloat = isDisclosure ? Self.disclosureIndent : 0
        let textWidth = max(1, bubbleWidth - padding * 2 - bodyIndent)
        let headerHeight: CGFloat = isDisclosure ? 24 : 0
        if !textView.isHidden && measuredWidth != textWidth {
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
        label.frame = NSRect(x: Self.disclosureIndent, y: 3,
                             width: max(1, width - Self.disclosureIndent), height: 18)
        // Trailing edge under the bubble text, not under the bubble's rounded edge.
        let copyX = user ? max(0, width - padding - 40) : bodyIndent
        copy.frame = NSRect(x: copyX, y: headerHeight + bodyHeight + 2, width: min(40, width), height: 20)
        disclosure.frame = NSRect(x: 0, y: 2, width: min(20, width), height: 20)
        let textFrame = NSRect(x: x + padding + bodyIndent, y: headerHeight + padding,
                               width: textWidth, height: measuredHeight)
        if textView.frame != textFrame { textView.frame = textFrame }
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
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
        disclosure.setAccessibilityLabel("\(expanded ? "Collapse" : "Expand") \(label.stringValue)")
        disclosure.toolTip = label.stringValue
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
