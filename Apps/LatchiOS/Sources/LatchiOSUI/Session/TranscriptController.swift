import LatchSessionKit
import UIKit

/// Tells its owner after each layout pass, which is when a pinned transcript keeps its end in
/// view, and when VoiceOver scrolls it, which is the reader leaving the end.
final class TranscriptCollectionView: UICollectionView {
    var onLayout: (() -> Void)?
    var onAccessibilityScroll: ((UIAccessibilityScrollDirection) -> Void)?
    /// The column's edges from the content's, set by the screen from its composer's, so the
    /// conversation lines up with it whatever the readable width and the sidebar do. Until
    /// then the column is worked out from the readable width.
    var column: (leading: CGFloat, trailing: CGFloat)? {
        didSet {
            guard column?.leading != oldValue?.leading || column?.trailing != oldValue?.trailing else { return }
            collectionViewLayout.invalidateLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        onAccessibilityScroll?(direction)
        return super.accessibilityScroll(direction)
    }
}

/// The conversation: one list row per message, keyed by the message's ID, so a streaming
/// update reconfigures the one row whose text changed and leaves the rest alone. What a
/// subagent did is shown under its row, in the order `TranscriptOutline` gives, while that row
/// is expanded. While the reader is at the end it stays there as the answer grows; once they
/// scroll up it stays put, and `onScroll` lets the screen offer a way back.
@MainActor
final class TranscriptController: NSObject, UICollectionViewDelegate {
    /// The widest the conversation's column gets, so lines on an iPad stay a comfortable
    /// length. The banner and composer share it.
    static let maximumColumnWidth: CGFloat = 700

    enum Item: Hashable {
        case message(UUID)
        /// "Working…" under the conversation while a turn runs.
        case working
    }

    let collectionView: TranscriptCollectionView
    let cache = MarkdownCache()
    var agentTitle = "Agent"
    /// Where the pictures of photos sent from this device are kept.
    var sentImages: SentImageCache?
    /// Copy writes here. Tests substitute a pasteboard of their own.
    var pasteboard = UIPasteboard.general
    /// Opens a link from a message's menu; tests replace it.
    var openURL: (URL) -> Void = { UIApplication.shared.open($0) }
    /// Whether the transcript follows its end. Only the reader's own scrolling changes it.
    private(set) var isPinned = true
    /// After any scroll, a change of pinning, or an update, all of which can change how far
    /// the end is out of view.
    var onScroll: (() -> Void)?

    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var messages: [UUID: ChatMessage] = [:]
    private var kinds: [UUID: ChatMessageKind] = [:]
    /// Every message, in the order it arrived.
    private var arrival: [ChatMessage] = []
    /// The rows shown, in order: what is under a collapsed row is not among them.
    private(set) var order: [UUID] = []
    private var rowInfo: [UUID: TranscriptRowInfo] = [:]
    private(set) var expanded: Set<UUID> = []
    /// A row opened while the transcript followed its end. It follows the end only while that
    /// keeps the row's top in sight: past that, the reader is reading the row, and it stays put.
    private var opening: UUID?
    private var isWorking = false
    private var isStopping = false
    /// Set while the transcript moves itself, so only the reader's moves change `isPinned`.
    private var isAutoScrolling = false
    /// Select Text chosen from a message's menu, done once the menu has gone.
    private var pendingSelection: (id: UUID, point: CGPoint)?
    private var menuShowing = false

    override init() {
        weak var host: TranscriptCollectionView?
        let layout = UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            // The readable width, capped: the ordinary margins on iPhone, a centred column on
            // iPad, lined up with the banner and the composer.
            var leading: CGFloat = 16
            var trailing: CGFloat = 16
            if let column = host?.column {
                leading = column.leading
                trailing = column.trailing
            } else if let host, host.bounds.width > 0 {
                // Centred in the readable width rather than the view's, which on iPad runs
                // under the sidebar: the composer's constraints do the same.
                let readable = host.readableContentGuide.layoutFrame
                let spare = max(0, (readable.width - TranscriptController.maximumColumnWidth) / 2)
                leading = max(16, readable.minX - host.bounds.minX + spare)
                trailing = max(16, host.bounds.maxX - readable.maxX + spare)
            }
            section.contentInsetsReference = .none
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: leading, bottom: 8, trailing: trailing)
            return section
        }
        collectionView = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()
        host = collectionView
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.allowsSelection = false
        collectionView.accessibilityLabel = "Conversation"
        collectionView.onLayout = { [weak self] in self?.keepPinned() }
        collectionView.onAccessibilityScroll = { [weak self] _ in self?.setPinned(false) }
        configureDataSource()
        collectionView.accessibilityCustomRotors = makeRotors()
        collectionView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) {
            [weak self] (view: TranscriptCollectionView, _) in
            view.collectionViewLayout.invalidateLayout()
            self?.reconfigureAll()
        }
    }

    private var context: TranscriptCellContext {
        TranscriptCellContext(
            agentTitle: agentTitle,
            renderer: MarkdownRenderer(traits: collectionView.traitCollection),
            cache: cache,
            isExpanded: { [weak self] in self?.expanded.contains($0) ?? false },
            toggle: { [weak self] in self?.toggle($0) },
            thumbnails: { [weak self] in self?.sentImages?.images(for: $0) ?? [] },
            row: { [weak self] in self?.rowInfo[$0] ?? TranscriptRowInfo() })
    }

    private func configureDataSource() {
        let user = UICollectionView.CellRegistration<UserMessageCell, UUID> { [weak self] cell, _, id in
            guard let self, let message = messages[id] else { return }
            cell.configure(message, context: context)
        }
        let assistant = UICollectionView.CellRegistration<AssistantMessageCell, UUID> { [weak self] cell, _, id in
            guard let self, let message = messages[id] else { return }
            cell.configure(message, context: context)
        }
        let tool = UICollectionView.CellRegistration<ToolCallCell, UUID> { [weak self] cell, _, id in
            guard let self, let message = messages[id] else { return }
            cell.configure(message, context: context)
        }
        let thought = UICollectionView.CellRegistration<ThoughtCell, UUID> { [weak self] cell, _, id in
            guard let self, let message = messages[id] else { return }
            cell.configure(message, context: context)
        }
        let notice = UICollectionView.CellRegistration<NoticeCell, UUID> { [weak self] cell, _, id in
            guard let self, let message = messages[id] else { return }
            cell.configure(message, context: context)
        }
        let working = UICollectionView.CellRegistration<WorkingCell, Item> { [weak self] cell, _, _ in
            cell.configure(stopping: self?.isStopping ?? false)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, path, item in
            guard case let .message(id) = item else {
                return view.dequeueConfiguredReusableCell(using: working, for: path, item: item)
            }
            switch self?.kinds[id] ?? .assistant {
            case .user: return view.dequeueConfiguredReusableCell(using: user, for: path, item: id)
            case .assistant: return view.dequeueConfiguredReusableCell(using: assistant, for: path, item: id)
            case .tool: return view.dequeueConfiguredReusableCell(using: tool, for: path, item: id)
            case .thought: return view.dequeueConfiguredReusableCell(using: thought, for: path, item: id)
            case .notice: return view.dequeueConfiguredReusableCell(using: notice, for: path, item: id)
            }
        }
    }

    static func kind(of message: ChatMessage) -> ChatMessageKind {
        switch message.role {
        case .user: .user
        case .tool: .tool
        case .thought: .thought
        case .assistant: ChatMessageKind.isNotice(message.text) ? .notice : .assistant
        }
    }

    /// Takes the model's messages as they are now. Rows whose message changed are
    /// reconfigured in place; a row whose kind changed is rebuilt. A subagent's row is
    /// reconfigured too when what is under it changes, since it counts and names its steps.
    func update(messages newMessages: [ChatMessage], isWorking working: Bool, isStopping stopping: Bool = false) {
        var seen = Set<UUID>()
        let retained = newMessages.filter { seen.insert($0.id).inserted }
        var changed: [UUID] = []
        var rebuilt: [UUID] = []
        var nextMessages: [UUID: ChatMessage] = [:]
        var nextKinds: [UUID: ChatMessageKind] = [:]
        for message in retained {
            let kind = Self.kind(of: message)
            nextMessages[message.id] = message
            nextKinds[message.id] = kind
            guard let old = messages[message.id] else { continue }
            if kinds[message.id] != kind { rebuilt.append(message.id) }
            else if old != message { changed.append(message.id) }
        }
        let stoppingChanged = working && stopping != isStopping
        isStopping = stopping
        guard retained.map(\.id) != arrival.map(\.id) || working != isWorking || stoppingChanged || !changed.isEmpty
            || !rebuilt.isEmpty else { return }
        messages = nextMessages
        kinds = nextKinds
        arrival = retained
        isWorking = working
        expanded.formIntersection(seen)
        cache.keep(seen)
        apply(changed: changed, rebuilt: rebuilt, stoppingChanged: stoppingChanged, animate: .insertions)
    }

    private enum Animation { case insertions, always }

    /// Shows the rows `TranscriptOutline` gives for the messages and what is expanded.
    private func apply(changed: [UUID], rebuilt: [UUID] = [], stoppingChanged: Bool = false, animate: Animation) {
        let outline = TranscriptOutline(arrival, expanded: expanded)
        // A row whose place or summary changed is drawn again, though its message did not.
        let moved = outline.rows.filter { id in rowInfo[id].map { $0 != outline.info[id] } ?? false }
        let inserted = Set(outline.rows).subtracting(order).isEmpty == false
        order = outline.rows
        rowInfo = outline.info
        if let id = opening, outline.info[id] == nil { opening = nil }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(order.map(Item.message))
        if isWorking { snapshot.appendItems([.working]) }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        // Only rows in both snapshots can be drawn again: one that has just gone under a folded
        // subagent is in the old one alone, and naming it to the new snapshot is fatal.
        let kept = existing.intersection(snapshot.itemIdentifiers)
        let rebuiltItems = Set(rebuilt.map(Item.message)).intersection(kept)
        let reconfigured = Set((changed + moved).map(Item.message)).intersection(kept).subtracting(rebuiltItems)
        snapshot.reconfigureItems(Array(reconfigured) + (stoppingChanged && existing.contains(.working) ? [.working] : []))
        snapshot.reloadItems(Array(rebuiltItems))
        // New rows fade in, and rows open and close; a streaming update never animates.
        let animated = (animate == .always || inserted) && !UIAccessibility.isReduceMotionEnabled
            && collectionView.window != nil && !existing.isEmpty
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.keepPinned()
            self?.onScroll?()
        }
    }

    private func reconfigureAll() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Opens or closes a row: a tool call's details, a thought, or a subagent with its steps.
    func toggle(_ id: UUID) {
        let opens = expanded.insert(id).inserted
        if !opens { expanded.remove(id) }
        if opens, isPinned { opening = id } else if opening == id { opening = nil }
        apply(changed: [id], animate: .always)
    }

    // MARK: Following the end

    /// How far the end of the conversation is below the bottom of what shows.
    var distanceFromBottom: CGFloat {
        let inset = collectionView.adjustedContentInset
        return collectionView.contentSize.height + inset.bottom - (collectionView.contentOffset.y + collectionView.bounds.height)
    }

    private var bottomOffset: CGFloat {
        let inset = collectionView.adjustedContentInset
        return max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
    }

    private func keepPinned() {
        guard isPinned, !collectionView.isTracking, !collectionView.isDecelerating, !readerIsElsewhere else { return }
        let target = bottomOffset
        if let id = opening, let path = dataSource.indexPath(for: .message(id)),
           let row = collectionView.layoutAttributesForItem(at: path)?.frame,
           target + collectionView.adjustedContentInset.top > row.minY {
            // Following the end would scroll away the row the reader opened to read.
            return setPinned(false)
        }
        if abs(collectionView.contentOffset.y - target) > 0.5 {
            autoScroll { collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false) }
        }
    }

    /// VoiceOver is reading a message other than the last: pulling the end into view would
    /// scroll it away from under the reader.
    private var readerIsElsewhere: Bool {
        guard UIAccessibility.isVoiceOverRunning,
              let focused = UIAccessibility.focusedElement(using: .notificationVoiceOver) as? UIView,
              focused.isDescendant(of: collectionView) else { return false }
        var view: UIView? = focused
        while let current = view, !(current is UICollectionViewCell) { view = current.superview }
        guard let cell = view as? UICollectionViewCell, let path = collectionView.indexPath(for: cell),
              case let .message(id)? = dataSource.itemIdentifier(for: path) else { return false }
        return id != order.last
    }

    /// Runs `body`, which moves the transcript, without the move reading as the reader's.
    func autoScroll(_ body: () -> Void) {
        let was = isAutoScrolling
        isAutoScrolling = true
        body()
        isAutoScrolling = was
    }

    func scrollToBottom(animated: Bool) {
        opening = nil
        setPinned(true)
        collectionView.layoutIfNeeded()
        autoScroll {
            collectionView.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: animated && !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        opening = nil
        onScroll?()
    }

    private func readPinnedFromScroll() {
        setPinned(distanceFromBottom <= 24)
    }

    /// A touch moves the transcript by dragging. VoiceOver moves it without one, by its
    /// three-finger scroll or to show the element it reads, so with VoiceOver on any move
    /// the transcript did not make itself is the reader's too.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        defer { onScroll?() }
        let byTouch = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        guard byTouch || (UIAccessibility.isVoiceOverRunning && !isAutoScrolling) else { return }
        readPinnedFromScroll()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { readPinnedFromScroll() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        readPinnedFromScroll()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        setPinned(false)
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        onScroll?()
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }

    // MARK: Message menus

    /// A long press or a secondary click on a message: copy it, whole or in parts, or select
    /// its text, as Messages offers. The bubble or the reply lifts on its own.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, case let .message(id)? = dataSource.itemIdentifier(for: indexPaths[0]),
              let message = messages[id], let menu = menu(for: message, at: point) else { return nil }
        return UIContextMenuConfiguration(identifier: id.uuidString as NSString, actionProvider: { _ in menu })
    }

    /// The menu for one message; nil for Latch's own notices.
    func menu(for message: ChatMessage, at point: CGPoint = .zero) -> UIMenu? {
        let copy = UIImage(systemName: "doc.on.doc")
        let select = UIAction(title: "Select Text", image: UIImage(systemName: "text.cursor")) { [weak self] _ in
            self?.select(message.id, at: point)
        }
        switch kinds[message.id] ?? Self.kind(of: message) {
        case .user:
            var items: [UIMenuElement] = [UIAction(title: "Copy", image: copy) { [weak self] _ in self?.pasteboard.string = message.text }]
            if !message.text.isEmpty { items.append(select) }
            return UIMenu(children: items)
        case .assistant:
            let blocks = cache.blocks(for: message.id, text: message.text, traits: collectionView.traitCollection)
            let content = MarkdownContentView()
            content.show(blocks, renderer: MarkdownRenderer(traits: collectionView.traitCollection))
            let plain = content.plainText
            let main: [UIMenuElement] = [
                UIAction(title: "Copy", image: copy) { [weak self] _ in self?.pasteboard.string = plain },
                UIAction(title: "Copy as Markdown", image: UIImage(systemName: "text.document")) { [weak self] _ in
                    self?.pasteboard.string = message.text
                },
                select,
            ]
            let code = content.codeBlocks
            // The first four blocks, numbered, with the fence's language under the number as
            // it was written; more would crowd out the rest. Select Text reaches the others.
            let codeItems = code.prefix(4).enumerated().map { index, block in
                let item = UIAction(title: code.count == 1 ? "Copy Code" : "Copy Code \(index + 1)",
                                    image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { [weak self] _ in
                    self?.pasteboard.string = block.code
                }
                if code.count > 1 { item.subtitle = block.language }
                return item
            }
            let linkItems = content.links.prefix(3).map { link in
                UIAction(title: "Open \(link.title)", image: UIImage(systemName: "safari")) { [weak self] _ in self?.openURL(link.url) }
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: main)]
                + (codeItems.isEmpty ? [] : [UIMenu(options: .displayInline, children: codeItems)])
                + (linkItems.isEmpty ? [] : [UIMenu(options: .displayInline, children: linkItems)]))
        case .tool:
            let tool = ToolCallPresentation(message)
            var items: [UIMenuElement] = [
                UIAction(title: tool.isCommand ? "Copy Command" : "Copy Title", image: copy) { [weak self] _ in
                    self?.pasteboard.string = tool.displayTitle
                },
            ]
            if !tool.details.isEmpty {
                items.append(UIAction(title: "Copy Details", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                    self?.pasteboard.string = ToolCallPresentation.displayedDetails(tool.details)
                })
            }
            return UIMenu(children: items)
        case .thought:
            var items: [UIMenuElement] = [UIAction(title: "Copy", image: copy) { [weak self] _ in self?.pasteboard.string = message.text }]
            if expanded.contains(message.id) { items.append(select) }
            return UIMenu(children: items)
        case .notice:
            return nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        preview(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        preview(at: indexPath)
    }

    /// The bubble alone on its own corners, a reply or a tool row on a panel of the page's
    /// colour; the rest of the row stays behind.
    private func preview(at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath), cell.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        let view: UIView
        switch cell {
        case let user as UserMessageCell where !user.bubble.isHidden:
            view = user.bubble
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 18)
        case let reply as AssistantMessageCell:
            view = reply.markdown
            parameters.backgroundColor = .systemBackground
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds.insetBy(dx: -10, dy: -8), cornerRadius: 12)
        case let row as DisclosureCell:
            view = row.header
            parameters.backgroundColor = .systemBackground
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds.insetBy(dx: -8, dy: 0), cornerRadius: 12)
        default:
            return nil
        }
        return UITargetedPreview(view: view, parameters: parameters)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration,
                        animator: (any UIContextMenuInteractionAnimating)?) {
        menuShowing = true
    }

    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: (any UIContextMenuInteractionAnimating)?) {
        guard let animator else {
            menuShowing = false
            return performPendingSelection()
        }
        animator.addCompletion { [weak self] in
            self?.menuShowing = false
            self?.performPendingSelection()
        }
    }

    /// Select Text: after the menu has gone, since the row is hidden under its preview until then.
    func select(_ id: UUID, at point: CGPoint) {
        pendingSelection = (id, point)
        if !menuShowing { performPendingSelection() }
    }

    private func performPendingSelection() {
        guard let (id, point) = pendingSelection else { return }
        pendingSelection = nil
        guard let path = dataSource.indexPath(for: .message(id)),
              let cell = collectionView.cellForItem(at: path) as? TranscriptCell else { return }
        cell.beginSelecting(near: cell.convert(point, from: collectionView))
    }

    // MARK: VoiceOver rotors

    /// Turn by turn through a long conversation: the user's messages, the agent's replies, what
    /// it thought, its tool calls, and replies with code. Rows under a collapsed subagent are
    /// passed over, as they are on screen.
    private func makeRotors() -> [UIAccessibilityCustomRotor] {
        let rotors: [(String, (ChatMessage, ChatMessageKind) -> Bool)] = [
            ("Your Messages", { _, kind in kind == .user }),
            ("Replies", { _, kind in kind == .assistant }),
            ("Thinking", { _, kind in kind == .thought }),
            ("Tool Calls", { _, kind in kind == .tool }),
            ("Code", { message, kind in kind == .assistant && message.text.contains("```") }),
        ]
        return rotors.map { name, matches in
            UIAccessibilityCustomRotor(name: name) { [weak self] predicate in
                self?.rotorResult(predicate, matches: matches)
            }
        }
    }

    private func rotorResult(_ predicate: UIAccessibilityCustomRotorSearchPredicate,
                             matches: (ChatMessage, ChatMessageKind) -> Bool) -> UIAccessibilityCustomRotorItemResult? {
        let forward = predicate.searchDirection == .next
        var current: Int?
        if var view = predicate.currentItem.targetElement as? UIView {
            while !(view is UICollectionViewCell), let parent = view.superview { view = parent }
            if let cell = view as? UICollectionViewCell, let path = collectionView.indexPath(for: cell),
               case let .message(id)? = dataSource.itemIdentifier(for: path) {
                current = order.firstIndex(of: id)
            }
        }
        let indices: [Int] = forward
            ? Array(((current.map { $0 + 1 } ?? 0)..<max(order.count, 0)))
            : Array((0..<(current ?? order.count)).reversed())
        for index in indices {
            let id = order[index]
            guard let message = messages[id], let kind = kinds[id], matches(message, kind),
                  let path = dataSource.indexPath(for: .message(id)) else { continue }
            if index != order.count - 1 { setPinned(false) }
            autoScroll {
                collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
                collectionView.layoutIfNeeded()
            }
            guard let cell = collectionView.cellForItem(at: path) else { return nil }
            let target: NSObject = (cell as? DisclosureCell)?.header ?? cell
            return UIAccessibilityCustomRotorItemResult(targetElement: target, targetRange: nil)
        }
        return nil
    }
}
