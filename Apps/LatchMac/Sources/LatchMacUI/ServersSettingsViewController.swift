import AppKit
import LatchRemoteProtocol
import LatchSessionKit

/// The Servers pane: the `latch-server`s this Mac runs remote sessions on. A list, and below it
/// what belongs to the selected server: whether its token may cross an unencrypted network,
/// the command its Custom agent runs, and a check that it answers.
@MainActor
final class ServersSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: any ServerStore
    private let check: ServerCheck

    let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString:
        "No servers yet. On the server, run “latch-server pair”, then choose Add Server… and paste what it prints.")
    private let problemLabel = WrappingLabel(wrappingLabelWithString: "")
    let addButton = NSButton(title: "Add Server…", target: nil, action: nil)
    let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let unencryptedCheckbox = NSButton(checkboxWithTitle: "Allow unencrypted network", target: nil, action: nil)
    private let unencryptedWarning = WrappingLabel(wrappingLabelWithString:
        "The token and everything the agent sends would cross that network in the clear. Use it only on a network you trust.")
    let commandField = NSTextField(string: "")
    private let commandCaption = NSTextField(labelWithString: "Custom agent command")
    let testButton = NSButton(title: "Test Connection", target: nil, action: nil)
    /// What the last Test Connection found, for the selected server only.
    let testResult = WrappingLabel(wrappingLabelWithString: "")
    private let testSpinner = NSProgressIndicator()
    private var testTask: Task<Void, Never>?
    /// Kept by ID, so a list that changes under the selection keeps the same server selected.
    private var selectedID: UUID?
    /// The Add or Edit sheet while it is open.
    private(set) var serverSheet: AddServerController?
    /// The server whose command is being typed. An edit still open when the selection moves
    /// (Remove and Add Server… take no focus) belongs to the server it began on.
    private var commandEditServerID: UUID?
    /// Asks before a server and its token are forgotten; calls back only to go ahead.
    var confirmRemoval: @MainActor (ServerProfile, NSWindow?, @escaping () -> Void) -> Void = ServersSettingsViewController.askToRemove

    init(store: any ServerStore, check: @escaping ServerCheck = ServerCheckText.live) {
        self.store = store
        self.check = check
        super.init(nibName: nil, bundle: nil)
        title = "Servers"
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .serverStoreDidChange, object: store)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    var selectedServer: ServerProfile? {
        store.servers.indices.contains(table.selectedRow) ? store.servers[table.selectedRow] : nil
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 36
        table.usesAutomaticRowHeights = false
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.setAccessibilityLabel("Servers")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editClickedServer)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 148).isActive = true
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        let listArea = NSView()
        listArea.addSubview(scroll)
        listArea.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: listArea.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listArea.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: listArea.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listArea.bottomAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listArea.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: listArea.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: listArea.trailingAnchor, constant: -24),
        ])
        let group = Self.group(listArea)

        addButton.target = self
        addButton.action = #selector(addServer)
        editButton.target = self
        editButton.action = #selector(editServer)
        removeButton.target = self
        removeButton.action = #selector(removeServer)
        for button in [addButton, editButton, removeButton] { button.bezelStyle = .rounded }
        let listButtons = NSStackView(views: [addButton, editButton, removeButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 8

        problemLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemLabel.textColor = .systemRed
        problemLabel.maximumNumberOfLines = 0

        unencryptedCheckbox.target = self
        unencryptedCheckbox.action = #selector(toggleUnencrypted)
        for label in [unencryptedWarning, testResult] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        testResult.isSelectable = true

        commandField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .regular)
        commandField.delegate = self
        commandField.placeholderString = "agent acp"
        commandField.setAccessibilityLabel("Custom agent command on this server")
        commandField.toolTip = "Runs on the server, found on its PATH. Quotes are supported; shell expansion is not."

        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false
        let testRow = NSStackView(views: [testButton, testSpinner])
        testRow.orientation = .horizontal
        testRow.spacing = 8

        let content = NSStackView(views: [group, listButtons, problemLabel, unencryptedCheckbox, unencryptedWarning,
                                          commandCaption, commandField, testRow, testResult])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(20, after: listButtons)
        content.setCustomSpacing(2, after: unencryptedCheckbox)
        content.setCustomSpacing(20, after: unencryptedWarning)
        content.setCustomSpacing(20, after: commandField)
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [group, problemLabel, commandField, testResult] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        // Under the checkbox's title, as a checkbox's explanation sits in System Settings.
        unencryptedWarning.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -60).isActive = true
        unencryptedWarning.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 40).isActive = true

        view = NSView()
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 460),
        ])
        table.reloadData()
        if !store.servers.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        refresh()
    }

    /// The same grouped box the Agents pane uses.
    private static func group(_ content: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .primary
        box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 0, height: 0)
        box.contentView = content
        return box
    }

    /// A file that could not be read is tried again whenever the pane is shown, so moving it
    /// aside needs no relaunch.
    override func viewWillAppear() {
        super.viewWillAppear()
        store.reload()
    }

    /// Opening Settings is not a request to edit the first field.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { store.servers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.servers.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("server")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ServerRowView ?? ServerRowView(identifier: identifier)
        cell.configure(store.servers[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard selectedServer?.id != selectedID else { return refresh() }
        selectedID = selectedServer?.id
        clearTestResult()
        refresh()
    }

    /// A result describes the profile it was run with; after a change it would mislead.
    private func clearTestResult() {
        testTask?.cancel()
        testTask = nil
        testSpinner.stopAnimation(nil)
        testResult.stringValue = ""
    }

    @objc private func storeChanged() {
        guard isViewLoaded else { return }
        table.reloadData()
        let row = selectedID.flatMap { id in store.servers.firstIndex { $0.id == id } }
        table.selectRowIndexes(row.map { [$0] } ?? [], byExtendingSelection: false)
        refresh()
    }

    private func refresh() {
        let server = selectedServer
        let readable = store.problem == nil
        // An unreadable file is not an empty list: the problem says what to do instead.
        emptyLabel.isHidden = !store.servers.isEmpty || !readable
        problemLabel.stringValue = store.problem.map {
            "\($0) Servers can’t be added or changed until it can. Move the file aside, then open this pane again to start a new list."
        } ?? ""
        problemLabel.isHidden = readable
        addButton.isEnabled = readable
        editButton.isEnabled = readable && server != nil
        removeButton.isEnabled = readable && server != nil
        for control in [unencryptedCheckbox, commandField, testButton] as [NSControl] {
            control.isEnabled = readable && server != nil
        }
        // Through a TLS proxy the connection is always encrypted.
        unencryptedCheckbox.isEnabled = unencryptedCheckbox.isEnabled && server?.transport == .tcp
        unencryptedCheckbox.state = server?.allowUnencryptedNetwork == true ? .on : .off
        let textColor: NSColor = server == nil ? .tertiaryLabelColor : .secondaryLabelColor
        unencryptedWarning.textColor = textColor
        commandCaption.textColor = server == nil ? .disabledControlTextColor : .labelColor
        if commandEditServerID == nil { commandField.stringValue = server?.customCommand ?? "" }
    }

    private func update(_ id: UUID? = nil, _ change: (inout ServerProfile) -> Void) {
        guard let original = id.map({ store.server(id: $0) }) ?? selectedServer else { return }
        var server = original
        change(&server)
        guard server != original else { return }
        if server.id == selectedServer?.id { clearTestResult() }
        save(server)
    }

    private func save(_ server: ServerProfile) {
        do { try store.save(server) } catch { report(error) }
    }

    private func report(_ error: any Error) {
        problemLabel.stringValue = error.localizedDescription
        problemLabel.isHidden = false
    }

    // MARK: Actions

    @objc func addServer() {
        showSheet(AddServerController())
    }

    /// Changes the selected server in place. It keeps its ID, so the sessions on it stay on it;
    /// this is how a rotated token reaches Latch without orphaning them.
    @objc func editServer() {
        // An open command edit is saved to its own server first, so the sheet starts from it.
        view.window?.makeFirstResponder(nil)
        guard let server = selectedServer else { return }
        showSheet(AddServerController(editing: server))
    }

    /// Selects a server, as a session's banner does before the user edits the server it is on.
    func select(serverID id: UUID) {
        loadViewIfNeeded()
        guard let row = store.servers.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// A double-click edits the row it landed on, not an empty part of the list.
    @objc private func editClickedServer() {
        guard store.servers.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        editServer()
    }

    private func showSheet(_ sheet: AddServerController) {
        guard let window = view.window, store.problem == nil, window.attachedSheet == nil else { return }
        window.makeFirstResponder(nil)
        sheet.onFinish = { [weak self] entry in
            guard let self else { return }
            self.serverSheet = nil
            guard var profile = entry else { return }
            // An edit changes only what the sheet shows, on the server as it is now: anything
            // else saved since the sheet opened, such as its command, stays.
            if let current = self.store.server(id: profile.id) {
                var edited = current
                edited.name = profile.name
                edited.host = profile.host
                edited.port = profile.port
                edited.transport = profile.transport
                edited.token = profile.token
                guard edited != current else { return }
                profile = edited
            }
            if profile.id == self.selectedServer?.id { self.clearTestResult() }
            self.save(profile)
            if let row = self.store.servers.firstIndex(where: { $0.id == profile.id }) {
                self.table.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
        serverSheet = sheet
        sheet.begin(over: window)
    }

    /// Only the profile goes: sessions on the server keep their history and show that their
    /// server is gone.
    @objc func removeServer() {
        // An open command edit is saved to its own server first.
        view.window?.makeFirstResponder(nil)
        guard let server = selectedServer, view.window?.attachedSheet == nil else { return }
        confirmRemoval(server, view.window) { [weak self] in
            guard let self, let row = self.store.servers.firstIndex(where: { $0.id == server.id }) else { return }
            do { try self.store.remove(id: server.id) } catch { return self.report(error) }
            // The next server takes the selection, as a row does in any list after a delete.
            let count = self.store.servers.count
            self.table.selectRowIndexes(count == 0 ? [] : [min(row, count - 1)], byExtendingSelection: false)
        }
    }

    /// Removing forgets the server for good: a server added again is a new one, so sessions on the
    /// removed one never connect again. Edit… is the way to change an address or token.
    private static func askToRemove(_ server: ServerProfile, over window: NSWindow?, then remove: @escaping () -> Void) {
        guard let window else { return remove() }
        let alert = NSAlert()
        alert.messageText = "Remove “\(server.name)”?"
        alert.informativeText = "Sessions on \(server.name) stay in the sidebar but can’t connect again, even if you add the server back. To change its address or token, use Edit… instead."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { remove() }
        }
    }

    @objc private func toggleUnencrypted() {
        let allowed = unencryptedCheckbox.state == .on
        update { $0.allowUnencryptedNetwork = allowed }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === commandField else { return }
        commandEditServerID = selectedServer?.id
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === commandField else { return }
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = commandEditServerID ?? selectedServer?.id
        commandEditServerID = nil
        // A server removed mid-edit takes the edit with it.
        if let id { update(id) { $0.customCommand = command } }
        refresh()
    }

    @objc func testConnection() {
        guard let server = selectedServer else { return }
        testTask?.cancel()
        testResult.stringValue = "Connecting to \(server.address)…"
        testSpinner.startAnimation(nil)
        let check = check
        let options = server.connectionOptions
        let id = server.id
        testTask = Task { [weak self] in
            let text: String
            do { text = ServerCheckText.summary(try await check(options)) }
            catch { text = ServerCheckText.failure(error) }
            guard let self, !Task.isCancelled, self.selectedServer?.id == id else { return }
            self.testSpinner.stopAnimation(nil)
            self.testResult.stringValue = text
            self.testTask = nil
        }
    }

    /// Waits for Test Connection to finish, for tests.
    func testFinished() async { await testTask?.value }
}

/// A server's name over its address.
@MainActor
private final class ServerRowView: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        address.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        address.textColor = .secondaryLabelColor
        for label in [name, address] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            address.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            address.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            address.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func configure(_ server: ServerProfile) {
        name.stringValue = server.name
        address.stringValue = server.address
        setAccessibilityLabel("\(server.name), \(server.address)")
    }
}

/// Add Server: paste what `latch-server pair` prints, which fills in everything, or enter the
/// server by hand. Both token-bearing fields are secure fields, so the token never shows.
/// Editing a server uses the same sheet, filled in except for the token: left empty, the token
/// stays as it was, and a pasted pairing string replaces the connection, host, port and token.
@MainActor
final class AddServerController: NSWindowController, NSTextFieldDelegate {
    /// Called once: with the profile on Add or Save, nil on Cancel.
    var onFinish: ((ServerProfile?) -> Void)?
    /// The server being edited, whose ID, token and settings carry over; nil when adding.
    let original: ServerProfile?

    let pairingField = NSSecureTextField(string: "")
    let nameField = NSTextField(string: "")
    /// Direct, or through a TLS proxy such as a Cloudflare Tunnel, in `LatchRemoteTransport` order.
    let transportPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let hostField = NSTextField(string: "")
    let portField = NSTextField(string: String(LatchRemoteProtocol.defaultPort))
    let tokenField = NSSecureTextField(string: "")
    /// Says what is wrong with the entry, or what the pasted string filled in.
    let message = WrappingLabel(wrappingLabelWithString: "")
    private let addButton: NSButton
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// The name follows the host until the user types one of their own.
    private var nameEdited = false
    private static let fieldWidth: CGFloat = 300

    init(editing original: ServerProfile? = nil) {
        self.original = original
        addButton = NSButton(title: original == nil ? "Add" : "Save", target: nil, action: nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        panel.title = original == nil ? "Add Server" : "Edit Server"
        super.init(window: panel)
        build(in: panel)
        if let original {
            nameField.stringValue = original.name
            transport = original.transport
            hostField.stringValue = original.host
            portField.stringValue = String(original.port)
            // A name of the user's own stays when the host changes; one that was only ever
            // the host follows it, as it does while adding.
            nameEdited = original.name != original.host
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func begin(over parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        // Editing starts where a rotated token goes too.
        window.makeFirstResponder(pairingField)
    }

    private func build(in panel: NSPanel) {
        let heading = NSTextField(labelWithString: original == nil ? "Add Server" : "Edit Server")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        pairingField.placeholderString = "latch://host:\(LatchRemoteProtocol.defaultPort)?token=…"
        pairingField.setAccessibilityLabel("Pairing string")
        let pairingCaption = NSTextField(labelWithString: original == nil
            ? "Paste what “latch-server pair” prints on the server; it fills in the rest."
            : "Paste a new pairing string to replace the connection, host, port and token.")
        nameField.setAccessibilityLabel("Name")
        transportPopUp.addItems(withTitles: LatchRemoteTransport.allCases.map(Self.title))
        transportPopUp.setAccessibilityLabel("Connection")
        transportPopUp.target = self
        transportPopUp.action = #selector(transportChanged)
        hostField.placeholderString = "vps.tailnet.ts.net"
        hostField.setAccessibilityLabel("Host")
        portField.setAccessibilityLabel("Port")
        portField.alignment = .right
        tokenField.placeholderString = original == nil ? "latch_…" : "Unchanged"
        tokenField.setAccessibilityLabel("Token")
        for field in [pairingField, nameField, hostField, portField, tokenField] as [NSTextField] { field.delegate = self }
        for label in [pairingCaption, message] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        message.maximumNumberOfLines = 0
        let hostRow = NSStackView(views: [hostField, NSTextField(labelWithString: "Port:"), portField])
        hostRow.orientation = .horizontal
        hostRow.spacing = 8
        hostField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        portField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        for view in [pairingField, nameField, hostRow, tokenField] as [NSView] {
            view.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Pairing string:"), pairingField],
            [NSGridCell.emptyContentView, pairingCaption],
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Connection:"), transportPopUp],
            [NSTextField(labelWithString: "Host:"), hostRow],
            [NSTextField(labelWithString: "Token:"), tokenField],
            [NSGridCell.emptyContentView, message],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.row(at: 1).topPadding = -6
        grid.row(at: 2).topPadding = 8

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(add)
        addButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancelButton, addButton], in: .trailing)
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let content = NSStackView(views: [heading, grid, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.setCustomSpacing(20, after: grid)
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            // A leading-aligned stack does not otherwise insist on the grid's full width.
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
        ])
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
    }

    // MARK: Entry

    func controlTextDidChange(_ obj: Notification) {
        switch obj.object as? NSTextField {
        case pairingField: pairingChanged()
        case nameField: nameEdited = !nameField.stringValue.isEmpty
        case hostField: if !nameEdited { nameField.stringValue = hostField.stringValue }
        default: break
        }
        refresh()
    }

    static func title(_ transport: LatchRemoteTransport) -> String {
        switch transport {
        case .tcp: "Direct"
        case .webSocket: "Through a TLS proxy (wss)"
        }
    }

    var transport: LatchRemoteTransport {
        get { LatchRemoteTransport.allCases[max(0, transportPopUp.indexOfSelectedItem)] }
        set { transportPopUp.selectItem(at: LatchRemoteTransport.allCases.firstIndex(of: newValue) ?? 0) }
    }

    /// A port left at the other connection's default follows to this one's.
    @objc func transportChanged() {
        let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespaces))
        if let port, LatchRemoteTransport.allCases.contains(where: { $0 != transport && $0.defaultPort == port }) {
            portField.stringValue = String(transport.defaultPort)
        }
        refresh()
    }

    /// A pasted pairing string fills the connection, host, port and token, and the name when
    /// none was typed.
    func pairingChanged() {
        let text = pairingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let pairing = try? LatchRemotePairing(parsing: text) else { return }
        transport = pairing.transport
        hostField.stringValue = pairing.host
        portField.stringValue = String(pairing.port)
        tokenField.stringValue = pairing.token.rawValue
        if !nameEdited { nameField.stringValue = pairing.host }
    }

    /// The server the fields describe, or why they do not describe one yet.
    var entry: Result<ServerProfile, EntryProblem> {
        let pairingText = pairingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pairingText.isEmpty, (try? LatchRemotePairing(parsing: pairingText)) == nil {
            return .failure(.pairing)
        }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .failure(.incomplete) }
        guard let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespaces)), port > 0 else {
            return .failure(.port)
        }
        let tokenText = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: LatchRemoteToken
        if tokenText.isEmpty, let original {
            token = original.token
        } else {
            guard !tokenText.isEmpty else { return .failure(.incomplete) }
            guard let entered = LatchRemoteToken(tokenText) else { return .failure(.token) }
            token = entered
        }
        // The pairing parser's host rules: a DNS name or a numeric address.
        guard (try? LatchRemotePairing(host: host, port: port, token: token)) != nil else { return .failure(.host) }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var profile = original else {
            return .success(ServerProfile(name: name.isEmpty ? host : name, host: host, port: port, transport: transport, token: token))
        }
        profile.name = name.isEmpty ? host : name
        profile.host = host
        profile.port = port
        profile.transport = transport
        profile.token = token
        return .success(profile)
    }

    enum EntryProblem: Error, Equatable {
        case incomplete, pairing, host, port, token

        var text: String {
            switch self {
            case .incomplete: ""
            case .pairing: "That is not a pairing string. It starts with latch:// and ends with the token."
            case .host: "The host must be a DNS name or an IP address."
            case .port: "The port must be a number from 1 to 65535."
            case .token: "That is not a Latch token. Run “latch-server token” on the server to see it."
            }
        }
    }

    private func refresh() {
        let text: String
        switch entry {
        case .success:
            addButton.isEnabled = true
            text = ""
        case let .failure(problem):
            addButton.isEnabled = false
            text = problem.text
        }
        guard text != message.stringValue else { return }
        message.stringValue = text
        // A message that wraps needs the room, rather than squeezing the heading's inset.
        if let window, let view = window.contentView { window.setContentSize(view.fittingSize) }
    }

    // MARK: Finishing

    @objc func add() {
        guard case let .success(profile) = entry else { return }
        finish(profile)
    }

    @objc func cancel() { finish(nil) }

    private func finish(_ profile: ServerProfile?) {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        let handler = onFinish
        onFinish = nil
        handler?(profile)
    }
}
