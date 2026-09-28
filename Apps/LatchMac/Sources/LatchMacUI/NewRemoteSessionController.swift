import AppKit
import LatchAgentCore
import LatchRemoteProtocol
import LatchSessionKit

/// Session ▸ New Remote Session…: which server, which folder on it, which agent. Latch cannot
/// browse a server's folders, so the folder is typed, starting from the server's home, which
/// one handshake reports.
@MainActor
final class NewRemoteSessionController: NSWindowController, NSTextFieldDelegate {
    struct Choice: Equatable {
        let serverID: UUID
        let path: String
        let agent: AgentPreset
    }

    /// Called once: with the choice on Create, nil on Cancel.
    var onFinish: ((Choice?) -> Void)?

    private let servers: [ServerProfile]
    private let check: ServerCheck
    let serverPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let pathField = NSTextField(string: "")
    let agentPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spinner = NSProgressIndicator()
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// Once the folder is typed in, a home folder arriving late must not replace it.
    private var pathEdited = false
    private var homeFetch: Task<Void, Never>?
    private var fetchGeneration = UUID()
    private(set) var isFetchingHome = false

    init(servers: [ServerProfile], check: @escaping ServerCheck) {
        self.servers = servers
        self.check = check
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        panel.title = "New Remote Session"
        super.init(window: panel)
        build(in: panel)
        for server in servers {
            serverPopUp.addItem(withTitle: "\(server.name) — \(server.address)")
            serverPopUp.lastItem?.representedObject = server.id
        }
        serverPopUp.selectItem(at: 0)
        refreshAgents()
        // Sized once the pop-ups hold their items, so the sheet is measured as it will show.
        if let view = panel.contentView { panel.setContentSize(view.fittingSize) }
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    var selectedServer: ServerProfile? {
        servers.indices.contains(serverPopUp.indexOfSelectedItem) ? servers[serverPopUp.indexOfSelectedItem] : nil
    }

    var selectedAgent: AgentPreset? {
        (agentPopUp.selectedItem?.representedObject as? String).flatMap(AgentPreset.init(rawValue:))
    }

    var canCreate: Bool {
        selectedServer != nil && selectedAgent != nil
            && !pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func begin(over parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        fetchHome()
    }

    /// Waits for the home folder request in flight, for tests.
    func homeFetched() async { await homeFetch?.value }

    private func build(in panel: NSPanel) {
        let heading = NSTextField(labelWithString: "New Remote Session")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        serverPopUp.target = self
        serverPopUp.action = #selector(serverChanged)
        serverPopUp.setAccessibilityLabel("Server")
        pathField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .regular)
        pathField.delegate = self
        pathField.setAccessibilityLabel("Folder on the server")
        pathField.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        let pathRow = NSStackView(views: [pathField, spinner])
        pathRow.orientation = .horizontal
        pathRow.spacing = 6
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathRow.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        let caption = NSTextField(labelWithString: "A folder on the server. The agent works there.")
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        agentPopUp.target = self
        agentPopUp.action = #selector(agentChanged)
        agentPopUp.setAccessibilityLabel("Agent")
        // A long server name or an IPv6 address truncates in the button instead of widening
        // the sheet past its window; the open menu still shows it whole.
        for popUp in [serverPopUp, agentPopUp] {
            popUp.cell?.lineBreakMode = .byTruncatingTail
            popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popUp.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Server:"), serverPopUp],
            [NSTextField(labelWithString: "Folder:"), pathRow],
            [NSGridCell.emptyContentView, caption],
            [NSTextField(labelWithString: "Agent:"), agentPopUp],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.row(at: 2).topPadding = -6

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(create)
        createButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancelButton, createButton], in: .trailing)
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
    }

    private static let fieldWidth: CGFloat = 300

    // MARK: Server and agent

    /// Presets are always offered: whether one is installed is the server's to say, when it
    /// launches. Custom appears only when this server has a command for it.
    private func refreshAgents() {
        let previous = selectedAgent
        agentPopUp.removeAllItems()
        let hasCustom = !(selectedServer?.customCommand.isEmpty ?? true)
        for preset in AgentPreset.allCases where preset != .custom || hasCustom {
            agentPopUp.addItem(withTitle: preset.title)
            agentPopUp.lastItem?.representedObject = preset.rawValue
        }
        if let previous, let index = agentPopUp.itemArray.firstIndex(where: { $0.representedObject as? String == previous.rawValue }) {
            agentPopUp.selectItem(at: index)
        } else {
            agentPopUp.selectItem(at: 0)
        }
        refreshButtons()
    }

    @objc private func serverChanged() {
        refreshAgents()
        fetchHome()
    }

    @objc private func agentChanged() { refreshButtons() }

    /// Test hook: picks a server the way the pop-up does.
    func selectServer(at index: Int) {
        serverPopUp.selectItem(at: index)
        serverChanged()
    }

    /// Asks the server for its home folder, the default workspace. Nothing is sent before the
    /// sheet is on screen, and a server that cannot be reached leaves `~`, which the server
    /// resolves when the agent launches.
    private func fetchHome() {
        homeFetch?.cancel()
        guard let server = selectedServer else { return }
        let generation = UUID()
        fetchGeneration = generation
        isFetchingHome = true
        spinner.startAnimation(nil)
        if !pathEdited { pathField.stringValue = "" }
        pathField.placeholderString = "Finding the home folder on \(server.name)…"
        refreshButtons()
        let check = check
        let options = server.connectionOptions
        homeFetch = Task { [weak self] in
            let home = try? await check(options).home
            guard let self, self.fetchGeneration == generation, !Task.isCancelled else { return }
            self.isFetchingHome = false
            self.spinner.stopAnimation(nil)
            self.pathField.placeholderString = "Path on the server"
            if !self.pathEdited { self.pathField.stringValue = home.flatMap { $0.isEmpty ? nil : $0 } ?? "~" }
            self.refreshButtons()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        pathEdited = !pathField.stringValue.isEmpty
        refreshButtons()
    }

    private func refreshButtons() { createButton.isEnabled = canCreate }

    // MARK: Finishing

    @objc func create() {
        guard canCreate, let server = selectedServer, let agent = selectedAgent else { return }
        finish(Choice(serverID: server.id, path: pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                      agent: agent))
    }

    @objc func cancel() { finish(nil) }

    private func finish(_ choice: Choice?) {
        homeFetch?.cancel()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        let handler = onFinish
        onFinish = nil
        handler?(choice)
    }
}
