import LatchRemoteProtocol
import LatchSessionKit
import UIKit

/// Servers: the `latch-server`s this device runs sessions on, each with whether it answers.
/// Tapping one edits it; Add Server adds one; swiping removes one.
final class ServersViewController: UICollectionViewController {
    enum Item: Hashable {
        case server(UUID)
        /// A saved server whose token is not on this device.
        case missingToken(UUID)
        case add
    }

    enum Check: Equatable {
        case checking
        case reachable(String)
        case failed(String)
    }

    private let store: any PhoneServerStore
    private let check: ServerCheck
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private(set) var checks: [UUID: Check] = [:]
    private var checkTasks: [UUID: Task<Void, Never>] = [:]
    /// What each check ran against, so a server changed since is checked again.
    private var checked: [UUID: ServerProfile] = [:]
    /// Presents the editor; the root wires it so the sheet stacks over this one.
    var onEdit: ((ServerEditorViewController) -> Void)?

    init(store: any PhoneServerStore, check: @escaping ServerCheck) {
        self.store = store
        self.check = check
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: list)
        super.init(collectionViewLayout: layout)
        title = "Servers"
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .serverStoreDidChange, object: store)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.footerMode = .supplementary
        list.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in self?.swipeActions(at: indexPath) }
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout.list(using: list)
        configureDataSource()
        reload()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            var snapshot = self.dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The Keychain is unreadable before the first unlock, and a file moved aside needs no relaunch.
        store.reload()
        reload()
    }

    // MARK: Data

    private func configureDataSource() {
        let serverCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
            guard let self, let server = self.store.server(id: id) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = server.name
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.font = ChromeFont.monospaced(.subheadline)
            content.secondaryTextProperties.color = .secondaryLabel
            // An address is never hyphenated: its middle gives way on one line, and at
            // accessibility sizes it wraps at any character, with the check's words under it
            // rather than a mark beside it, so the address has the row's width.
            let large = self.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            let status = ServerCheckView(self.checks[id])
            if large {
                content.secondaryAttributedText = ServerCheckView.detail(address: server.address, self.checks[id])
                content.secondaryTextProperties.numberOfLines = 0
                content.secondaryTextProperties.lineBreakMode = .byCharWrapping
            } else {
                content.secondaryText = server.address
                content.secondaryTextProperties.numberOfLines = 1
                content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            }
            content.textToSecondaryTextVerticalPadding = 2
            content.directionalLayoutMargins.top = 10
            content.directionalLayoutMargins.bottom = 10
            cell.contentConfiguration = content
            cell.accessories = (large ? [] : [.customView(configuration: .init(customView: status, placement: .trailing(),
                                                                               reservedLayoutWidth: .actual))])
                + [.disclosureIndicator()]
            cell.accessibilityLabel = server.name
            cell.accessibilityValue = [server.address, status.spoken].compactMap { $0 }.joined(separator: ", ")
        }
        let missingCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
            guard let self, let stored = self.store.missingTokens.first(where: { $0.id == id }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = stored.name
            content.secondaryText = "Needs its token again"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "key.slash")
            content.imageProperties.tintColor = .systemOrange
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let addCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = cell.defaultContentConfiguration()
            content.text = "Add Server"
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessories = []
            cell.accessibilityTraits = .button
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case let .server(id): collectionView.dequeueConfiguredReusableCell(using: serverCell, for: indexPath, item: id)
            case let .missingToken(id): collectionView.dequeueConfiguredReusableCell(using: missingCell, for: indexPath, item: id)
            case .add: collectionView.dequeueConfiguredReusableCell(using: addCell, for: indexPath, item: item)
            }
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter) { [weak self] footer, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = self.store.problem ?? "Latch reaches each server over the network or your tailnet. Tap a server to change its address, token or custom agent."
            footer.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func reload() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(store.servers.map { .server($0.id) } + store.missingTokens.map { .missingToken($0.id) })
        if store.fileProblem == nil { snapshot.appendItems([.add]) }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.indexPath(for: $0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        if store.servers.isEmpty, store.missingTokens.isEmpty, store.fileProblem == nil {
            contentUnavailableConfiguration = SessionsViewController.noServers { [weak self] in self?.addServer() }
        } else {
            contentUnavailableConfiguration = nil
        }
        checkServers()
    }

    @objc private func storeChanged() {
        guard isViewLoaded else { return }
        reload()
    }

    /// Checks every server not checked as it is now, all at once.
    private func checkServers() {
        for server in store.servers where checked[server.id] != server {
            checked[server.id] = server
            checkTasks[server.id]?.cancel()
            checks[server.id] = .checking
            let check = check
            let options = server.connectionOptions
            checkTasks[server.id] = Task { [weak self] in
                let result: Check
                do { result = .reachable(ServerCheckText.summary(try await check(options))) }
                catch { result = .failed(ServerCheckText.failure(error)) }
                guard let self, !Task.isCancelled, self.checked[server.id] == server else { return }
                self.checks[server.id] = result
                self.checkTasks[server.id] = nil
                var snapshot = self.dataSource.snapshot()
                guard snapshot.indexOfItem(.server(server.id)) != nil else { return }
                snapshot.reconfigureItems([.server(server.id)])
                await self.dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
        applyChecking()
    }

    private func applyChecking() {
        var snapshot = dataSource.snapshot()
        let checking = store.servers.filter { checks[$0.id] == .checking }.map { Item.server($0.id) }
            .filter { snapshot.indexOfItem($0) != nil }
        guard !checking.isEmpty else { return }
        snapshot.reconfigureItems(checking)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Waits for the checks in flight, for tests.
    func checksFinished() async {
        for task in checkTasks.values { await task.value }
    }

    // MARK: Actions

    func addServer() {
        edit(ServerEditorViewController(store: store, check: check))
    }

    func edit(serverID id: UUID) {
        if let server = store.server(id: id) {
            edit(ServerEditorViewController(store: store, editing: server, check: check))
        } else if let stored = store.missingTokens.first(where: { $0.id == id }) {
            edit(ServerEditorViewController(store: store, restoring: stored, check: check))
        }
    }

    private func edit(_ editor: ServerEditorViewController) {
        if let onEdit { return onEdit(editor) }
        present(ServerEditorViewController.sheet(editor), animated: true)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .server(id)?, let .missingToken(id)?: edit(serverID: id)
        case .add?: addServer()
        case nil: break
        }
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let id: UUID
        let name: String
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .server(server)?:
            guard let profile = store.server(id: server) else { return nil }
            (id, name) = (server, profile.name)
        case let .missingToken(server)?:
            guard let stored = store.missingTokens.first(where: { $0.id == server }) else { return nil }
            (id, name) = (server, stored.name)
        default: return nil
        }
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.present(Self.removalAlert(name: name) { [weak self] in
                try? self?.store.remove(id: id)
            }, animated: true)
            // Only asked so far: the row slides back, and the alert decides.
            done(false)
        }
        remove.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [remove])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    /// Removing forgets the server for good: one added again is a new server, so the sessions
    /// on this one never connect again. Their agents run on; editing is how an address or
    /// token changes.
    static func removalAlert(name: String, remove: @escaping () -> Void) -> UIAlertController {
        let device = UIDevice.current.model
        let alert = UIAlertController(
            title: "Remove “\(name)”?",
            message: "Sessions on \(name) stay on this \(device) but can’t connect again, even if you add the server back. "
                + "Their agents keep running on the server. To change its address or token, edit it instead.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in remove() })
        return alert
    }
}

extension ServerEditorViewController {
    /// The editor in its own navigation controller, as a sheet that asks before a swipe
    /// throws away what was typed.
    static func sheet(_ editor: ServerEditorViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .formSheet
        editor.isModalInPresentation = true
        return navigation
    }
}

/// Whether a server answered: a spinner while asking, then a mark.
final class ServerCheckView: UIView {
    let spoken: String?

    init(_ check: ServersViewController.Check?) {
        switch check {
        case .checking?: spoken = "Checking"
        case let .reachable(summary)?: spoken = "Connected, \(summary)"
        case let .failed(reason)?: spoken = "Can’t connect. \(reason)"
        case nil: spoken = nil
        }
        super.init(frame: .zero)
        let view: UIView
        switch check {
        case .checking?:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            view = spinner
        case .reachable?:
            let image = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            image.tintColor = .systemGreen
            view = image
        case .failed?:
            let image = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
            image.tintColor = .systemRed
            view = image
        case nil:
            view = UIView()
        }
        (view as? UIImageView)?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The address with the check's result under it, mark and words, for accessibility sizes.
    static func detail(address: String, _ check: ServersViewController.Check?) -> NSAttributedString {
        let font = ChromeFont.monospaced(.subheadline)
        let text = NSMutableAttributedString(string: address, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        let (symbol, color, words): (String, UIColor, String)
        switch check {
        case .checking?: (symbol, color, words) = ("ellipsis.circle", .secondaryLabel, "Checking…")
        case .reachable?: (symbol, color, words) = ("checkmark.circle.fill", .systemGreen, "Connected")
        case .failed?: (symbol, color, words) = ("exclamationmark.triangle.fill", .systemRed, "Can’t connect")
        case nil: return text
        }
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        text.append(NSAttributedString(string: "\n"))
        if let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: body, scale: .small)) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image.withTintColor(color, renderingMode: .alwaysOriginal))))
        }
        text.append(NSAttributedString(string: " \(words)", attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel]))
        return text
    }
}
