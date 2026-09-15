import AppKit

/// The Agents pane: every harness Latch can launch, what it needs, and whether the
/// composer offers it. Install state, the custom command, and the executable browser all
/// live here, so a session's chat surface carries none of that plumbing.
@MainActor
final class AgentsSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let settings: AgentSettings
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var catalog: AgentCatalog

    private let detailTitle = NSTextField(labelWithString: "")
    private let detailBadge = NSTextField(labelWithString: "")
    private let statusLabel = WrappingLabel(wrappingLabelWithString: "")
    private let setupLabel = WrappingLabel(wrappingLabelWithString: "")
    private let commandField = NSTextField(string: "")
    private let browse = NSButton(title: "Choose Executable…", target: nil, action: nil)
    private let copyCommand = NSButton(title: "Copy Command", target: nil, action: nil)
    private let enableSwitch = NSSwitch()
    private let enableLabel = NSTextField(labelWithString: "Offer in the composer")
    private let commandCaption = NSTextField(labelWithString: "Command")
    private let detail = NSStackView()

    private var selected: AgentPreset = .fx

    /// Tests and smoke runs pass their own settings and a fixed environment so no check
    /// reads the developer's real agents or writes their real preferences.
    init(settings: AgentSettings = .shared, environment: AgentLaunchEnvironment? = nil) {
        self.settings = settings
        catalog = AgentCatalog(environment: environment ?? AgentLaunchEnvironment(),
                               customCommand: settings.customCommand)
        super.init(nibName: nil, bundle: nil)
        title = "Agents"
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        buildList()
        buildDetail()
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalToConstant: 232),
            detail.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            detail.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        selected = settings.suggested(in: catalog)
        table.reloadData()
        selectRow(for: selected)
        refreshDetail()
    }

    /// Opening the pane rescans: installing a CLI and coming back here is the whole
    /// recovery path, and it must not need a separate refresh control to work.
    override func viewWillAppear() {
        super.viewWillAppear()
        rescan()
    }

    private func buildList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 48
        table.usesAutomaticRowHeights = false
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Agents")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
    }

    private func buildDetail() {
        detailTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        detailBadge.font = .systemFont(ofSize: 11, weight: .medium)
        detailBadge.textColor = .secondaryLabelColor
        for label in [statusLabel, setupLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        commandCaption.font = .systemFont(ofSize: 11, weight: .medium)
        commandField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandField.delegate = self
        commandField.placeholderString = "agent acp"
        commandField.setAccessibilityLabel("ACP agent command")
        commandField.toolTip = "Executable name or path and arguments. Quotes are supported; shell expansion is not."
        browse.target = self
        browse.action = #selector(chooseExecutable)
        browse.bezelStyle = .rounded
        browse.controlSize = .small
        copyCommand.target = self
        copyCommand.action = #selector(copyLaunchCommand)
        copyCommand.bezelStyle = .rounded
        copyCommand.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(toggleEnabled)
        enableSwitch.setAccessibilityLabel("Offer in the composer")
        enableLabel.font = .systemFont(ofSize: 12)

        let heading = NSStackView(views: [detailTitle, detailBadge, NSView()])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 8
        let toggleRow = NSStackView(views: [enableSwitch, enableLabel, NSView()])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .centerY
        toggleRow.spacing = 8
        let buttonRow = NSStackView(views: [browse, copyCommand, NSView()])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10
        detail.translatesAutoresizingMaskIntoConstraints = false
        for row in [heading, statusLabel, toggleRow, separator(), commandCaption, commandField, setupLabel, buttonRow] as [NSView] {
            detail.addArrangedSubview(row)
        }
        view.addSubview(detail)
        for row in detail.arrangedSubviews {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: Data

    private func rescan() {
        catalog = AgentCatalog(environment: AgentLaunchEnvironment(), customCommand: settings.customCommand)
        table.reloadData()
        selectRow(for: selected)
        refreshDetail()
    }

    private func selectRow(for preset: AgentPreset) {
        guard let index = AgentPreset.allCases.firstIndex(of: preset) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { AgentPreset.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let status = catalog.status(for: AgentPreset.allCases[row])
        let identifier = NSUserInterfaceItemIdentifier("agentRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? AgentRowView ?? {
            let cell = AgentRowView()
            cell.identifier = identifier
            return cell
        }()
        cell.configure(status: status, enabled: settings.isEnabled(status.preset))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        selected = AgentPreset.allCases[table.selectedRow]
        refreshDetail()
    }

    private func refreshDetail() {
        let status = catalog.status(for: selected)
        detailTitle.stringValue = status.title
        detailBadge.stringValue = status.readiness.badge
        switch status.readiness {
        case let .installed(path):
            statusLabel.stringValue = path
            statusLabel.textColor = .secondaryLabelColor
        case .installsOnFirstUse:
            statusLabel.stringValue = "Downloaded the first time a session connects. Node.js and npm are already in place."
            statusLabel.textColor = .secondaryLabelColor
        case let .unavailable(problem):
            statusLabel.stringValue = problem
            statusLabel.textColor = .systemRed
        case let .unconfigured(detail):
            // Nothing is broken here, so this is not an error colour.
            statusLabel.stringValue = detail
            statusLabel.textColor = .secondaryLabelColor
        }
        statusLabel.toolTip = statusLabel.stringValue
        enableSwitch.state = settings.isEnabled(selected) ? .on : .off
        let isCustom = selected == .custom
        commandField.isEditable = isCustom
        commandField.isSelectable = true
        commandField.stringValue = isCustom ? settings.customCommand : status.command
        commandField.textColor = isCustom ? .labelColor : .secondaryLabelColor
        commandCaption.stringValue = isCustom ? "Command" : "Launch command"
        browse.isHidden = !isCustom
        copyCommand.isEnabled = !status.command.isEmpty
        setupLabel.stringValue = status.setup ?? ""
        setupLabel.isHidden = (status.setup ?? "").isEmpty
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        settings.setEnabled(enableSwitch.state == .on, for: selected)
        table.reloadData()
        selectRow(for: selected)
    }

    /// Drives the real row selection so a test exercises the production path.
    func smokeSelect(_ preset: AgentPreset) {
        selectRow(for: preset)
        // Selecting a row that is already selected posts no notification.
        selected = preset
        refreshDetail()
    }

    /// Clicks the real switch, which both flips it and fires its action, exactly as a
    /// click does. Setting the state first would make the click flip it back.
    func smokeSetEnabled(_ enabled: Bool) {
        guard (enableSwitch.state == .on) != enabled else { return }
        enableSwitch.performClick(nil)
    }

    @objc private func copyLaunchCommand() {
        let command = catalog.status(for: selected).command
        guard !command.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard selected == .custom else { return }
        settings.setCustomCommand(commandField.stringValue)
        rescan()
    }

    @objc private func chooseExecutable() {
        guard let window = view.window, selected == .custom else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Executable"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let arguments = (try? AgentCommand(self.settings.customCommand))?.arguments ?? []
            let command = ([url.path] + arguments).map(AgentCommand.quotedArgument).joined(separator: " ")
            self.settings.setCustomCommand(command)
            self.rescan()
        }
    }
}

/// One agent in the list: name, what state it is in, and whether the composer offers it.
@MainActor
private final class AgentRowView: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let dot = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        for view in [dot, name, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = name
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func configure(status: AgentStatus, enabled: Bool) {
        name.stringValue = status.title
        // A disabled agent still reports its real state; it is simply not offered.
        detail.stringValue = enabled ? status.readiness.badge : "Not offered"
        let tint: NSColor = switch status.readiness {
        case .installed: .systemGreen
        case .installsOnFirstUse: .systemTeal
        case .unavailable, .unconfigured: .tertiaryLabelColor
        }
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.contentTintColor = enabled ? tint : .quaternaryLabelColor
        name.textColor = enabled ? .labelColor : .secondaryLabelColor
        setAccessibilityLabel("\(status.title), \(detail.stringValue)")
    }
}
