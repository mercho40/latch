import LatchRemoteProtocol
import LatchSessionKit
import UIKit

/// The primary column: every session on every server, a section per server, newest first.
/// Under each server, "On <server>" lists what it runs that this device has no session for,
/// to take up with a tap. With no server added it explains how to pair one.
final class SessionsViewController: UICollectionViewController {
    enum Section: Hashable {
        case problem
        case server(UUID)
        /// Sessions whose server was removed from Servers.
        case removedServer
    }

    enum Item: Hashable {
        case problem
        case session(UUID)
        case newSession(serverID: UUID)
        case runtimes(serverID: UUID)
        case runtime(serverID: UUID, runtimeID: String)
        case unreachable(serverID: UUID)
    }

    var onAddServer: (() -> Void)?
    /// New Session, on the given server when it came from that server's section.
    var onNewSession: ((UUID?) -> Void)?
    var onShowServers: (() -> Void)?
    var onServerSettings: ((UUID) -> Void)?
    var onOpen: ((PhoneSession) -> Void)?
    /// Asks whether to go ahead with Remove or Stop Agent; calls back only to go ahead.
    var confirm: (@MainActor (Confirmation, @escaping () -> Void) -> Void)?

    enum Confirmation: Equatable {
        /// Only the first time: after that the user knows the agent runs on.
        case remove(sessionTitle: String, serverName: String)
        case stop(sessionTitle: String, serverName: String)
    }

    let library: SessionLibrary
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var expanded: Set<UUID> = []
    private var ticker: Timer?
    private var clock: Timer?
    private let defaults: UserDefaults
    static let removalExplainedKey = "RemoveSessionExplained"

    init(library: SessionLibrary, defaults: UserDefaults = .standard) {
        self.library = library
        self.defaults = defaults
        super.init(collectionViewLayout: UICollectionViewLayout())
        title = "Sessions"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        ticker?.invalidate()
        clock?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.collectionViewLayout = makeLayout()
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        let newSession = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in
            self?.onNewSession?(nil)
        })
        newSession.accessibilityLabel = "New Session"
        let servers = UIBarButtonItem(image: UIImage(systemName: "server.rack"), primaryAction: UIAction { [weak self] _ in
            self?.onShowServers?()
        })
        servers.accessibilityLabel = "Servers"
        navigationItem.rightBarButtonItems = [newSession]
        navigationItem.leftBarButtonItems = [servers]
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            guard let self else { return }
            Task {
                (self.library.connector as? ChannelRemoteSessionConnector)?.probeAll()
                await self.library.refreshRuntimes()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        configureDataSource()
        reload(animated: false)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.reconfigureSessions { _ in true }
        }
        clock = Self.repeating(every: 30) { [weak self] in self?.reconfigureSessions { _ in true } }
    }

    override func viewWillAppear(_ animated: Bool) {
        // A sidebar keeps its selection beside the session it shows.
        clearsSelectionOnViewWillAppear = splitViewController?.isCollapsed ?? true
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await library.refreshRuntimes() }
    }

    func addServer() { onAddServer?() }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            // A sidebar beside the session on iPad; grouped rows when the list fills the screen.
            let sidebar = environment.traitCollection.userInterfaceIdiom == .pad
            var configuration = UICollectionLayoutListConfiguration(appearance: sidebar ? .sidebar : .insetGrouped)
            let section = self?.dataSource?.sectionIdentifier(for: index)
            configuration.headerMode = section == .problem ? .none : .supplementary
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            return .list(using: configuration, layoutEnvironment: environment)
        }
    }

    // MARK: Data

    private func configureDataSource() {
        let sessionCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
            guard let self, let session = self.library.session(id: id) else { return }
            self.configure(cell, for: session)
        }
        let newSessionCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { cell, _, _ in
            var content = cell.defaultContentConfiguration()
            content.text = "New Session"
            content.image = UIImage(systemName: "plus.circle.fill")
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessories = []
        }
        let runtimesCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, serverID in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            content.text = "On \(self.serverName(serverID))"
            content.secondaryText = String(self.library.adoptableRuntimes(on: serverID).count)
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure(options: .init(style: .cell))]
            cell.accessibilityHint = "Agents running on \(self.serverName(serverID)) with no session on this device."
        }
        let runtimeCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, case let .runtime(serverID, runtimeID) = item,
                  let runtime = self.library.adoptableRuntimes(on: serverID).first(where: { $0.runtimeID.rawValue == runtimeID })
            else { return }
            self.configure(cell, for: runtime)
        }
        let unreachableCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, serverID in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Can’t reach \(self.serverName(serverID))"
            content.secondaryText = self.library.runtimes[serverID]?.failure
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.textProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
        }
        let problemCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            var content = cell.defaultContentConfiguration()
            content.text = [self.library.servers.problem, self.library.persistenceError].compactMap { $0 }.joined(separator: "\n\n")
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            cell.contentConfiguration = content
            cell.accessories = self.library.servers.problem == nil ? [] : [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .problem: collectionView.dequeueConfiguredReusableCell(using: problemCell, for: indexPath, item: item)
            case let .session(id): collectionView.dequeueConfiguredReusableCell(using: sessionCell, for: indexPath, item: id)
            case let .newSession(serverID):
                collectionView.dequeueConfiguredReusableCell(using: newSessionCell, for: indexPath, item: serverID)
            case let .runtimes(serverID):
                collectionView.dequeueConfiguredReusableCell(using: runtimesCell, for: indexPath, item: serverID)
            case .runtime: collectionView.dequeueConfiguredReusableCell(using: runtimeCell, for: indexPath, item: item)
            case let .unreachable(serverID):
                collectionView.dequeueConfiguredReusableCell(using: unreachableCell, for: indexPath, item: serverID)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            self.configure(header, for: section)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        dataSource.sectionSnapshotHandlers.willExpandItem = { [weak self] item in
            if case let .runtimes(serverID) = item { self?.expanded.insert(serverID) }
        }
        dataSource.sectionSnapshotHandlers.willCollapseItem = { [weak self] item in
            if case let .runtimes(serverID) = item { self?.expanded.remove(serverID) }
        }
    }

    /// The sections and rows as the library has them now.
    func reload(animated: Bool = true) {
        guard let dataSource else { return }
        var sections: [(Section, NSDiffableDataSourceSectionSnapshot<Item>)] = []
        if library.servers.problem != nil || library.persistenceError != nil {
            var problem = NSDiffableDataSourceSectionSnapshot<Item>()
            problem.append([.problem])
            sections.append((.problem, problem))
        }
        for server in library.servers.servers {
            var snapshot = NSDiffableDataSourceSectionSnapshot<Item>()
            let sessions = library.sessions(on: server.id)
            snapshot.append(sessions.isEmpty ? [.newSession(serverID: server.id)] : sessions.map { .session($0.id) })
            let runtimes = library.adoptableRuntimes(on: server.id)
            if !runtimes.isEmpty {
                let group = Item.runtimes(serverID: server.id)
                snapshot.append([group])
                snapshot.append(runtimes.map { .runtime(serverID: server.id, runtimeID: $0.runtimeID.rawValue) }, to: group)
                if expanded.contains(server.id) { snapshot.expand([group]) }
            }
            if library.runtimes[server.id]?.failure != nil { snapshot.append([.unreachable(serverID: server.id)]) }
            sections.append((.server(server.id), snapshot))
        }
        let orphans = library.orphanedSessions
        if !orphans.isEmpty {
            var snapshot = NSDiffableDataSourceSectionSnapshot<Item>()
            snapshot.append(orphans.map { .session($0.id) })
            sections.append((.removedServer, snapshot))
        }
        let identifiers = sections.map(\.0)
        if dataSource.snapshot().sectionIdentifiers != identifiers {
            var main = NSDiffableDataSourceSnapshot<Section, Item>()
            main.appendSections(identifiers)
            dataSource.apply(main, animatingDifferences: false)
        }
        for (section, snapshot) in sections {
            dataSource.apply(snapshot, to: section, animatingDifferences: animated && view.window != nil)
        }
        // Headers show names and counts that a reload of the rows does not redraw.
        var all = dataSource.snapshot()
        all.reconfigureItems(all.itemIdentifiers)
        dataSource.apply(all, animatingDifferences: false)
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            if let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell,
               let section = dataSource.sectionIdentifier(for: indexPath.section) {
                configure(header, for: section)
            }
        }
        updateEmptyState()
        updateTicker()
        selectShownSession()
        navigationItem.rightBarButtonItems?.first?.isEnabled = !library.servers.servers.isEmpty
    }

    /// Redraws the rows of the sessions that `include` picks, without moving any.
    func reconfigureSessions(_ include: (PhoneSession) -> Bool) {
        guard let dataSource else { return }
        var snapshot = dataSource.snapshot()
        let items = library.sessions.filter(include).map { Item.session($0.id) }.filter { snapshot.indexOfItem($0) != nil }
        guard !items.isEmpty else { return }
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// One session changed: its row, and its place if its last activity moved it.
    func sessionChanged(_ session: PhoneSession) {
        guard isViewLoaded else { return }
        let order = library.sessions(on: session.serverID).map(\.id)
        let shown = dataSource.snapshot(for: .server(session.serverID)).rootItems.compactMap { item -> UUID? in
            if case let .session(id) = item { return id }
            return nil
        }
        if order != shown { reload() } else { reconfigureSessions { $0 === session } }
        updateTicker()
    }

    private func updateEmptyState() {
        if library.servers.servers.isEmpty, library.sessions.isEmpty, library.servers.problem == nil {
            contentUnavailableConfiguration = Self.noServers { [weak self] in self?.addServer() }
        } else if library.sessions.isEmpty, library.servers.problem == nil,
                  library.servers.servers.allSatisfy({ library.adoptableRuntimes(on: $0.id).isEmpty }) {
            contentUnavailableConfiguration = Self.noSessions { [weak self] in self?.onNewSession?(nil) }
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    static func noServers(addServer: @escaping () -> Void) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "server.rack")
        configuration.text = "No servers yet"
        configuration.secondaryAttributedText = pairingInstructions
        var button = UIButton.Configuration.filled()
        button.title = "Add Server"
        configuration.button = button
        configuration.buttonProperties.primaryAction = UIAction { _ in addServer() }
        return configuration
    }

    /// The pairing command on a line of its own, monospaced, and joined so a narrow column
    /// wraps it only between "pair" and "--host <name>": word joiners after its hyphens.
    static var pairingInstructions: NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: UIColor.secondaryLabel,
                                                     .paragraphStyle: paragraph]
        let command = "latch-server\u{00A0}pair --host\u{00A0}<name>".replacingOccurrences(of: "-", with: "-\u{2060}")
        let text = NSMutableAttributedString(string: "On the machine your agents run on, run:\n", attributes: plain)
        text.append(NSAttributedString(string: command + "\n", attributes: [
            .font: ChromeFont.monospaced(.callout), .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
            .accessibilitySpeechPunctuation: true]))
        text.append(NSAttributedString(string: "Then add the server it prints.", attributes: plain))
        return text
    }

    static func noSessions(newSession: @escaping () -> Void) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "text.bubble")
        configuration.text = "No sessions yet"
        configuration.secondaryText = "Start an agent in a folder on one of your servers. Agents started from another device show up here too."
        var button = UIButton.Configuration.filled()
        button.title = "New Session"
        configuration.button = button
        configuration.buttonProperties.primaryAction = UIAction { _ in newSession() }
        return configuration
    }

    private func serverName(_ id: UUID) -> String { library.servers.server(id: id)?.name ?? "Removed server" }

    // MARK: Cells

    private var isSidebar: Bool { traitCollection.userInterfaceIdiom == .pad }

    private func configure(_ cell: UICollectionViewListCell, for session: PhoneSession) {
        let status = session.rowStatus(now: library.now())
        // At accessibility sizes the slot goes under the subtitle, so the title keeps the width.
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        var content = UIListContentConfiguration.subtitleCell()
        content.text = session.title
        // An unread reply is the one row state worth reading from across the list.
        content.textProperties.font = status.mark == .unread
            ? ChromeFont.preferred(.body, weight: .semibold) : .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = stacked ? 0 : 1
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = stacked ? 0 : 1
        // A sidebar is too narrow for words beside the title: they lead the subtitle, as the
        // Mac's sidebar puts its status there, and only the mark stays at the end.
        let wordsInSubtitle = isSidebar && !stacked && status.isWords
        if stacked {
            content.secondaryAttributedText = Self.detail(session.subtitle, status, stacked: true)
        } else if wordsInSubtitle {
            content.secondaryAttributedText = Self.detail(session.subtitle, status, stacked: false)
        } else {
            content.secondaryText = session.subtitle
        }
        content.textToSecondaryTextVerticalPadding = 2
        content.directionalLayoutMargins.top = 10
        content.directionalLayoutMargins.bottom = 10
        cell.contentConfiguration = content
        let slot = SessionStatusView(status: wordsInSubtitle
            ? SessionRowStatus(mark: status.mark, text: "", spoken: status.spoken) : status)
        cell.accessories = stacked ? [] : [.customView(configuration: .init(customView: slot, placement: .trailing(),
                                                                          reservedLayoutWidth: .actual,
                                                                          maintainsFixedSize: false))]
        cell.accessibilityLabel = session.title
        cell.accessibilityValue = [session.subtitle, status.spoken].filter { !$0.isEmpty }.joined(separator: ", ")
        cell.accessibilityCustomActions = customActions(for: session)
        cell.configurationUpdateHandler = { [weak slot] cell, state in
            // Where selection fills the row with the tint and turns its title white, the subtitle
            // and the slot follow: their own colours would sink into the tint.
            var updated = content.updated(for: state)
            let text = updated.textProperties.resolvedColor().resolvedColor(with: cell.traitCollection)
            var white: CGFloat = 0
            var alpha: CGFloat = 0
            let onTint = state.isSelected && text.getWhite(&white, alpha: &alpha) && white > 0.99
            slot?.isOnTint = onTint
            if onTint {
                let subdued = UIColor.white.withAlphaComponent(0.8)
                if let detail = updated.secondaryAttributedText {
                    let recoloured = NSMutableAttributedString(attributedString: detail)
                    recoloured.addAttribute(.foregroundColor, value: subdued, range: NSRange(location: 0, length: recoloured.length))
                    updated.secondaryAttributedText = recoloured
                } else {
                    updated.secondaryTextProperties.color = subdued
                }
            }
            cell.contentConfiguration = updated
        }
    }

    /// The subtitle with the status's words: ahead of it on one line in a sidebar, or on a line
    /// of their own under it at accessibility sizes, where the mark comes too. A decision or a
    /// failure reads in the label's colour at semibold, the rest in the subtitle's.
    private static func detail(_ subtitle: String, _ status: SessionRowStatus, stacked: Bool) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let secondary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        let urgent = status.mark == .waiting || status.mark == .failed
        let words = status.mark == .working && !status.text.hasSuffix("…") ? "Working · \(status.text)" : status.text
        let wordsRun = NSAttributedString(string: words, attributes: urgent
            ? [.font: ChromeFont.preferred(.subheadline, weight: .semibold), .foregroundColor: UIColor.label] : secondary)
        let text = NSMutableAttributedString()
        guard stacked else {
            text.append(wordsRun)
            text.append(NSAttributedString(string: " · \(subtitle)", attributes: secondary))
            return text
        }
        text.append(NSAttributedString(string: subtitle, attributes: secondary))
        guard !words.isEmpty else { return text }
        text.append(NSAttributedString(string: "\n"))
        if let (symbol, color) = SessionStatusView.mark(for: status.mark),
           let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image.withTintColor(color, renderingMode: .alwaysOriginal))))
            text.append(NSAttributedString(string: " "))
        }
        text.append(wordsRun)
        return text
    }

    /// A runtime another device started: its folder, its agent, and what it is doing. The
    /// whole path is in its VoiceOver value and its context menu.
    private func configure(_ cell: UICollectionViewListCell, for runtime: LatchRemoteRuntimeSummary) {
        var content = UIListContentConfiguration.subtitleCell()
        let folder = WorkspaceLocation.remote(serverID: UUID(), path: runtime.workspace).folderName
        content.text = folder
        content.secondaryText = runtime.agentTitle
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.textToSecondaryTextVerticalPadding = 2
        cell.contentConfiguration = content
        var accessories: [UICellAccessory] = []
        let state: SessionRowStatus? = if runtime.pendingPermissionCount > 0 {
            SessionRowStatus(mark: .waiting, text: "Needs approval", spoken: "Needs approval")
        } else if runtime.activeTurnID != nil {
            SessionRowStatus(mark: .working, text: "Working", spoken: "Working")
        } else { nil }
        if let state {
            accessories.append(.customView(configuration: .init(customView: SessionStatusView(status: state),
                                                                placement: .trailing(), reservedLayoutWidth: .actual)))
        }
        accessories.append(.disclosureIndicator())
        cell.accessories = accessories
        cell.accessibilityLabel = "\(folder), \(runtime.agentTitle)"
        cell.accessibilityValue = [state?.spoken, runtime.workspace].compactMap { $0 }.joined(separator: ", ")
        cell.accessibilityHint = "Opens this agent’s session on this device."
    }

    private func configure(_ header: UICollectionViewListCell, for section: Section) {
        var content = isSidebar ? UIListContentConfiguration.header() : UIListContentConfiguration.prominentInsetGroupedHeader()
        switch section {
        case .problem:
            header.contentConfiguration = content
            header.accessories = []
        case .removedServer:
            content.text = "Removed Server"
            header.contentConfiguration = content
            header.accessories = []
        case let .server(id):
            content.text = serverName(id)
            // Whether the server answered the last time it was asked for its runtimes.
            let (color, spoken): (UIColor, String?) = switch library.runtimes[id] {
            case let listing? where listing.failure != nil: (.systemRed, "Can’t connect")
            case let listing? where listing.answered: (.systemGreen, "Connected")
            default: (.tertiaryLabel, nil)
            }
            content.image = UIImage(systemName: "circle.fill")
            content.imageProperties.tintColor = color
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 8)
            content.imageProperties.reservedLayoutSize = CGSize(width: 8, height: 8)
            content.imageToTextPadding = 6
            header.contentConfiguration = content
            header.accessibilityLabel = serverName(id)
            header.accessibilityValue = spoken
            let button = UIButton(configuration: .plain())
            button.configuration?.image = UIImage(systemName: "ellipsis.circle")
            button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
            button.configuration?.contentInsets = .zero
            button.menu = serverMenu(id)
            button.showsMenuAsPrimaryAction = true
            button.accessibilityLabel = "\(serverName(id)) Actions"
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            header.accessories = [.customView(configuration: .init(customView: button, placement: .trailing()))]
        }
    }

    private func serverMenu(_ id: UUID) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "New Session", image: UIImage(systemName: "plus")) { [weak self] _ in self?.onNewSession?(id) },
            UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                guard let self else { return }
                Task { await self.library.refreshRuntimes(for: [id]) }
            },
            UIAction(title: "Server Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.onServerSettings?(id)
            },
        ])
    }

    // MARK: Actions

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .unreachable?, nil: false
        case .problem?: library.servers.problem != nil
        default: true
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case let .session(id):
            if let session = library.session(id: id) { onOpen?(session) }
            return
        case let .newSession(serverID): onNewSession?(serverID)
        case let .runtimes(serverID):
            var snapshot = dataSource.snapshot(for: .server(serverID))
            // Applied here rather than by the disclosure, so the expansion handlers do not hear of it.
            if snapshot.isExpanded(item) {
                snapshot.collapse([item])
                expanded.remove(serverID)
            } else {
                snapshot.expand([item])
                expanded.insert(serverID)
            }
            dataSource.apply(snapshot, to: .server(serverID))
        case let .runtime(serverID, runtimeID):
            // A row a moment out of date opens the session that took the runtime up.
            guard let runtime = library.runtimes[serverID]?.runtimes.first(where: { $0.runtimeID.rawValue == runtimeID })
            else { break }
            onOpen?(library.adopt(runtime, serverID: serverID))
            return
        case .problem: onShowServers?()
        case .unreachable: break
        }
        collectionView.deselectItem(at: indexPath, animated: true)
    }

    /// Opens a server's "On <server>" group, as tapping it does.
    func expandRuntimes(on serverID: UUID) {
        let item = Item.runtimes(serverID: serverID)
        var snapshot = dataSource.snapshot(for: .server(serverID))
        guard snapshot.contains(item), !snapshot.isExpanded(item) else { return }
        snapshot.expand([item])
        expanded.insert(serverID)
        dataSource.apply(snapshot, to: .server(serverID))
    }

    /// The shown session stays selected in a sidebar.
    func selectShownSession() {
        guard let dataSource, splitViewController?.isCollapsed == false,
              let id = library.selectedSessionID, let indexPath = dataSource.indexPath(for: .session(id)) else { return }
        guard collectionView.indexPathsForSelectedItems != [indexPath] else { return }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case let .session(id)? = dataSource.itemIdentifier(for: indexPath), let session = library.session(id: id)
        else { return nil }
        // A swipe that only asks reports nothing done, so the row slides back and the alert decides.
        let remove = UIContextualAction(style: .normal, title: "Remove") { [weak self] _, _, done in
            guard let self else { return done(false) }
            done(!self.remove(session))
        }
        remove.image = UIImage(systemName: "minus.circle")
        remove.backgroundColor = .systemGray
        var actions = [remove]
        if session.canStop {
            let stop = UIContextualAction(style: .destructive, title: "Stop Agent") { [weak self] _, _, done in
                self?.stop(session)
                done(false)
            }
            stop.image = UIImage(systemName: "stop.circle")
            actions.append(stop)
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    /// "Remove from iPhone": what goes is this device's copy, not the agent.
    static var removeTitle: String { "Remove from \(UIDevice.current.model)" }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                                 point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1 else { return nil }
        if case let .runtime(serverID, runtimeID)? = dataSource.itemIdentifier(for: indexPaths[0]),
           let runtime = library.runtimes[serverID]?.runtimes.first(where: { $0.runtimeID.rawValue == runtimeID }) {
            return UIContextMenuConfiguration(actionProvider: { _ in
                UIMenu(children: [UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = runtime.workspace
                }])
            })
        }
        guard case let .session(id)? = dataSource.itemIdentifier(for: indexPaths[0]),
              let session = library.session(id: id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = session.path
                },
                UIAction(title: Self.removeTitle, image: UIImage(systemName: "minus.circle")) { [weak self] _ in
                    self?.remove(session)
                },
            ]
            if session.canStop {
                actions.append(UIAction(title: "Stop Agent", image: UIImage(systemName: "stop.circle"),
                                        attributes: .destructive) { [weak self] _ in self?.stop(session) })
            }
            return UIMenu(children: actions)
        })
    }

    func customActions(for session: PhoneSession) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if session.needsApproval {
            // The decision is made on the session's screen, where the request shows whole.
            actions.append(UIAccessibilityCustomAction(name: "Review Request…") { [weak self] _ in
                self?.onOpen?(session)
                return true
            })
        }
        actions.append(UIAccessibilityCustomAction(name: Self.removeTitle) { [weak self] _ in
            self?.remove(session)
            return true
        })
        if session.canStop {
            actions.append(UIAccessibilityCustomAction(name: "Stop Agent") { [weak self] _ in
                self?.stop(session)
                return true
            })
        }
        return actions
    }

    /// Detaches and forgets the session here. The first time, it says the agent keeps running.
    /// Returns whether it asked rather than removing.
    @discardableResult
    func remove(_ session: PhoneSession) -> Bool {
        let go = { [weak self] in
            guard let self else { return }
            self.defaults.set(true, forKey: Self.removalExplainedKey)
            Task { await self.library.remove(session) }
        }
        guard !defaults.bool(forKey: Self.removalExplainedKey), let confirm else {
            go()
            return false
        }
        confirm(.remove(sessionTitle: session.title, serverName: serverName(session.serverID)), go)
        return true
    }

    func stop(_ session: PhoneSession) {
        let go = { [weak self] in
            guard let self else { return }
            Task { await self.library.stop(session) }
        }
        guard let confirm else { return go() }
        confirm(.stop(sessionTitle: session.title, serverName: serverName(session.serverID)), go)
    }

    // MARK: Time

    private func updateTicker() {
        let working = library.sessions.contains { $0.model.phase == .prompting }
        if working, ticker == nil {
            ticker = Self.repeating(every: 1) { [weak self] in
                self?.reconfigureSessions { $0.model.phase == .prompting }
            }
        } else if !working {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// In the common modes, so times move while the list scrolls; tolerance lets the system
    /// batch the wakeups.
    private static func repeating(every interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { body() } }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// The status slot: a mark and a few words, or how long ago the session was active.
final class SessionStatusView: UIView {
    let status: SessionRowStatus
    let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let mark = UIImageView()

    /// Selected in a sidebar, over the tint.
    var isOnTint = false {
        didSet { if isOnTint != oldValue { applyColors() } }
    }

    init(status: SessionRowStatus) {
        self.status = status
        super.init(frame: .zero)
        label.text = status.text
        label.font = status.mark == .waiting ? ChromeFont.preferred(.subheadline, weight: .semibold) : ChromeFont.digits(.subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        mark.setContentHuggingPriority(.required, for: .horizontal)
        spinner.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        let stack = UIStackView(arrangedSubviews: [spinner, mark, label])
        stack.spacing = 5
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        spinner.isHidden = status.mark != .working
        if status.mark == .working { spinner.startAnimating() }
        if let (symbol, _) = Self.mark(for: status.mark) {
            mark.image = UIImage(systemName: symbol)
            if status.mark == .unread { mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9) }
        } else {
            mark.isHidden = true
        }
        label.isHidden = status.text.isEmpty
        isAccessibilityElement = false
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The symbol and colour of a mark, as the Mac's sidebar draws them: an orange decision
    /// stands apart from the tint of an unread reply and of every control.
    static func mark(for mark: SessionRowStatus.Mark) -> (symbol: String, color: UIColor)? {
        switch mark {
        case .waiting: ("exclamationmark.circle.fill", .systemOrange)
        case .failed: ("exclamationmark.triangle.fill", .systemRed)
        case .unread: ("circle.fill", .tintColor)
        case .working, .none: nil
        }
    }

    private func applyColors() {
        // Orange words would be faint on white: a decision's are the label's colour, in semibold.
        let textColor: UIColor = status.mark == .waiting ? .label : .secondaryLabel
        mark.tintColor = isOnTint ? .white : Self.mark(for: status.mark)?.color ?? .secondaryLabel
        label.textColor = isOnTint ? .white : textColor
        spinner.color = isOnTint ? .white : .secondaryLabel
    }
}
