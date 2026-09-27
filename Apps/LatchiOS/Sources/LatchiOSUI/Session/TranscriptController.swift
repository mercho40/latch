import LatchSessionKit
import UIKit

/// Tells its owner after each layout pass, which is when a pinned transcript keeps its end in view.
final class TranscriptCollectionView: UICollectionView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// The conversation: one list row per message, keyed by the message's ID, so a streaming
/// update reconfigures the one row whose text changed and leaves the rest alone. While the
/// reader is at the end it stays there as the answer grows; once they scroll up it stays put,
/// and `onScroll` lets the screen offer a way back.
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
    /// Whether the transcript follows its end. Only the reader's own scrolling changes it.
    private(set) var isPinned = true
    /// After any scroll, a change of pinning, or an update, all of which can change how far
    /// the end is out of view.
    var onScroll: (() -> Void)?

    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var messages: [UUID: ChatMessage] = [:]
    private var kinds: [UUID: ChatMessageKind] = [:]
    private(set) var order: [UUID] = []
    private(set) var expanded: Set<UUID> = []
    private var isWorking = false
    private var lastContentHeight: CGFloat = 0

    override init() {
        weak var host: UICollectionView?
        let layout = UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            // The readable width, capped: the ordinary margins on iPhone, a centred column on
            // iPad, lined up with the banner and the composer.
            var leading: CGFloat = 16
            var trailing: CGFloat = 16
            if let host, host.bounds.width > 0 {
                let readable = host.readableContentGuide.layoutFrame
                let centred = (host.bounds.width - TranscriptController.maximumColumnWidth) / 2
                leading = max(16, readable.minX - host.bounds.minX, centred)
                trailing = max(16, host.bounds.maxX - readable.maxX, centred)
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
        configureDataSource()
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
            toggle: { [weak self] in self?.toggle($0) })
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
        let notice = UICollectionView.CellRegistration<NoticeCell, UUID> { [weak self] cell, _, id in
            guard let self, let message = messages[id] else { return }
            cell.configure(message, context: context)
        }
        let working = UICollectionView.CellRegistration<WorkingCell, Item> { _, _, _ in }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, path, item in
            guard case let .message(id) = item else {
                return view.dequeueConfiguredReusableCell(using: working, for: path, item: item)
            }
            switch self?.kinds[id] ?? .assistant {
            case .user: return view.dequeueConfiguredReusableCell(using: user, for: path, item: id)
            case .assistant: return view.dequeueConfiguredReusableCell(using: assistant, for: path, item: id)
            case .tool: return view.dequeueConfiguredReusableCell(using: tool, for: path, item: id)
            case .notice: return view.dequeueConfiguredReusableCell(using: notice, for: path, item: id)
            }
        }
    }

    static func kind(of message: ChatMessage) -> ChatMessageKind {
        switch message.role {
        case .user: .user
        case .tool: .tool
        case .assistant: ChatMessageKind.isNotice(message.text) ? .notice : .assistant
        }
    }

    /// Takes the model's messages as they are now. Rows whose message changed are
    /// reconfigured in place; a row whose kind changed is rebuilt.
    func update(messages newMessages: [ChatMessage], isWorking working: Bool) {
        var seen = Set<UUID>()
        let retained = newMessages.filter { seen.insert($0.id).inserted }
        var changed: [Item] = []
        var rebuilt: [Item] = []
        var nextMessages: [UUID: ChatMessage] = [:]
        var nextKinds: [UUID: ChatMessageKind] = [:]
        for message in retained {
            let kind = Self.kind(of: message)
            nextMessages[message.id] = message
            nextKinds[message.id] = kind
            guard let old = messages[message.id] else { continue }
            if kinds[message.id] != kind { rebuilt.append(.message(message.id)) }
            else if old != message { changed.append(.message(message.id)) }
        }
        let nextOrder = retained.map(\.id)
        guard nextOrder != order || working != isWorking || !changed.isEmpty || !rebuilt.isEmpty else { return }
        let inserted = nextOrder.count > order.count
        messages = nextMessages
        kinds = nextKinds
        order = nextOrder
        isWorking = working
        expanded.formIntersection(seen)
        cache.keep(seen)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(nextOrder.map(Item.message))
        if working { snapshot.appendItems([.working]) }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(changed.filter(existing.contains))
        snapshot.reloadItems(rebuilt.filter(existing.contains))
        // New rows fade in; a streaming update never animates.
        let animate = inserted && !UIAccessibility.isReduceMotionEnabled && collectionView.window != nil && !existing.isEmpty
        dataSource.apply(snapshot, animatingDifferences: animate) { [weak self] in
            self?.keepPinned()
            self?.onScroll?()
        }
    }

    private func reconfigureAll() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func toggle(_ id: UUID) {
        if expanded.remove(id) == nil { expanded.insert(id) }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.message(id)])
        dataSource.apply(snapshot, animatingDifferences: !UIAccessibility.isReduceMotionEnabled)
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
        guard isPinned, !collectionView.isTracking, !collectionView.isDecelerating else { return }
        let target = bottomOffset
        if abs(collectionView.contentOffset.y - target) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        }
    }

    func scrollToBottom(animated: Bool) {
        setPinned(true)
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        onScroll?()
    }

    private func readPinnedFromScroll() {
        setPinned(distanceFromBottom <= 24)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        defer { onScroll?() }
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
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
}
