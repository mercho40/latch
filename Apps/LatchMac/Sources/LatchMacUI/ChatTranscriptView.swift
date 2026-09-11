import AppKit

/// A session-local, selectable transcript. The composer and connection status belong to the parent.
@MainActor
final class ChatTranscriptView: NSView {
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
        working = isWorking
        let label = order.isEmpty
            ? (working ? "Working on your request…" : "Start a conversation. Your messages will appear here.")
            : (working ? "Working…" : "")
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
        scrollView.frame = bounds
        scrollView.tile()
        let width = max(1, scrollView.contentSize.width)
        let inset: CGFloat = min(16, width / 12)
        var y: CGFloat = 16
        for id in order {
            guard let row = rows[id] else { continue }
            let height = row.arrange(width: max(1, width - inset * 2))
            row.frame.origin = NSPoint(x: inset, y: y)
            y += height + 12
        }
        if !status.isHidden {
            let size = status.sizeThatFits(NSSize(width: max(1, width - inset * 2), height: .greatestFiniteMagnitude))
            status.frame = NSRect(x: inset, y: y, width: max(1, width - inset * 2), height: max(24, ceil(size.height)))
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

    /// Focused real-AppKit checks; uses a separate view and never changes the displayed conversation.
    func smokeTest() throws {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func require(_ value: Bool, _ description: String) throws {
            if !value { throw Failure(description: description) }
        }
        let probe = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        var messages = (0..<12).map {
            ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
                        text: "Message \($0)\n" + String(repeating: "Long wrapping text with selectable content. ", count: 8))
        }
        let diagnostic = ChatMessage(role: .diagnostics, text: "Raw diagnostics\n" + String(repeating: "trace\n", count: 20))
        messages.append(diagnostic)
        probe.update(messages: messages, isWorking: true)
        let row = probe.rows[messages[11].id]!
        let identity = ObjectIdentifier(row)
        row.textView.setSelectedRange(NSRange(location: 2, length: 8))
        messages[11].text += "\n```swift\nlet value = 42\n```"
        probe.update(messages: messages, isWorking: true)
        try require(ObjectIdentifier(probe.rows[messages[11].id]!) == identity, "Streaming replaced a row")
        try require(row.textView.selectedRange() == NSRange(location: 2, length: 8), "Streaming lost selection")
        try require(row.textView.string == messages[11].text, "Streaming changed raw text")
        let codeRange = (messages[11].text as NSString).range(of: "let value")
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
        let diagnostics = probe.rows[diagnostic.id]!
        try require(diagnostics.textView.isHidden, "Diagnostics should start collapsed")
        let collapsedHeight = diagnostics.frame.height
        diagnostics.toggleDisclosure()
        try require(!diagnostics.textView.isHidden && diagnostics.frame.height > collapsedHeight, "Diagnostics did not expand")
        try require(diagnostics.textView.string == diagnostic.text, "Diagnostics lost raw text")
        messages[messages.count - 1].text += "\nNew trace"
        probe.update(messages: messages, isWorking: false)
        try require(!diagnostics.textView.isHidden, "Streaming collapsed expanded diagnostics")
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
        }
        probe.jumpToLatest()
        try require(abs(probe.document.frame.height - probe.scrollView.contentView.bounds.maxY) < 2, "Jump did not reach bottom")
        probe.update(messages: (0..<405).map { ChatMessage(role: .tool, text: "Tool \($0)") }, isWorking: false)
        try require(probe.messageCount == 400 && probe.rows.count == 400, "Transcript exceeded history bound")
        probe.update(messages: [], isWorking: false)
        try require(probe.messageCount == 0 && !probe.status.isHidden, "Missing empty state")
    }
}

@MainActor
private final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class TranscriptMessageView: NSView {
    let role: ChatMessage.Role
    let textView = NSTextView(frame: .zero)
    var onDisclosure: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let copy = NSButton(title: "Copy", target: nil, action: nil)
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private var rawText: String?
    private var expanded = false
    private var bubble = NSRect.zero
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    init(message: ChatMessage) {
        role = message.role
        super.init(frame: .zero)
        label.stringValue = switch role {
        case .user: "You"
        case .assistant: "Assistant"
        case .tool: "Tool"
        case .diagnostics: "Diagnostics"
        }
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        copy.bezelStyle = .inline
        copy.font = .systemFont(ofSize: 11)
        copy.target = self
        copy.action = #selector(copyMessage)
        copy.setAccessibilityLabel("Copy \(label.stringValue.lowercased()) message")
        copy.isHidden = role != .user && role != .assistant
        addSubview(copy)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.target = self
        disclosure.action = #selector(toggleDisclosure)
        disclosure.setAccessibilityLabel("Expand diagnostics")
        disclosure.isHidden = role != .diagnostics
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
        textView.isHidden = role == .diagnostics
        addSubview(textView)
        update(text: message.text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String) {
        guard rawText != text else { return }
        rawText = text
        measuredWidth = -1
        let selection = textView.selectedRanges
        let font = NSFont.systemFont(ofSize: role == .tool ? 12 : 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        let content = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        // Preserve fences and all source text, changing only the font of fenced lines.
        if role == .diagnostics {
            content.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: NSRange(location: 0, length: content.length))
        } else if role == .assistant || role == .user {
            let source = text as NSString
            var position = 0
            var fenced = false
            while position < source.length {
                let range = source.lineRange(for: NSRange(location: position, length: 0))
                let isFence = source.substring(with: range).trimmingCharacters(in: .whitespaces).hasPrefix("```")
                if fenced || isFence {
                    content.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: range)
                }
                if isFence { fenced.toggle() }
                position = NSMaxRange(range)
            }
        }
        textView.textStorage?.setAttributedString(content)
        textView.selectedRanges = selection.map {
            let range = $0.rangeValue
            let start = min(range.location, content.length)
            return NSValue(range: NSRange(location: start, length: min(range.length, content.length - start)))
        }
    }

    func arrange(width: CGFloat) -> CGFloat {
        let conversational = role == .user || role == .assistant
        let bubbleWidth = conversational ? min(760, width * 0.9) : width
        let x = role == .user ? width - bubbleWidth : 0
        let padding: CGFloat = conversational ? 12 : 6
        let textWidth = max(1, bubbleWidth - padding * 2)
        let headerHeight: CGFloat = 24
        if !textView.isHidden && measuredWidth != textWidth {
            let container = textView.textContainer!
            container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
            let manager = textView.layoutManager!
            manager.ensureLayout(for: container)
            measuredHeight = ceil(max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)) + 2
            measuredWidth = textWidth
        }
        let height = textView.isHidden ? headerHeight + 8 : headerHeight + measuredHeight + padding * 2
        frame.size = NSSize(width: width, height: height)
        bubble = NSRect(x: x, y: 0, width: bubbleWidth, height: height)
        let disclosureSpace: CGFloat = role == .diagnostics ? 22 : 0
        label.frame = NSRect(x: x + padding + disclosureSpace, y: 5, width: max(1, textWidth - disclosureSpace - (copy.isHidden ? 0 : 44)), height: 18)
        copy.frame = NSRect(x: x + bubbleWidth - padding - 40, y: 3, width: 40, height: 20)
        disclosure.frame = NSRect(x: x + padding, y: 3, width: 20, height: 20)
        textView.frame = NSRect(x: x + padding, y: headerHeight + padding, width: textWidth, height: measuredHeight)
        needsDisplay = true
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color: NSColor = switch role {
        case .user: NSColor.controlAccentColor.withAlphaComponent(0.12)
        case .assistant: .controlBackgroundColor
        case .tool, .diagnostics: .quaternaryLabelColor
        }
        color.setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 10, yRadius: 10).fill()
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

    @objc func toggleDisclosure() {
        expanded.toggle()
        disclosure.state = expanded ? .on : .off
        disclosure.setAccessibilityLabel(expanded ? "Collapse diagnostics" : "Expand diagnostics")
        textView.isHidden = !expanded
        onDisclosure?()
    }
}
