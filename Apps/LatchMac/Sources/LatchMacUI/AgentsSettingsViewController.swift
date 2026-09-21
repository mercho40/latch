import AppKit

/// The Agents pane: one row per harness Latch can launch, saying what state it is in, with a
/// switch for whether the agent menu offers it. The custom agent's command is the only thing
/// here that is typed. Everything a row does not need to say stays in its tooltip.
@MainActor
final class AgentsSettingsViewController: NSViewController, NSTextFieldDelegate {
    private let settings: AgentSettings
    private var catalog: AgentCatalog
    /// Tests and smoke runs pin the environment; a real pane rescans the filesystem.
    private let injectedEnvironment: AgentLaunchEnvironment?

    private var rows: [AgentPreset: AgentRowView] = [:]
    private let commandField = NSTextField(string: "")
    private let browse = NSButton(title: "Choose…", target: nil, action: nil)
    private var selected: AgentPreset = .fx

    /// Tests and smoke runs pass their own settings and a fixed environment so no check
    /// reads the developer's real agents or writes their real preferences.
    init(settings: AgentSettings = .shared, environment: AgentLaunchEnvironment? = nil) {
        self.settings = settings
        injectedEnvironment = environment
        catalog = AgentCatalog(environment: environment ?? AgentLaunchEnvironment(),
                               customCommand: settings.customCommand)
        super.init(nibName: nil, bundle: nil)
        title = "Agents"
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func loadView() {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        for (index, preset) in AgentPreset.allCases.enumerated() {
            if index > 0 { list.addArrangedSubview(Self.separator()) }
            let row = AgentRowView { [weak self] enabled in self?.setEnabled(enabled, for: preset) }
            rows[preset] = row
            list.addArrangedSubview(row)
        }
        let group = Self.group(list)

        commandField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .regular)
        commandField.delegate = self
        commandField.placeholderString = "agent acp"
        commandField.setAccessibilityLabel("Custom ACP agent command")
        commandField.toolTip = "Executable name or path and arguments. Quotes are supported; shell expansion is not."
        browse.target = self
        browse.action = #selector(chooseExecutable)
        browse.bezelStyle = .rounded
        browse.setContentHuggingPriority(.required, for: .horizontal)
        let caption = NSTextField(labelWithString: "Custom agent command")
        let commandRow = NSStackView(views: [commandField, browse])
        commandRow.orientation = .horizontal
        commandRow.spacing = 8

        let content = NSStackView(views: [group, caption, commandRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(20, after: group)
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in list.arrangedSubviews { view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        for view in [group, commandRow] { view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true }

        view = NSView()
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 460),
        ])
        selected = settings.suggested(in: catalog)
        refresh()
    }

    /// Opening the pane rescans: installing a CLI and coming back here is the whole
    /// recovery path, and it must not need a separate refresh control to work.
    override func viewWillAppear() {
        super.viewWillAppear()
        rescan()
    }

    /// Opening Settings is not a request to flip the first switch, so nothing starts with the focus ring.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    /// The system's own grouped-box look, which follows the appearance and the OS release.
    private static func group(_ content: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .primary
        box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 0, height: 0)
        box.contentView = content
        return box
    }

    private static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: Data

    private func rescan() {
        catalog = AgentCatalog(environment: injectedEnvironment ?? AgentLaunchEnvironment(),
                               customCommand: settings.customCommand)
        refresh()
    }

    private func refresh() {
        for (preset, row) in rows {
            row.configure(status: catalog.status(for: preset), enabled: settings.isEnabled(preset))
        }
        if commandField.currentEditor() == nil { commandField.stringValue = settings.customCommand }
    }

    // MARK: Actions

    private func setEnabled(_ enabled: Bool, for preset: AgentPreset) {
        settings.setEnabled(enabled, for: preset)
        refresh()
    }

    /// Names the row the next `smokeSetEnabled` acts on.
    func smokeSelect(_ preset: AgentPreset) { selected = preset }

    /// Clicks the real switch, which both flips it and fires its action, exactly as a click does.
    func smokeSetEnabled(_ enabled: Bool) { rows[selected]?.smokeSetEnabled(enabled) }

    func controlTextDidEndEditing(_ obj: Notification) {
        settings.setCustomCommand(commandField.stringValue)
        rescan()
    }

    @objc private func chooseExecutable() {
        guard let window = view.window else { return }
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
            self.commandField.abortEditing()
            self.rescan()
        }
    }
}

/// One agent: its name, one line about its state, and whether the agent menu offers it.
@MainActor
private final class AgentRowView: NSView {
    private let name = NSTextField(labelWithString: "")
    private let detail = WrappingLabel(wrappingLabelWithString: "")
    private let toggle = NSSwitch()
    private let onToggle: (Bool) -> Void

    init(onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [name, detail, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            name.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func configure(status: AgentStatus, enabled: Bool) {
        name.stringValue = status.title
        // The line says what the reader can act on: what is missing, or that nothing is.
        detail.stringValue = status.readiness.problem ?? status.readiness.badge
        toggle.state = enabled ? .on : .off
        toggle.setAccessibilityLabel("Offer \(status.title) in the agent menu")
        // Where it was found and what is left to do are there for whoever looks, not for everyone.
        var tip: [String] = []
        if case let .installed(path) = status.readiness { tip.append(path) }
        if let guidance = status.guidance { tip.append(guidance) }
        toolTip = tip.isEmpty ? nil : tip.joined(separator: "\n")
        setAccessibilityLabel("\(status.title), \(detail.stringValue)")
    }

    @objc private func toggled() { onToggle(toggle.state == .on) }

    func smokeSetEnabled(_ enabled: Bool) {
        guard (toggle.state == .on) != enabled else { return }
        toggle.performClick(nil)
    }
}
