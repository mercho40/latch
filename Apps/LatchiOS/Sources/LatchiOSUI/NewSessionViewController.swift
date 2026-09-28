import LatchAgentCore
import LatchSessionKit
import UIKit

/// New Session: which server, which folder on it, which agent. Latch cannot browse a
/// server's folders, so the folder is typed, starting from the server's home, which one
/// handshake reports, or picked from the folders in use there. The home reads as `~`, and is
/// written out in full on Create, so a session keeps an absolute path.
final class NewSessionViewController: UITableViewController, UITextFieldDelegate {
    struct Choice: Equatable {
        let serverID: UUID
        let path: String
        let agent: AgentPreset
    }

    /// Called once, on Create.
    var onCreate: ((Choice) -> Void)?

    private let servers: [ServerProfile]
    private let check: ServerCheck
    /// The folder and agent last used on a server, which it starts from rather than the
    /// server's home and the first agent.
    private let recent: (UUID) -> Choice?
    private let memory: ServerMemory?
    /// Folders in use on a server, most recent first, for the folder field's menu.
    var recentFolders: (UUID) -> [String] = { _ in [] } {
        didSet { if isViewLoaded { rebuildFolderMenu() } }
    }
    private let foldersButton = UIButton(type: .system)
    private(set) var selectedServerID: UUID?
    private(set) var selectedAgent: AgentPreset?
    let pathField = UITextField()
    private let spinner = UIActivityIndicatorView(style: .medium)
    let serverButton = UIButton(configuration: .plain())
    let agentButton = UIButton(configuration: .plain())
    private(set) lazy var createItem = UIBarButtonItem(title: "Create", primaryAction: UIAction { [weak self] _ in
        self?.create()
    })
    /// Once the folder is typed in, a home folder arriving late must not replace it.
    private var pathEdited = false
    private var homeFetch: Task<Void, Never>?
    private var fetchGeneration = UUID()
    private(set) var isFetchingHome = false

    init(servers: [ServerProfile], serverID: UUID? = nil, check: @escaping ServerCheck, memory: ServerMemory? = nil,
         recent: @escaping (UUID) -> Choice? = { _ in nil }) {
        self.servers = servers
        self.check = check
        self.memory = memory
        self.recent = recent
        selectedServerID = serverID.flatMap { id in servers.contains { $0.id == id } ? id : nil } ?? servers.first?.id
        selectedAgent = selectedServerID.flatMap(recent)?.agent
        super.init(style: .insetGrouped)
        title = "New Session"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var selectedServer: ServerProfile? { servers.first { $0.id == selectedServerID } }

    var canCreate: Bool {
        selectedServer != nil && selectedAgent != nil
            && !(pathField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.cancel()
        })
        if #available(iOS 26.0, *) { createItem.style = .prominent } else { createItem.style = .done }
        navigationItem.rightBarButtonItem = createItem
        tableView.keyboardDismissMode = .interactive
        for button in [serverButton, agentButton] {
            button.showsMenuAsPrimaryAction = true
            button.changesSelectionAsPrimaryAction = true
            button.configuration?.titleLineBreakMode = .byTruncatingTail
        }
        serverButton.accessibilityLabel = "Server"
        agentButton.accessibilityLabel = "Agent"
        pathField.font = ChromeFont.monospaced(.body)
        pathField.adjustsFontForContentSizeCategory = true
        pathField.autocapitalizationType = .none
        pathField.autocorrectionType = .no
        pathField.spellCheckingType = .no
        pathField.smartDashesType = .no
        pathField.smartQuotesType = .no
        pathField.returnKeyType = .go
        pathField.clearButtonMode = .whileEditing
        pathField.delegate = self
        pathField.accessibilityLabel = "Folder on the server"
        pathField.addAction(UIAction { [weak self] _ in self?.pathChanged() }, for: .editingChanged)
        spinner.hidesWhenStopped = true
        var folders = UIButton.Configuration.plain()
        folders.image = UIImage(systemName: "clock.arrow.circlepath")
        folders.baseForegroundColor = .secondaryLabel
        folders.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        folders.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
        foldersButton.configuration = folders
        foldersButton.showsMenuAsPrimaryAction = true
        // A symbol, not text: past the first accessibility size it would crowd out the folder.
        foldersButton.maximumContentSizeCategory = .accessibilityMedium
        foldersButton.setContentHuggingPriority(.required, for: .horizontal)
        foldersButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        foldersButton.accessibilityLabel = "Recent Folders"
        foldersButton.isPointerInteractionEnabled = true
        rebuildServerMenu()
        rebuildAgentMenu()
        rebuildFolderMenu()
        fetchHome()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: NewSessionViewController, _) in
            controller.fitSheet()
        }
    }

    /// On iPad the form sheet is as tall as the form, so at accessibility sizes the folder is
    /// not cut off below a fixed height; never taller than the window.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitSheet()
    }

    private func fitSheet() {
        guard traitCollection.userInterfaceIdiom == .pad, let navigation = navigationController else { return }
        tableView.layoutIfNeeded()
        let bar = navigation.navigationBar.frame.maxY
        let content = tableView.contentSize.height + tableView.adjustedContentInset.bottom + bar
        let limit = (view.window?.bounds.height ?? 1_000) - 80
        let height = ceil(min(max(content, 300), limit))
        if abs(navigation.preferredContentSize.height - height) > 1 {
            navigation.preferredContentSize = CGSize(width: 540, height: height)
        }
    }

    // MARK: Table

    /// The two choices together, then the folder, which is typed: the whole form fits the
    /// medium detent.
    private enum Row { case server, folder, agent }
    private let layout: [[Row]] = [[.server, .agent], [.folder]]

    override func numberOfSections(in tableView: UITableView) -> Int { layout.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { layout[section].count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        layout[section].first == .folder ? "Folder" : nil
    }

    /// The sheet's first row sits close under its title.
    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 8 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard layout[section].first == .folder else { return nil }
        let server = selectedServer?.name ?? "the server"
        let agent = selectedAgent.map { $0 == .custom ? "the custom agent" : $0.title } ?? "the agent"
        return "The folder on \(server) where the agent works. If \(agent) isn’t installed on \(server), the session says so when it starts."
    }

    /// The footer names the server and agent chosen.
    private func refreshFooter() {
        guard isViewLoaded, let section = layout.firstIndex(where: { $0.first == .folder }),
              let footer = tableView.footerView(forSection: section) else { return }
        var content = footer.defaultContentConfiguration()
        content.text = tableView(tableView, titleForFooterInSection: section)
        UIView.performWithoutAnimation {
            footer.contentConfiguration = content
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    /// Up to eight folders in use on the server, shown as the field shows them.
    private func rebuildFolderMenu() {
        guard let server = selectedServer else { return }
        let folders = recentFolders(server.id)
        foldersButton.isHidden = folders.isEmpty
        foldersButton.menu = UIMenu(title: "Recent Folders", children: folders.map { path in
            UIAction(title: shown(path)) { [weak self] _ in
                guard let self else { return }
                pathField.text = shown(path)
                pathEdited = true
                refreshCreate()
            }
        })
    }

    /// A path as the field shows it: the server's home as `~`.
    private func shown(_ path: String) -> String {
        ServerMemory.displayPath(path, home: home)
    }

    /// The selected server's home, as this sheet or an earlier handshake found it.
    private var home: String? { fetchedHome ?? memory?.home(for: selectedServer) }
    private var fetchedHome: String?

    /// Three rows, each made once: the controls in them keep their state across reloads.
    private var cells: [Row: UITableViewCell] = [:]

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = layout[indexPath.section][indexPath.row]
        if let cell = cells[row] { return cell }
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        cells[row] = cell
        switch row {
        case .server: menuRow(cell, title: "Server", button: serverButton)
        case .agent: menuRow(cell, title: "Agent", button: agentButton)
        case .folder:
            for view in [pathField, spinner, foldersButton] as [UIView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.contentView.addSubview(view)
            }
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                pathField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                pathField.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
                pathField.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                pathField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                pathField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                spinner.trailingAnchor.constraint(equalTo: foldersButton.leadingAnchor),
                spinner.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                foldersButton.trailingAnchor.constraint(equalTo: margins.trailingAnchor, constant: 8),
                foldersButton.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                foldersButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                foldersButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
        }
        return cell
    }

    /// A label, and a pop-up button at the trailing edge that shows the choice, as Settings
    /// has; at accessibility sizes the button goes under the label, as the server editor's
    /// fields do, so the choice has the row's width.
    private func menuRow(_ cell: UITableViewCell, title: String, button: UIButton) {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -2),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let update = { [weak stack, weak button] (traits: UITraitCollection) in
            let stacked = traits.preferredContentSizeCategory.isAccessibilityCategory
            stack?.axis = stacked ? .vertical : .horizontal
            stack?.alignment = stacked ? .leading : .center
            stack?.spacing = stacked ? 0 : 12
            stack?.layoutMargins.top = stacked ? 8 : 0
            stack?.isLayoutMarginsRelativeArrangement = stacked
            button?.contentHorizontalAlignment = stacked ? .leading : .trailing
            // Stacked, the choice has the row's width, and wraps rather than lose its end.
            button?.configuration?.titleLineBreakMode = stacked ? .byWordWrapping : .byTruncatingTail
            button?.configuration?.contentInsets = stacked
                ? NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0)
                : NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0)
        }
        update(cell.traitCollection)
        cell.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: UITableViewCell, _) in
            update(cell.traitCollection)
        }
    }

    // MARK: Server and agent

    private func rebuildServerMenu() {
        serverButton.menu = UIMenu(options: .singleSelection, children: servers.map { server in
            UIAction(title: server.name, subtitle: server.address,
                     state: server.id == selectedServerID ? .on : .off) { [weak self] _ in
                self?.selectServer(server.id)
            }
        })
    }

    /// Presets are always offered: whether one is installed is the server's to say, when it
    /// launches. Custom appears only when this server has a command for it.
    private func rebuildAgentMenu() {
        let hasCustom = !(selectedServer?.customCommand.isEmpty ?? true)
        let offered = AgentPreset.allCases.filter { $0 != .custom || hasCustom }
        if selectedAgent.map({ !offered.contains($0) }) ?? true { selectedAgent = offered.first }
        agentButton.menu = UIMenu(options: .singleSelection, children: offered.map { preset in
            UIAction(title: preset == .custom ? "Custom" : preset.title,
                     subtitle: preset == .custom ? selectedServer?.customCommand : nil,
                     state: preset == selectedAgent ? .on : .off) { [weak self] _ in
                self?.selectedAgent = preset
                self?.refreshCreate()
                self?.refreshFooter()
            }
        })
        refreshCreate()
    }

    /// Picks a server as the menu does.
    func selectServer(_ id: UUID) {
        guard id != selectedServerID, servers.contains(where: { $0.id == id }) else { return }
        selectedServerID = id
        if let agent = recent(id)?.agent { selectedAgent = agent }
        fetchedHome = nil
        rebuildServerMenu()
        rebuildAgentMenu()
        rebuildFolderMenu()
        fetchHome()
        refreshFooter()
    }

    func selectAgent(_ preset: AgentPreset) {
        selectedAgent = preset
        rebuildAgentMenu()
    }

    // MARK: Folder

    /// The folder last used on the server, or else its home folder, which one handshake
    /// reports. A server that cannot be reached leaves `~`, which the server resolves when the
    /// agent launches.
    private func fetchHome() {
        homeFetch?.cancel()
        guard let server = selectedServer else { return }
        if let last = recent(server.id)?.path, !last.isEmpty {
            fetchGeneration = UUID()
            isFetchingHome = false
            spinner.stopAnimating()
            pathField.placeholder = "Path on the server"
            if !pathEdited { pathField.text = shown(last) }
            return refreshCreate()
        }
        let generation = UUID()
        fetchGeneration = generation
        isFetchingHome = true
        spinner.startAnimating()
        if !pathEdited { pathField.text = "" }
        pathField.placeholder = "Finding the home folder on \(server.name)…"
        refreshCreate()
        let check = check
        let options = server.connectionOptions
        homeFetch = Task { [weak self] in
            let home = try? await check(options).home
            guard let self, self.fetchGeneration == generation, !Task.isCancelled else { return }
            self.isFetchingHome = false
            self.spinner.stopAnimating()
            self.pathField.placeholder = "Path on the server"
            if let home, home.hasPrefix("/") { self.fetchedHome = home }
            // The home itself reads as `~`, which Create writes out again.
            if !self.pathEdited { self.pathField.text = "~" }
            self.rebuildFolderMenu()
            self.refreshCreate()
        }
    }

    /// Waits for the home folder request in flight, for tests.
    func homeFetched() async { await homeFetch?.value }

    func pathChanged() {
        pathEdited = !(pathField.text ?? "").isEmpty
        refreshCreate()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard canCreate else { return false }
        create()
        return true
    }

    private func refreshCreate() { createItem.isEnabled = canCreate }

    // MARK: Finishing

    func create() {
        guard canCreate, let server = selectedServer, let agent = selectedAgent else { return }
        homeFetch?.cancel()
        let typed = (pathField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let choice = Choice(serverID: server.id, path: ServerMemory.expandedPath(typed, home: home), agent: agent)
        let handler = onCreate
        onCreate = nil
        dismiss(animated: true)
        handler?(choice)
    }

    private func cancel() {
        homeFetch?.cancel()
        onCreate = nil
        dismiss(animated: true)
    }
}
