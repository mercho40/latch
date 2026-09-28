import LatchAgentCore
import LatchSessionKit
import UIKit

/// New Session: which server, which folder on it, which agent. Latch cannot browse a
/// server's folders, so the folder is typed, starting from the server's home, which one
/// handshake reports.
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

    init(servers: [ServerProfile], serverID: UUID? = nil, check: @escaping ServerCheck,
         recent: @escaping (UUID) -> Choice? = { _ in nil }) {
        self.servers = servers
        self.check = check
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
        rebuildServerMenu()
        rebuildAgentMenu()
        fetchHome()
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
        layout[section].first == .folder
            ? "A folder on the server, where the agent works. If the agent is not installed there, the session says so when it starts."
            : nil
    }

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
            pathField.translatesAutoresizingMaskIntoConstraints = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(pathField)
            cell.contentView.addSubview(spinner)
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                pathField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                pathField.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
                pathField.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                pathField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                pathField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                spinner.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                spinner.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
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
            }
        })
        refreshCreate()
    }

    /// Picks a server as the menu does.
    func selectServer(_ id: UUID) {
        guard id != selectedServerID, servers.contains(where: { $0.id == id }) else { return }
        selectedServerID = id
        if let agent = recent(id)?.agent { selectedAgent = agent }
        rebuildServerMenu()
        rebuildAgentMenu()
        fetchHome()
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
            if !pathEdited { pathField.text = last }
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
            if !self.pathEdited { self.pathField.text = home.flatMap { $0.isEmpty ? nil : $0 } ?? "~" }
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
        let choice = Choice(serverID: server.id,
                            path: (pathField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), agent: agent)
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
