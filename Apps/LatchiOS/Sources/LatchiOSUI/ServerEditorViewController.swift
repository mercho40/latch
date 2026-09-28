import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import UniformTypeIdentifiers

/// Add Server and Edit Server: paste what `latch-server pair` prints, which fills in
/// everything, or enter the server by hand. The token field is secure and, when editing,
/// empty: left so, the token stays as it was. Nothing is saved until Add or Save.
final class ServerEditorViewController: UITableViewController, UITextFieldDelegate {
    /// Called after the server was saved.
    var onSave: ((ServerProfile) -> Void)?
    /// Called after the server was removed from the editor.
    var onRemove: ((UUID) -> Void)?

    private let store: any PhoneServerStore
    private let check: ServerCheck
    /// The server being edited, whose ID carries over; nil when adding.
    let originalID: UUID?
    private let originalToken: LatchRemoteToken?
    /// Said in the form when it was opened for a reason, such as a link to a known server.
    private var note: String?
    /// Filled in from a `latch://` link rather than typed or pasted.
    private(set) var fromLink = false

    let nameField = UITextField()
    let hostField = UITextField()
    let portField = UITextField()
    let tokenField = UITextField()
    let unencryptedSwitch = UISwitch()
    let commandField = UITextField()
    let pasteControl: UIPasteControl
    private(set) lazy var saveItem = UIBarButtonItem(title: originalID == nil ? "Add" : "Save",
                                                     primaryAction: UIAction { [weak self] _ in self?.save() })
    /// What the last paste did, under the Paste button.
    private(set) var pasteMessage: String?
    /// What the last Test Connection found, for the fields as they were then.
    private(set) var testResult: (text: String, succeeded: Bool)?
    private(set) var isTesting = false
    private var testTask: Task<Void, Never>?
    /// The name follows the host until the user types one of their own.
    private var nameEdited = false
    static let filledMessage = "Filled in from the pairing string."

    /// Adding, optionally filled in from a pairing link.
    convenience init(store: any PhoneServerStore, pairing: LatchRemotePairing? = nil, check: @escaping ServerCheck) {
        self.init(store: store, id: nil, token: nil, check: check,
                  note: pairing == nil ? nil : "From a pairing link. Check the host, then tap Add.")
        if let pairing { fillFromLink(pairing) }
    }

    /// Editing a server. A pairing fills in its new address and token, for a link to a server
    /// already added.
    convenience init(store: any PhoneServerStore, editing server: ServerProfile, pairing: LatchRemotePairing? = nil,
                     check: @escaping ServerCheck) {
        self.init(store: store, id: server.id, token: server.token, check: check,
                  note: pairing == nil ? nil : "Save to use the new token for \(server.name).")
        load(ServerProfile.Stored(server))
        if let pairing { fillFromLink(pairing) }
    }

    /// Entering the token again for a server whose token is not on this device. Its ID stays,
    /// so its sessions connect once it is saved. A pairing link to it fills in its token.
    convenience init(store: any PhoneServerStore, restoring stored: ServerProfile.Stored,
                     pairing: LatchRemotePairing? = nil, check: @escaping ServerCheck) {
        self.init(store: store, id: stored.id, token: nil, check: check, note: pairing == nil
            ? "The token for \(stored.name) is not on this device. Paste a pairing string or enter the token."
            : "The token for \(stored.name) is not on this device. Save to use the one from this link.")
        load(stored)
        if let pairing { fillFromLink(pairing) }
    }

    private init(store: any PhoneServerStore, id: UUID?, token: LatchRemoteToken?, check: @escaping ServerCheck, note: String?) {
        self.store = store
        self.check = check
        originalID = id
        originalToken = token
        self.note = note
        let paste = UIPasteControl.Configuration()
        paste.displayMode = .iconAndLabel
        paste.cornerStyle = .capsule
        pasteControl = UIPasteControl(configuration: paste)
        super.init(style: .insetGrouped)
        title = id == nil ? "Add Server" : "Edit Server"
        portField.text = String(LatchRemoteProtocol.defaultPort)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func load(_ stored: ServerProfile.Stored) {
        nameField.text = stored.name
        hostField.text = stored.host
        portField.text = String(stored.port)
        unencryptedSwitch.isOn = stored.allowUnencryptedNetwork
        commandField.text = stored.customCommand
        // A name of the user's own stays when the host changes; one that was only ever the
        // host follows it, as while adding.
        nameEdited = stored.name != stored.host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        if #available(iOS 26.0, *) { saveItem.style = .prominent } else { saveItem.style = .done }
        navigationItem.rightBarButtonItem = saveItem
        tableView.keyboardDismissMode = .interactive
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.url.identifier])
        pasteControl.target = self

        nameField.placeholder = "Optional"
        hostField.placeholder = "vps.tailnet.ts.net"
        hostField.keyboardType = .URL
        portField.keyboardType = .numberPad
        tokenField.isSecureTextEntry = true
        tokenField.placeholder = originalToken == nil ? "latch_…" : "Unchanged"
        commandField.placeholder = "agent acp"
        commandField.font = ChromeFont.monospaced(.body)
        for field in [hostField, portField, tokenField, commandField] { field.font = ChromeFont.monospaced(.body) }
        nameField.font = .preferredFont(forTextStyle: .body)
        for field in [nameField, hostField, portField, tokenField, commandField] {
            field.adjustsFontForContentSizeCategory = true
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.delegate = self
            field.addAction(UIAction { [weak self, weak field] _ in
                guard let self, let field else { return }
                self.fieldChanged(field)
            }, for: .editingChanged)
        }
        nameField.autocapitalizationType = .words
        for field in [hostField, tokenField, commandField] { field.autocapitalizationType = .none }
        nameField.accessibilityLabel = "Name"
        hostField.accessibilityLabel = "Host"
        portField.accessibilityLabel = "Port"
        tokenField.accessibilityLabel = "Token"
        commandField.accessibilityLabel = "Custom agent command"
        unencryptedSwitch.addAction(UIAction { [weak self] _ in self?.clearTestResult() }, for: .valueChanged)
        refresh()
    }

    // MARK: Entry

    /// The server the fields describe, or why they do not describe one yet.
    var entry: Result<ServerProfile, EntryProblem> {
        let host = (hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .failure(.incomplete) }
        guard let port = UInt16((portField.text ?? "").trimmingCharacters(in: .whitespaces)), port > 0 else {
            return .failure(.port)
        }
        let tokenText = (tokenField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token: LatchRemoteToken
        if tokenText.isEmpty, let originalToken {
            token = originalToken
        } else {
            guard !tokenText.isEmpty else { return .failure(.incomplete) }
            guard let entered = LatchRemoteToken(tokenText) else { return .failure(.token) }
            token = entered
        }
        // The pairing parser's host rules: a DNS name or a numeric address.
        guard (try? LatchRemotePairing(host: host, port: port, token: token)) != nil else { return .failure(.host) }
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(ServerProfile(
            id: originalID ?? UUID(), name: name.isEmpty ? host : name, host: host, port: port, token: token,
            allowUnencryptedNetwork: unencryptedSwitch.isOn,
            customCommand: (commandField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    enum EntryProblem: Error, Equatable {
        case incomplete, host, port, token

        var text: String? {
            switch self {
            case .incomplete: nil
            case .host: "The host must be a DNS name or an IP address."
            case .port: "The port must be a number from 1 to 65535."
            case .token: "That is not a Latch token. Run “latch-server token” on the server to see it."
            }
        }
    }

    private func fieldChanged(_ field: UITextField) {
        switch field {
        case nameField: nameEdited = !(nameField.text ?? "").isEmpty
        case hostField: if !nameEdited { nameField.text = hostField.text }
        default: break
        }
        if field !== nameField, field !== commandField { clearTestResult() }
        refresh()
    }

    /// A pasted pairing string fills host, port and token, and the name when none was typed.
    func applyPairing(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            fill(from: try LatchRemotePairing(parsing: trimmed))
            pasteMessage = Self.filledMessage
        } catch {
            pasteMessage = "That is not a pairing string. It starts with latch:// and ends with the token."
        }
        clearTestResult()
        refresh()
    }

    /// A link has filled in everything a paste would, so the sheet asks for a check instead
    /// of offering Paste.
    private func fillFromLink(_ pairing: LatchRemotePairing) {
        fromLink = true
        fill(from: pairing)
    }

    private func fill(from pairing: LatchRemotePairing) {
        hostField.text = pairing.host
        portField.text = String(pairing.port)
        tokenField.text = pairing.token.rawValue
        if !nameEdited { nameField.text = pairing.host }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first else { return }
        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
                let text = text ?? ""
                Task { @MainActor in self?.applyPairing(text) }
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                let text = url?.absoluteString ?? ""
                Task { @MainActor in self?.applyPairing(text) }
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let order = [nameField, hostField, portField, tokenField, commandField]
        if let index = order.firstIndex(of: textField), index + 1 < order.count {
            order[index + 1].becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    private func refresh() {
        saveItem.isEnabled = store.fileProblem == nil && (try? entry.get()) != nil
        guard isViewLoaded else { return }
        for (row, footer) in footers { footer.contentConfiguration = footerContent(for: row) }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
        refreshTestRow()
    }

    // MARK: Test Connection

    func testConnection() {
        guard case let .success(profile) = entry else { return }
        testTask?.cancel()
        isTesting = true
        testResult = nil
        refreshTestRow()
        let check = check
        let options = profile.connectionOptions
        let fromLink = fromLink
        testTask = Task { [weak self] in
            let result: (String, Bool)
            var info: LatchRemoteServerInfo?
            do {
                let answer = try await check(options)
                info = answer
                result = (ServerCheckText.summary(answer), true)
            } catch {
                result = (ServerCheckText.failure(error, offeringUnencryptedNetwork: !fromLink), false)
            }
            guard let self, !Task.isCancelled else { return }
            self.isTesting = false
            self.testResult = result
            self.testTask = nil
            // The result's row first: the note's refresh reloads the table's heights.
            self.refreshTestRow()
            if let info { self.found(info) }
            // Heard without hunting for the row the result appears in.
            UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                string: result.1 ? "Connected. \(result.0)" : "Can’t connect. \(result.0)",
                attributes: [.accessibilitySpeechQueueAnnouncement: true]))
        }
    }

    /// A server that answered goes by the name it gives itself, rather than its full host,
    /// unless one was typed; from a link, the form says what to do next. The result row
    /// already says what was found.
    private func found(_ info: LatchRemoteServerInfo) {
        if !nameEdited, let name = adoptableName(info.hostname) {
            nameField.text = name
        }
        if fromLink, originalID == nil {
            note = "Tap Add to use this server."
            refresh()
        }
    }

    /// The host name a server reports, as a name for it: printable, at most 64 characters, and
    /// not the name of another server here. The server says what it likes, so one reached from
    /// a stranger's link must not pass for a server the user already has, or hide its text
    /// behind bidirectional controls. Nil when nothing of it can be used.
    func adoptableName(_ reported: String) -> String? {
        let scalars = reported.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: false
            default: true
            }
        }
        let name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { return nil }
        let taken = store.servers.contains { $0.id != originalID && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            || store.missingTokens.contains { $0.id != originalID && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return taken ? nil : name
    }

    /// Waits for Test Connection to finish, for tests.
    func testFinished() async { await testTask?.value }

    /// A result describes the fields it was run with; after a change it would mislead.
    private func clearTestResult() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
        guard testResult != nil else { return refreshTestRow() }
        testResult = nil
        refreshTestRow()
    }

    /// The Test Connection button, and the result in a row of its own under it.
    private func refreshTestRow() {
        guard isViewLoaded else { return }
        if let cell = cells[.test] { configureTestCell(cell) }
        if let cell = cells[.testResult] { configureResultCell(cell) }
        guard let section = layout.firstIndex(where: { $0.first == .test }),
              tableView.numberOfSections == layout.count else { return }
        let result = IndexPath(row: 1, section: section)
        let shown = tableView.numberOfRows(inSection: section)
        tableView.performBatchUpdates {
            if layout[section].count > shown { tableView.insertRows(at: [result], with: .fade) }
            if layout[section].count < shown { tableView.deleteRows(at: [result], with: .fade) }
        }
    }

    private func configureTestCell(_ cell: UITableViewCell) {
        var content = cell.defaultContentConfiguration()
        content.text = "Test Connection"
        let enabled = (try? entry.get()) != nil
        content.textProperties.color = enabled ? .tintColor : .tertiaryLabel
        cell.contentConfiguration = content
        let spinner = cell.accessoryView as? UIActivityIndicatorView ?? UIActivityIndicatorView(style: .medium)
        if isTesting { spinner.startAnimating() } else { spinner.stopAnimating() }
        cell.accessoryView = isTesting ? spinner : nil
        cell.selectionStyle = enabled ? .default : .none
        cell.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        cell.accessibilityValue = isTesting ? "Connecting" : nil
    }

    private func configureResultCell(_ cell: UITableViewCell) {
        guard let testResult else { return }
        var content = cell.defaultContentConfiguration()
        content.text = testResult.text
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.textProperties.color = .secondaryLabel
        content.textProperties.numberOfLines = 0
        content.image = UIImage(systemName: testResult.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        content.imageProperties.tintColor = testResult.succeeded ? .systemGreen : .systemRed
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        cell.contentConfiguration = content
        cell.accessibilityLabel = testResult.succeeded ? "Connected" : "Can’t connect"
        cell.accessibilityValue = testResult.text
    }

    // MARK: Finishing

    func save() {
        guard case let .success(profile) = entry else { return }
        do {
            try store.save(profile)
        } catch {
            let alert = UIAlertController(title: "The server could not be saved", message: error.localizedDescription,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            return present(alert, animated: true)
        }
        testTask?.cancel()
        let handler = onSave
        onSave = nil
        dismiss(animated: true)
        handler?(profile)
    }

    private func confirmRemoval() {
        guard let id = originalID else { return }
        let name = (nameField.text ?? "").isEmpty ? (hostField.text ?? "") : (nameField.text ?? "")
        let alert = ServersViewController.removalAlert(name: name) { [weak self] in
            guard let self else { return }
            do { try self.store.remove(id: id) } catch { return }
            self.onRemove?(id)
            self.dismiss(animated: true)
        }
        if let cell = cells[.remove] {
            alert.popoverPresentationController?.sourceView = cell
            alert.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(alert, animated: true)
    }

    // MARK: Table

    private enum Row { case paste, name, host, port, token, test, testResult, unencrypted, command, remove }

    /// Test Connection sits under the fields it tests. A link leaves nothing to paste.
    private var layout: [[Row]] {
        (fromLink ? [] : [[.paste]])
            + [[.name, .host, .port, .token], testResult == nil ? [.test] : [.test, .testResult], [.unencrypted], [.command]]
            + (originalID == nil || !store.servers.contains { $0.id == originalID } ? [] : [[.remove]])
    }

    private var cells: [Row: UITableViewCell] = [:]

    override func numberOfSections(in tableView: UITableView) -> Int { layout.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { layout[section].count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch layout[section].first {
        case .name?: "Server"
        case .command?: "Custom Agent"
        default: nil
        }
    }

    /// Made once per section, so a footer that changes as the user types is updated in place
    /// rather than reloaded out from under the keyboard.
    private var footers: [Row: UITableViewHeaderFooterView] = [:]

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let row = layout[section].first!
        if let footer = footers[row] { return footer }
        let footer = UITableViewHeaderFooterView()
        footer.contentConfiguration = footerContent(for: row)
        footers[row] = footer
        return footer
    }

    private func footerContent(for row: Row) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.footer()
        content.text = footer(for: row)
        return content
    }

    private func footer(for row: Row) -> String? {
        switch row {
        case .paste:
            pasteMessage ?? note ?? (originalID == nil
                ? "Copy what “latch-server pair” prints on the server, then paste it here. It fills in the rest."
                : "Paste a new pairing string to replace the host, port and token.")
        case .name:
            if case let .failure(problem) = entry, let text = problem.text { text } else { fromLink ? note : nil }
        case .unencrypted:
            "The token and everything the agent sends would cross that network in the clear. Use it only on a network you trust."
        case .command:
            "The command a Custom agent runs on this server, found on its PATH. Quotes work; shell expansion does not. Leave it empty to offer no Custom agent."
        case .port, .host, .token, .test, .testResult, .remove: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = layout[indexPath.section][indexPath.row]
        if let cell = cells[row] { return cell }
        let cell = UITableViewCell()
        cells[row] = cell
        cell.selectionStyle = .none
        switch row {
        case .paste:
            // The button alone, on the form's background, rather than a card around one button.
            cell.backgroundConfiguration = .clear()
            pasteControl.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(pasteControl)
            NSLayoutConstraint.activate([
                pasteControl.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                pasteControl.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 4),
                pasteControl.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -4),
                pasteControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
        case .name: FormRow.field(in: cell, label: "Name", field: nameField)
        case .host: FormRow.field(in: cell, label: "Host", field: hostField)
        case .port: FormRow.field(in: cell, label: "Port", field: portField)
        case .token: FormRow.field(in: cell, label: "Token", field: tokenField)
        case .command: FormRow.field(in: cell, label: nil, field: commandField)
        case .unencrypted:
            var content = cell.defaultContentConfiguration()
            // As the Mac's checkbox and the connection error name it.
            content.text = "Allow unencrypted network"
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessoryView = unencryptedSwitch
        case .test: configureTestCell(cell)
        case .testResult: configureResultCell(cell)
        case .remove:
            var content = cell.defaultContentConfiguration()
            content.text = "Remove Server"
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch layout[indexPath.section][indexPath.row] {
        case .test: testConnection()
        case .remove: confirmRemoval()
        default: break
        }
    }
}

/// A form row: a label, and a text field filling the rest; stacked at accessibility sizes.
enum FormRow {
    @MainActor
    static func field(in cell: UITableViewCell, label text: String?, field: UITextField) {
        field.clearButtonMode = .whileEditing
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [field])
        if let text {
            let label = UILabel()
            label.text = text
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.isAccessibilityElement = false
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
            stack.insertArrangedSubview(label, at: 0)
        }
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let update = { [weak stack] (traits: UITraitCollection) in
            let stacked = traits.preferredContentSizeCategory.isAccessibilityCategory
            stack?.axis = stacked ? .vertical : .horizontal
            stack?.alignment = stacked ? .fill : .center
            stack?.spacing = stacked ? 4 : 12
        }
        update(cell.traitCollection)
        cell.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: UITableViewCell, _) in
            update(cell.traitCollection)
        }
    }
}
