import AppKit

/// One ACP session: agent selection, settings, transcript, and composer.
/// The workspace is fixed at creation; the sidebar owns the list of sessions.
@MainActor
final class SessionViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    let model = SessionModel()
    let id: UUID
    let workspace: URL
    private var pendingNewContext = false

    /// No view loading or process launch is needed to save an unopened sidebar row.
    var savedSession: SavedSession {
        let newContext = pendingNewContext || commandDirty
        return SavedSession(id: id, workspacePath: workspace.path, title: sessionTitle,
                     agentID: selectedAgent.rawValue,
                     customCommand: selectedAgent == .custom && isViewLoaded ? command.stringValue : customCommand,
                     draft: prompt.string,
                     messages: newContext ? [] : model.messages,
                     agentSessionID: newContext ? nil : model.savedAgentSessionID)
    }
    /// Derived from the first prompt; the sidebar and window title show it.
    private(set) var sessionTitle = "New Session"
    var onChange: (() -> Void)?

    /// Built-in connections use the chosen provider name, not the protocol executable's identity.
    var displayStatus: String {
        if selectedAgent != .custom, model.status.hasPrefix("Connected · ") {
            return "Connected · \(selectedAgent.title)"
        }
        return model.status
    }

    private var permissionAlert: (id: UUID, alert: NSAlert, escapeMonitor: Any?)?
    private let command = NSTextField(string: "")
    private let agents = NSPopUpButton(frame: .zero, pullsDown: false)
    private let agentHint = SettingsWrappingLabel(wrappingLabelWithString: "")
    private let browse = NSButton(title: "Choose Executable…", target: nil, action: nil)
    private var launchEnvironment: AgentLaunchEnvironment
    private let injectedLaunchEnvironment: AgentLaunchEnvironment?
    private var drainTask: Task<Void, Never>?
    private var commandEditing = false
    private var commandDirty = false
    private var selectedAgent: AgentPreset = .custom
    private var customCommand = ""
    private var selectedRecipe: AgentLaunchRecipe?
    private var launchProblem: String?
    private var operation: UUID?
    private var operationTask: Task<Void, Never>?
    private var changingConfiguration = false
    private var actionGeneration = UUID()
    private let composerBox = ChatComposerBox()
    private var shuttingDown = false
    private let status = NSTextField(labelWithString: "Not connected")
    private let error = SettingsWrappingLabel(wrappingLabelWithString: "")
    private let conversation = ChatTranscriptView(frame: .zero)
    private let prompt = ChatInputView(frame: .zero)
    private let connectionDetails = NSStackView()
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let permissionModePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var composerControls = ComposerControlsView(
        pickers: [modelPicker, effortPicker, permissionModePicker], actions: [cancel, send])
    private var renderedConfiguration: SessionConfiguration?
    private var renderedPickerPlaceholder: String?

    init(workspace: URL, launchEnvironment: AgentLaunchEnvironment? = nil, savedSession: SavedSession? = nil) {
        self.id = savedSession?.id ?? UUID()
        self.workspace = workspace
        self.injectedLaunchEnvironment = launchEnvironment
        self.launchEnvironment = launchEnvironment ?? AgentLaunchEnvironment()
        selectedAgent = savedSession.flatMap { AgentPreset(rawValue: $0.agentID) } ?? AgentPreset.suggested(in: self.launchEnvironment)
        super.init(nibName: nil, bundle: nil)
        if let savedSession {
            sessionTitle = savedSession.title
            customCommand = savedSession.customCommand
            prompt.string = savedSession.draft
            model.restore(messages: savedSession.messages, agentSessionID: savedSession.agentSessionID)
        }
        model.onChange = { [weak self] in
            self?.refresh()
            self?.onChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func loadView() {
        view = NSView()
        buildContent()
        updateAgentCommand()
        initializeSelection()
    }

    private func buildContent() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        agents.addItems(withTitles: AgentPreset.allCases.map(\.title))
        agents.selectItem(at: AgentPreset.allCases.firstIndex(of: selectedAgent)!)
        agents.target = self
        agents.action = #selector(selectAgent)
        agents.setAccessibilityLabel("ACP agent")
        agents.setContentCompressionResistancePriority(.required, for: .horizontal)
        command.placeholderString = "agent acp"
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.delegate = self
        command.setAccessibilityLabel("ACP agent command")
        command.toolTip = "Executable name or path and arguments. Quotes are supported; shell expansion is not."
        command.setContentHuggingPriority(.defaultLow, for: .horizontal)
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(row([agents, status]))
        connectionDetails.orientation = .vertical
        connectionDetails.alignment = .leading
        connectionDetails.spacing = 8
        connectionDetails.addArrangedSubview(command)
        agentHint.font = .systemFont(ofSize: 11)
        agentHint.textColor = .secondaryLabelColor
        agentHint.maximumNumberOfLines = 0
        agentHint.setContentCompressionResistancePriority(.required, for: .vertical)
        agentHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browse.target = self
        browse.action = #selector(chooseExecutable)
        browse.bezelStyle = .rounded
        connectionDetails.addArrangedSubview(agentHint)
        browse.setContentCompressionResistancePriority(.required, for: .horizontal)
        browse.setContentCompressionResistancePriority(.required, for: .vertical)
        connectionDetails.addArrangedSubview(row([browse, NSView()]))
        for item in connectionDetails.arrangedSubviews {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: connectionDetails.widthAnchor).isActive = true
        }
        root.addArrangedSubview(connectionDetails)
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 12)
        error.setAccessibilityLabel("Session error")
        error.maximumNumberOfLines = 0
        error.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        error.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addArrangedSubview(error)
        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)

        conversation.setAccessibilityLabel("Conversation")
        // Expanded settings/errors may need the space at the minimum window size.
        let transcriptHeight = conversation.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        transcriptHeight.priority = .defaultHigh
        transcriptHeight.isActive = true
        conversation.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        root.addArrangedSubview(conversation)

        let composerContent = NSStackView()
        composerContent.orientation = .vertical
        composerContent.alignment = .leading
        composerContent.spacing = 8
        composerContent.translatesAutoresizingMaskIntoConstraints = false
        composerBox.addSubview(composerContent)
        NSLayoutConstraint.activate([
            composerContent.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 10),
            composerContent.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor, constant: -10),
            composerContent.topAnchor.constraint(equalTo: composerBox.topAnchor, constant: 8),
            composerContent.bottomAnchor.constraint(equalTo: composerBox.bottomAnchor, constant: -8),
        ])
        for picker in [modelPicker, effortPicker, permissionModePicker] {
            picker.controlSize = .large
            picker.bezelStyle = .rounded
            picker.font = .systemFont(ofSize: 14)
            picker.menu?.font = .systemFont(ofSize: 14)
            picker.target = self
            picker.cell?.lineBreakMode = .byTruncatingTail
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            picker.setContentHuggingPriority(.required, for: .horizontal)
            picker.menu?.autoenablesItems = false
        }
        modelPicker.action = #selector(selectModel)
        effortPicker.action = #selector(selectEffort)
        permissionModePicker.action = #selector(selectPermissionMode)
        modelPicker.setAccessibilityLabel("Session model")
        effortPicker.setAccessibilityLabel("Reasoning effort")
        permissionModePicker.setAccessibilityLabel("Permission mode")
        let composer = NSScrollView()
        composer.borderType = .noBorder
        composer.drawsBackground = false
        prompt.drawsBackground = false
        prompt.onSubmit = { [weak self] in self?.sendPrompt() }
        prompt.font = .systemFont(ofSize: 14)
        prompt.textContainerInset = NSSize(width: 8, height: 8)
        prompt.isRichText = false
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.delegate = self
        prompt.setAccessibilityLabel("Message to agent")
        configureTextView(prompt, in: composer)
        composer.heightAnchor.constraint(equalToConstant: 88).isActive = true
        composerContent.addArrangedSubview(composer)

        send.target = self
        send.action = #selector(sendPrompt)
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        cancel.target = self
        cancel.action = #selector(cancelPrompt)
        cancel.bezelStyle = .rounded
        send.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send message")
        cancel.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop response")
        for button in [send, cancel] {
            button.imagePosition = .imageOnly
            button.controlSize = .large
        }
        send.setAccessibilityLabel("Send message")
        send.toolTip = "Send message (Return or ⌘ Return)"
        cancel.setAccessibilityLabel("Stop response")
        cancel.toolTip = "Stop the current response"
        composerContent.addArrangedSubview(composerControls)
        for item in composerContent.arrangedSubviews {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: composerContent.widthAnchor).isActive = true
        }
        let composerContainer = NSView()
        composerBox.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.addSubview(composerBox)
        let preferredWidth = composerBox.widthAnchor.constraint(equalTo: composerContainer.widthAnchor, constant: -32)
        // Stretches the box to the container; the required inset constraints above already
        // bound it to `container - 32`. Priority must stay below the 500 that AppKit gives
        // the window's own width, or this preference becomes the window's maximum width and
        // the window cannot be widened past the 768 cap plus insets. Above content hugging
        // (250) so the box still fills a narrow container instead of shrinking to its content.
        preferredWidth.priority = NSLayoutConstraint.Priority(400)
        NSLayoutConstraint.activate([
            composerBox.centerXAnchor.constraint(equalTo: composerContainer.centerXAnchor),
            composerBox.leadingAnchor.constraint(greaterThanOrEqualTo: composerContainer.leadingAnchor, constant: 16),
            composerBox.trailingAnchor.constraint(lessThanOrEqualTo: composerContainer.trailingAnchor, constant: -16),
            composerBox.widthAnchor.constraint(lessThanOrEqualToConstant: ChatTranscriptView.maximumContentWidth),
            preferredWidth,
            composerBox.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composerBox.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
        ])
        root.addArrangedSubview(composerContainer)
        for view in root.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func configureTextView(_ text: NSTextView, in scroll: NSScrollView) {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
    }

    private func refresh() {
        guard isViewLoaded else { return }
        refreshPermission()
        let disconnected = model.phase == .disconnected
        let editable = canEditLaunch
        agents.isEnabled = editable
        browse.isEnabled = editable
        browse.isHidden = selectedAgent != .custom
        command.isHidden = selectedAgent != .custom
        command.isEnabled = editable
        command.isEditable = editable && selectedAgent == .custom
        status.stringValue = displayStatus
        let failure = model.errorMessage.map { message in
            selectedAgent != .custom && disconnected ? startupError(message) : message
        } ?? launchProblem
        error.stringValue = failure ?? ""
        error.isHidden = failure == nil
        // Drafting can continue during connection setup; only a queued send locks the ready composer.
        prompt.isEditable = !shuttingDown && (operation == nil || model.phase != .ready)
        refreshPickers()
        send.isEnabled = !shuttingDown && operation == nil && !changingConfiguration && model.phase == .ready && !commandEditing && !commandDirty && !model.isChangingConfiguration && !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let preparing = operation != nil || model.phase == .connecting
        cancel.isEnabled = !shuttingDown && model.phase != .stopping && (preparing || (model.phase == .prompting && !model.cancellationRequested))
        cancel.isHidden = !preparing && model.phase != .prompting
        composerControls.refreshLayout()
        // Launch details exist only for a user-supplied command; built-in agents report
        // problems through the error label, so there is nothing to reveal or toggle.
        connectionDetails.isHidden = selectedAgent != .custom
        prompt.placeholder = "Message \(selectedAgent.title)…"
        prompt.needsDisplay = true
        conversation.update(messages: model.messages, isWorking: model.phase == .prompting)
    }

    private func startupError(_ message: String) -> String {
        // Preserve the actual failure, but keep launch implementation details out of built-in UI.
        var detail = message
        if let recipe = selectedRecipe, let parsed = try? AgentCommand(recipe.command) {
            let internals = [recipe.command, launchEnvironment.executable(named: parsed.executable),
                             parsed.executable] + parsed.arguments.filter { $0.hasPrefix("@agentclientprotocol/") }.map(Optional.some)
            for value in internals.compactMap({ $0 }).sorted(by: { $0.count > $1.count }) {
                detail = detail.replacingOccurrences(of: value, with: selectedAgent.title)
            }
        }
        return "\(detail) \(selectedRecipe?.setup ?? "")"
    }

    private func refreshPickers() {
        let placeholder = model.phase == .disconnected || model.phase == .connecting ? "Available after connection" : "Not available"
        if renderedConfiguration != model.configuration || renderedPickerPlaceholder != placeholder {
            populate(modelPicker, from: model.configuration.model, placeholder: placeholder)
            populate(effortPicker, from: model.configuration.effort, placeholder: placeholder)
            populate(permissionModePicker, from: model.configuration.permissionMode, placeholder: placeholder)
            renderedConfiguration = model.configuration
            renderedPickerPlaceholder = placeholder
        }
        let editable = model.phase == .ready && operation == nil && !changingConfiguration && !model.isChangingConfiguration && !shuttingDown
        modelPicker.isHidden = model.configuration.model?.choices.isEmpty ?? true
        effortPicker.isHidden = model.configuration.effort?.choices.isEmpty ?? true
        modelPicker.isEnabled = editable && !(model.configuration.model?.choices.isEmpty ?? true)
        effortPicker.isEnabled = editable && !(model.configuration.effort?.choices.isEmpty ?? true)
        permissionModePicker.isHidden = model.configuration.permissionMode?.choices.isEmpty ?? true
        permissionModePicker.isEnabled = editable && !permissionModePicker.isHidden
        composerControls.refreshLayout()
    }

    private func populate(_ button: NSPopUpButton, from picker: SessionPicker?, placeholder: String) {
        button.removeAllItems()
        guard let picker else {
            button.addItem(withTitle: placeholder)
            button.toolTip = placeholder == "Available after connection" ? "Options are supplied when the selected harness connects." : "This agent does not expose this setting for the current session."
            return
        }
        var lastGroup: String?
        var selected: NSMenuItem?
        for choice in picker.choices {
            if let group = choice.group, group != lastGroup {
                let header = NSMenuItem(title: group, action: nil, keyEquivalent: "")
                header.isEnabled = false
                button.menu?.addItem(header)
            }
            lastGroup = choice.group
            let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
            item.representedObject = choice.value
            item.toolTip = choice.description
            item.indentationLevel = choice.group == nil ? 0 : 1
            button.menu?.addItem(item)
            if choice.value == picker.currentValue { selected = item }
        }
        if selected == nil {
            let unavailable = NSMenuItem(title: "Current: \(picker.currentValue)", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            button.menu?.insertItem(unavailable, at: 0)
            selected = unavailable
        }
        button.select(selected)
        button.toolTip = picker.description ?? selected?.toolTip ?? selected?.title
    }

    @objc private func selectModel() { select(.model, from: modelPicker) }
    @objc private func selectEffort() { select(.effort, from: effortPicker) }
    @objc private func selectPermissionMode() { select(.permissionMode, from: permissionModePicker) }

    private func select(_ kind: SessionPicker.Kind, from button: NSPopUpButton) {
        guard operation == nil, !changingConfiguration, !shuttingDown,
              let value = button.selectedItem?.representedObject as? String else { return }
        changingConfiguration = true
        let generation = actionGeneration
        // A pop-up selects optimistically; restore the confirmed value until the reply arrives.
        renderedConfiguration = nil
        refreshPickers()
        refresh()
        Task {
            defer { changingConfiguration = false; refresh() }
            guard !shuttingDown, generation == actionGeneration else { return }
            await model.select(kind, value: value)
        }
    }

    private func refreshPermission() {
        guard let window = view.window else { return }
        let pending = model.permissions.current
        if let existing = permissionAlert {
            if existing.id != pending?.id { window.endSheet(existing.alert.window, returnCode: .abort) }
            return
        }
        guard let pending else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Agent requests permission"
        alert.informativeText = "Review the agent-provided tool details below. “Always” uses the agent’s scope, not a saved Latch preference. Cancelling this request does not sandbox the agent."
        // Return and Escape both cancel. No approval receives a default key equivalent.
        alert.addButton(withTitle: "Cancel Request").keyEquivalent = "\r"
        for option in pending.options { alert.addButton(withTitle: option.permissionLabel!).keyEquivalent = "" }
        let details = NSTextView()
        details.isEditable = false
        details.isSelectable = true
        details.isRichText = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.setAccessibilityLabel("Agent-provided permission request details")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(pending.request), let text = String(data: data, encoding: .utf8) else {
            model.permissions.resolve(id: pending.id, optionID: nil)
            return
        }
        details.string = text
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scroll.borderType = .bezelBorder
        configureTextView(details, in: scroll)
        alert.accessoryView = scroll
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
            guard let alert, event.window === alert.window, event.keyCode == 53 else { return event }
            alert.buttons.first?.performClick(nil)
            return nil
        }
        permissionAlert = (pending.id, alert, escapeMonitor)
        alert.beginSheetModal(for: window) { [weak self] response in
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            guard let self, self.permissionAlert?.id == pending.id else { return }
            self.permissionAlert = nil
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue - 1
            let optionID = pending.options.indices.contains(index) ? pending.options[index].optionId : nil
            self.model.permissions.resolve(id: pending.id, optionID: optionID)
            self.refreshPermission()
        }
    }

    /// Permission sheets need a window; a session selected while a request is pending attaches it now.
    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    func textDidChange(_ notification: Notification) { refresh(); onChange?() }
    func controlTextDidBeginEditing(_ obj: Notification) {
        commandEditing = true
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard selectedAgent == .custom, canEditLaunch else { return }
        commandDirty = customCommand != command.stringValue
        updateAgentHint()
        refresh()
        // An edited command cannot resume context belonging to the previous command.
        // Do not associate the previous agent ID with uncommitted command text on disk.
        onChange?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commandEditing = false
        guard selectedAgent == .custom, canEditLaunch else { refresh(); return }
        let changed = customCommand != command.stringValue
        if changed { pendingNewContext = true }
        customCommand = command.stringValue
        commandDirty = false
        if changed || model.phase == .disconnected {
            rescanLaunchEnvironment()
            updateAgentCommand()
            initializeSelection()
        }
        else { refresh() }
    }

    private var canEditLaunch: Bool {
        !shuttingDown && !changingConfiguration && !model.isChangingConfiguration &&
            model.phase != .prompting
    }

    @objc private func selectAgent() {
        guard canEditLaunch else { return }
        let selection = AgentPreset.allCases[agents.indexOfSelectedItem]
        // Selecting an agent rescans, so installing a prerequisite then reselecting is
        // the whole recovery path. There is no separate refresh control.
        rescanLaunchEnvironment()
        if selectedAgent == .custom {
            commandDirty = customCommand != command.stringValue
            customCommand = command.stringValue
        }
        let unchanged = selection == selectedAgent && !commandDirty
        if !unchanged { pendingNewContext = true }
        selectedAgent = selection
        commandEditing = false
        commandDirty = false
        updateAgentCommand()
        if unchanged && operation == nil && model.phase == .ready {
            refresh()
            return
        }
        initializeSelection()
    }

    /// Re-reads installed agents and Node locations from the filesystem. Tests inject a
    /// fixed environment, which must not be replaced by a real scan.
    private func rescanLaunchEnvironment() {
        guard injectedLaunchEnvironment == nil else { return }
        launchEnvironment = AgentLaunchEnvironment()
    }

    private func updateAgentCommand() {
        selectedRecipe = selectedAgent.recipe(in: launchEnvironment)
        command.stringValue = selectedRecipe?.command ?? customCommand
        updateAgentHint()
    }

    private func updateAgentHint() {
        launchProblem = selectedRecipe?.problem(in: launchEnvironment)
        if selectedAgent != .custom {
            agentHint.stringValue = launchProblem ?? selectedRecipe?.setup ?? ""
        } else {
            do {
                let resolved = try launchEnvironment.resolve(AgentCommand(command.stringValue))
                agentHint.stringValue = "Found: \(resolved.executable)"
            } catch {
                launchProblem = error.localizedDescription
                agentHint.stringValue = launchProblem!
            }
        }
        agentHint.toolTip = agentHint.stringValue
    }

    @objc private func chooseExecutable() {
        guard let window = view.window, selectedAgent == .custom, canEditLaunch else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Executable"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, self.selectedAgent == .custom, self.canEditLaunch else { return }
            let arguments = (try? AgentCommand(self.command.stringValue))?.arguments ?? []
            let command = ([url.path] + arguments).map(AgentCommand.quotedArgument).joined(separator: " ")
            if command != self.customCommand { self.pendingNewContext = true }
            self.customCommand = command
            self.updateAgentCommand()
            self.commandEditing = false
            self.commandDirty = false
            self.initializeSelection()
        }
    }

    /// Serialize teardown, asking the model to unblock initialization BEFORE awaiting it.
    private func drainConnection() -> Task<Void, Never> {
        actionGeneration = UUID()
        let pending = operationTask
        pending?.cancel()
        let previousDrain = drainTask
        let drain = Task {
            await previousDrain?.value
            await model.disconnect()
            await pending?.value
        }
        drainTask = drain
        return drain
    }

    private func disconnect() {
        guard !shuttingDown else { return }
        let drain = drainConnection()
        let token = UUID()
        operation = token
        operationTask = Task {
            await drain.value
            if operation == token { operation = nil; operationTask = nil; refresh() }
        }
        refresh()
    }

    private func initializeSelection() {
        guard !shuttingDown else { return }
        let drain = drainConnection()
        let token = UUID()
        let input = command.stringValue
        let environment = launchEnvironment
        let valid = launchProblem == nil
        let startNewSession = pendingNewContext
        operation = token
        operationTask = Task {
            defer {
                if operation == token { operation = nil; operationTask = nil; refresh() }
            }
            await drain.value
            guard !Task.isCancelled, !shuttingDown, operation == token, valid else { return }
            await model.connect(command: input, workspace: workspace, launchEnvironment: environment, startNewSession: startNewSession)
            if operation == token, model.phase == .ready { pendingNewContext = false }
            onChange?()
        }
        refresh()
        onChange?()
    }

    /// Send never initializes or retries a connection, nor commits an in-progress command edit.
    private func beginOperation(draft: String) {
        guard !shuttingDown, operation == nil, !changingConfiguration,
              !commandEditing, !commandDirty, !model.isChangingConfiguration,
              model.phase == .ready else { return }
        let token = UUID()
        operation = token
        refresh()
        operationTask = Task {
            defer {
                if operation == token { operation = nil; operationTask = nil; refresh() }
            }
            guard !Task.isCancelled, !shuttingDown, operation == token,
                  !commandEditing, !commandDirty, model.phase == .ready else { return }
            prompt.string = ""
            if sessionTitle == "New Session" {
                let firstLine = draft.split(whereSeparator: \.isNewline).first.map(String.init) ?? draft
                sessionTitle = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
                onChange?()
            }
            operation = nil
            operationTask = nil
            await model.send(draft)
        }
    }

    @objc private func sendPrompt() {
        let text = prompt.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        beginOperation(draft: text)
    }

    @objc private func cancelPrompt() {
        if operation != nil || model.phase == .connecting {
            disconnect()
        } else {
            Task { await model.cancel() }
        }
    }

    func shutdown() async {
        shuttingDown = true
        let drain = drainConnection()
        operation = nil
        operationTask = nil
        refresh()
        await drain.value
    }

    func shutdownInitialSmokeConnection() async {
        disconnect()
        await operationTask?.value
    }

    /// Exercises actual AppKit controls without a model provider, file picker, or UI scripting permissions.
    /// The caller creates this session with `fixtureHome` as its workspace.
    func smokeTest(fixtureHome: URL) async throws {
        let localBin = fixtureHome.appendingPathComponent(".local/bin")
        let nodeBin = fixtureHome.appendingPathComponent(".local/share/fnm/node-versions/v99.0.0/installation/bin")
        for directory in [localBin, nodeBin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let marker = fixtureHome.appendingPathComponent("npm-ran")
        let fixtures: [(URL, String)] = [
            (localBin.appendingPathComponent("fx"), "#!/usr/bin/env latch-smoke-runtime\n" + SmokeAgent.script),
            (nodeBin.appendingPathComponent("latch-smoke-runtime"), "#!/bin/sh\nexec /bin/sh \"$@\"\n"),
            (nodeBin.appendingPathComponent("node"), "#!/bin/sh\nexit 99\n"),
            (localBin.appendingPathComponent("npx"), "#!/bin/sh\nprintf invoked > " + AgentCommand.quotedArgument(marker.path) + "\n" + SmokeAgent.script),
        ]
        for (file, contents) in fixtures {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        // Verify Finder-style discovery without ever launching from host common locations.
        let discovered = AgentLaunchEnvironment(environment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome.path], home: fixtureHome)
        guard discovered.executable(named: "fx") == localBin.appendingPathComponent("fx").path,
              discovered.executable(named: "latch-smoke-runtime") == nodeBin.appendingPathComponent("latch-smoke-runtime").path else {
            throw SmokeError.failed("Finder-style discovery missed fixture executables")
        }
        launchEnvironment = AgentLaunchEnvironment(environment: [
            "PATH": [localBin.path, nodeBin.path, "/usr/bin", "/bin"].joined(separator: ":"),
            "HOME": fixtureHome.path,
        ], home: fixtureHome, includeCommonLocations: false)
        // Default initialization is injected before loadView; only fixture executables exist here.
        let initial = SessionViewController(workspace: workspace, launchEnvironment: launchEnvironment)
        _ = initial.view
        try await wait { initial.model.phase == .ready && initial.operation == nil }
        guard initial.selectedAgent == .fx, initial.model.messages.isEmpty else {
            throw SmokeError.failed("Default selection did not initialize without a prompt")
        }
        await initial.shutdown()
        agents.selectItem(at: AgentPreset.allCases.firstIndex(of: .fx)!)
        selectAgent()
        prompt.string = "Unsent initialization draft"
        sendPrompt()
        guard prompt.string == "Unsent initialization draft", model.messages.isEmpty else {
            throw SmokeError.failed("Send during initialization consumed a draft")
        }
        try await wait { self.model.phase == .ready && self.operation == nil }
        prompt.string = ""
        refresh()
        guard command.stringValue == "fx acp", !command.isEditable, launchProblem == nil else {
            throw SmokeError.failed("fx preset did not discover the local executable")
        }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        try conversation.smokeTest()
        try smokeTestComposerBounds()
        try smokeTestLaunchDetailsBounds()
        guard conversation.frame.height >= 140, !send.isEnabled, !cancel.isEnabled,
              model.phase == .ready, operation == nil, model.messages.isEmpty else {
            throw SmokeError.failed("Invalid initial layout or controls")
        }
        guard modelPicker.isHidden, effortPicker.isHidden, permissionModePicker.isHidden,
              !modelPicker.isEnabled, !effortPicker.isEnabled, !permissionModePicker.isEnabled else {
            throw SmokeError.failed("Agent without configuration must hide pickers")
        }
        guard connectionDetails.isHidden, command.isHidden else {
            throw SmokeError.failed("A built-in agent must not show launch details")
        }
        view.window?.makeFirstResponder(prompt)
        prompt.string = "Draft"
        prompt.setSelectedRange(NSRange(location: 5, length: 0))
        let shiftReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: view.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        prompt.keyDown(with: shiftReturn)
        guard prompt.string.contains("\n"), model.phase == .ready else { throw SmokeError.failed("Shift Return must insert a newline, not send") }
        prompt.string = "Keep working"
        refresh()
        guard send.isEnabled else { throw SmokeError.failed("Send stayed disabled") }
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: view.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        prompt.keyDown(with: enter)
        try await wait { self.model.phase == .prompting }
        guard sessionTitle == "Keep working" else { throw SmokeError.failed("Session title did not follow the first prompt") }
        try await wait {
            self.model.messages.contains(where: { $0.role == .assistant && $0.text.contains("working") }) && self.cancel.isEnabled
        }
        guard conversation.messageCount == model.messages.count,
              model.messages.contains(where: { $0.role == .user }),
              model.messages.contains(where: { $0.role == .assistant }), prompt.string.isEmpty else {
            throw SmokeError.failed("Chat did not render separate messages or clear the sent draft")
        }
        cancel.performClick(nil)
        try await wait { self.model.phase == .ready && self.model.status == "Cancelled" }
        guard agents.isEnabled else { throw SmokeError.failed("Idle connected agent picker disabled") }
        guard model.errorMessage == nil else { throw SmokeError.failed(model.errorMessage!) }

        // Keep fallback testing independent of integrations installed on the developer's Mac.
        launchEnvironment = AgentLaunchEnvironment(environment: [
            "PATH": [localBin.path, nodeBin.path, "/usr/bin", "/bin"].joined(separator: ":"),
            "HOME": fixtureHome.path,
        ], home: fixtureHome, includeCommonLocations: false)
        agents.selectItem(at: AgentPreset.allCases.firstIndex(of: .codex)!)
        NSApp.sendAction(agents.action!, to: agents.target, from: agents)
        try await wait { self.model.phase == .ready && self.operation == nil }
        guard model.messages.isEmpty, FileManager.default.fileExists(atPath: marker.path) else {
            throw SmokeError.failed("Harness selection did not initialize silently")
        }
        guard selectedRecipe?.requiresNode == true, launchProblem == nil, command.isHidden else {
            throw SmokeError.failed("Codex fallback was not ready or exposed its command")
        }
        prompt.string = "First send"
        refresh()
        send.performClick(nil)
        sendPrompt() // A second event before the task starts must not queue another prompt.
        try await wait { self.model.phase == .prompting }
        guard view.window?.attachedSheet == nil, FileManager.default.fileExists(atPath: marker.path),
              model.messages.filter({ $0.role == .user }).count == 1, prompt.string.isEmpty else {
            throw SmokeError.failed("Send did not submit exactly once")
        }
        cancel.performClick(nil)
        try await wait { self.model.phase == .ready }
        agents.selectItem(at: AgentPreset.allCases.firstIndex(of: .custom)!)
        NSApp.sendAction(agents.action!, to: agents.target, from: agents)
        try await wait { self.model.phase == .disconnected && self.operation == nil }
        try smokeTestLaunchDetailsBounds()
        try await smokeTestSelectionRetry()
        try await smokeTestShutdownDraft()
        try await smokeTestConfigurationPickers()

        // Exercise safe default dismissal and explicit selection using the actual sheet buttons.
        for (buttonIndex, result) in [(-1, "permission cancelled"), (-2, "permission cancelled"), (0, "permission cancelled"), (1, "permission selected")] {
            customCommand = "sh -c " + AgentCommand.quotedArgument(SmokeAgent.permissionScript)
            updateAgentCommand()
            // Each pass needs an empty context. Declare that the way the launch controls do,
            // because an ordinary reselection resumes and this fixture reports loadSession: false.
            pendingNewContext = true
            initializeSelection()
            try await wait { self.model.phase == .ready && self.operation == nil }
            prompt.string = "Read example.txt"
            refresh()
            send.performClick(nil)
            try await wait { self.permissionAlert != nil }
            // AppKit may strip every key equivalent once the sheet is presented (observed on macOS betas
            // depending on focus), so only assert the invariant: no approval button ever owns Return.
            guard let alert = permissionAlert?.alert,
                  ["", "\r"].contains(alert.buttons.first?.keyEquivalent ?? "-"),
                  alert.buttons.dropFirst().allSatisfy({ $0.keyEquivalent.isEmpty }) else {
                let buttons = permissionAlert?.alert.buttons.map { "\($0.title):\($0.keyEquivalent.unicodeScalars.map { $0.value })" } ?? ["<no alert>"]
                throw SmokeError.failed("Approval must not be a default action (buttons \(buttons))")
            }
            if buttonIndex < 0 {
                try await wait { alert.window.isVisible }
                // When the app cannot become active (focus elsewhere on recent macOS), the sheet
                // never becomes key and AppKit drops its Return equivalent. Escape still routes
                // through the local monitor, so fall back to it and say what was not verified.
                var useEscape = buttonIndex == -1
                if !useEscape, alert.buttons.first?.keyEquivalent != "\r" {
                    print("UI SMOKE NOTE: Return-cancels not verified; sheet has no Return equivalent (app active: \(NSApp.isActive))")
                    useEscape = true
                }
                let character = useEscape ? "\u{1b}" : "\r"
                let key = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: alert.window.windowNumber, context: nil,
                    characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: useEscape ? 53 : 36
                )!
                NSApp.sendEvent(key)
            } else { alert.buttons[buttonIndex].performClick(nil) }
            try await wait { self.model.phase == .ready && self.model.transcript.contains(result) && self.permissionAlert == nil }
            disconnect()
            try await wait { self.model.phase == .disconnected && self.operation == nil }
        }
    }

    private func smokeTestLaunchDetailsBounds() throws {
        guard let window = view.window else { throw SmokeError.failed("Missing smoke window") }
        func checkRemovedControls(_ container: NSView) throws {
            for child in container.subviews {
                if let button = child as? NSButton,
                   ["Connect", "Disconnect", "Refresh"].contains(button.title) {
                    throw SmokeError.failed("Removed connection control remains in the view hierarchy: \(button.title)")
                }
                if let button = child as? NSButton,
                   button.image?.accessibilityDescription == "Session settings" {
                    throw SmokeError.failed("Session settings button remains in the view hierarchy")
                }
                if let label = child as? NSTextField, label.stringValue.contains("Local session, not saved") {
                    throw SmokeError.failed("Composer footer remains in the view hierarchy")
                }
                try checkRemovedControls(child)
            }
        }
        try checkRemovedControls(view)
        let original = window.frame
        let restoredAgent = selectedAgent
        let oldHint = agentHint.stringValue
        let oldError = error.stringValue
        let errorWasHidden = error.isHidden
        defer {
            selectedAgent = restoredAgent
            refresh()
            agentHint.stringValue = oldHint
            error.stringValue = oldError
            error.isHidden = errorWasHidden
            window.setFrame(original, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        // Launch details are shown by the Custom agent, not by a toggle.
        selectedAgent = .custom
        refresh()
        guard !connectionDetails.isHidden, !command.isHidden, !browse.isHidden else {
            throw SmokeError.failed("Custom agent did not show its command field and executable browser")
        }
        agentHint.stringValue = String(repeating: "Choose an installed executable to run as an ACP agent. ", count: 3)
        error.stringValue = String(repeating: "The agent could not start. Check the command and reselect the harness. ", count: 3)
        error.isHidden = false
        for size in [window.contentMinSize, NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            let controls: [NSView] = [agents, status, command, agentHint, browse, error, conversation, composerBox]
            let visible = controls.filter { !$0.isHiddenOrHasHiddenAncestor }
            for (index, control) in visible.enumerated() {
                let frame = control.convert(control.alignmentRect(forFrame: control.bounds), to: view)
                guard frame.width > 0, frame.height > 0,
                      view.bounds.insetBy(dx: -1, dy: -1).contains(frame) else {
                    throw SmokeError.failed("Launch detail clipped at \(size): \(frame)")
                }
                for other in visible.dropFirst(index + 1) {
                    let otherFrame = other.convert(other.alignmentRect(forFrame: other.bounds), to: view)
                    guard !frame.intersects(otherFrame) else {
                        throw SmokeError.failed("Launch details overlap at \(size): \(frame), \(otherFrame)")
                    }
                }
            }
            for label in [agentHint, error] {
                let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000))
                guard label.bounds.height + 1 >= needed.height else {
                    throw SmokeError.failed("Wrapping text compressed at \(size): \(label.bounds), needs \(needed)")
                }
            }
        }
    }

    private func smokeTestComposerBounds() throws {
        guard let window = view.window else { throw SmokeError.failed("Missing smoke window") }
        let original = window.frame
        defer { window.setFrame(original, display: true); window.contentView?.layoutSubtreeIfNeeded() }
        for size in [window.contentMinSize, NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            let box = composerBox.convert(composerBox.bounds, to: view)
            let transcript = conversation.convert(conversation.bounds, to: view)
            let expected = min(ChatTranscriptView.maximumContentWidth, transcript.width - 32)
            guard abs(box.width - expected) < 2, abs(box.midX - transcript.midX) < 2,
                  box.minX >= transcript.minX + 15, box.maxX <= transcript.maxX - 15,
                  box.height > 88, box.minY >= 0, box.maxY <= view.bounds.height else {
                throw SmokeError.failed("Composer column is clipped or misaligned at \(size): \(box)")
            }
            for picker in [modelPicker, effortPicker, permissionModePicker] where !picker.isHidden {
                let frame = picker.convert(picker.bounds, to: composerBox)
                guard frame.minX >= 0, frame.maxX <= composerBox.bounds.width,
                      picker.frame.width <= 240 else { throw SmokeError.failed("Picker is stretched or clipped") }
            }
        }
    }

    private func smokeTestSelectionRetry() async throws {
        customCommand = "/usr/bin/false"
        updateAgentCommand()
        prompt.string = "Retain this draft"
        selectAgent()
        try await wait { self.operation == nil && self.model.phase == .disconnected && self.model.errorMessage != nil }
        sendPrompt()
        guard prompt.string == "Retain this draft", !send.isEnabled, operation == nil,
              command.isEditable, !command.isHidden else {
            throw SmokeError.failed("Disconnected Send retried or lost the draft")
        }
        // Reselecting a failed harness retries, but never sends.
        selectAgent()
        guard operation != nil else { throw SmokeError.failed("Reselection did not retry") }
        try await wait { self.operation == nil && self.model.phase == .disconnected }
        command.stringValue = "sh -c " + AgentCommand.quotedArgument("while IFS= read -r line; do :; done")
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: command))
        guard operation == nil else { throw SmokeError.failed("Keystroke started initialization") }
        controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: command))
        try await wait { self.model.phase == .connecting }
        sendPrompt()
        guard cancel.isEnabled, agents.isEnabled, prompt.isEditable, !send.isEnabled,
              model.messages.isEmpty, prompt.string == "Retain this draft" else {
            throw SmokeError.failed("Connecting must allow drafting, not sending")
        }
        cancel.performClick(nil)
        try await wait { self.operation == nil && self.model.phase == .disconnected }
        sendPrompt()
        guard operation == nil, model.messages.isEmpty else { throw SmokeError.failed("Stop allowed Send to reconnect") }

        // A hanging initialization must be disconnected before it is awaited; latest selection wins.
        selectAgent()
        try await wait { self.model.phase == .connecting }
        for agent in [AgentPreset.fx, .codex, .fx] {
            agents.selectItem(at: AgentPreset.allCases.firstIndex(of: agent)!)
            selectAgent()
        }
        try await wait { self.operation == nil && self.model.phase == .ready }
        guard selectedAgent == .fx, model.messages.isEmpty, prompt.string == "Retain this draft" else {
            throw SmokeError.failed("Rapid selection sent a draft or retained stale work")
        }
        selectAgent()
        guard operation == nil, model.phase == .ready else { throw SmokeError.failed("Same ready harness restarted") }
        agents.selectItem(at: AgentPreset.allCases.firstIndex(of: .custom)!)
        selectAgent()
        cancelPrompt() // Stop before the new initialization task starts.
        try await wait { self.operation == nil && self.model.phase == .disconnected }
        selectAgent()
        cancelPrompt()
        selectAgent() // A new selection wins even while Stop is still draining this same harness.
        try await wait { self.model.phase == .connecting }
        guard model.messages.isEmpty, prompt.string == "Retain this draft" else {
            throw SmokeError.failed("Reselecting during Stop consumed the draft")
        }
        cancel.performClick(nil)
        try await wait { self.operation == nil && self.model.phase == .disconnected }
        command.stringValue = "sh -c " + AgentCommand.quotedArgument(SmokeAgent.script)
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: command))
        controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: command))
        try await wait { self.operation == nil && self.model.phase == .ready }
        controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: command))
        command.stringValue += " "
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: command))
        sendPrompt()
        guard model.messages.isEmpty, prompt.string == "Retain this draft", operation == nil else {
            throw SmokeError.failed("Send ran a stale command while editing")
        }
        controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: command))
        try await wait { self.operation == nil && self.model.phase == .ready }
        sendPrompt()
        try await wait { self.model.phase == .prompting }
        guard prompt.string.isEmpty, model.messages.filter({ $0.role == .user }).count == 1 else {
            throw SmokeError.failed("Ready Send did not send exactly once")
        }
        cancel.performClick(nil)
        try await wait { self.model.phase == .ready }
        // Reselecting the connected agent rescans but keeps the live session, its history,
        // and the unsent draft. It must never send.
        let sent = model.messages.filter { $0.role == .user }.count
        prompt.string = "Reselection retains draft"
        selectAgent()
        try await wait { self.operation == nil && self.model.phase == .ready }
        guard model.messages.filter({ $0.role == .user }).count == sent,
              prompt.string == "Reselection retains draft" else {
            throw SmokeError.failed("Reselecting the connected agent sent a prompt or lost the draft")
        }
        disconnect()
        try await wait { self.operation == nil && self.model.phase == .disconnected }
    }

    private func smokeTestShutdownDraft() async throws {
        let session = SessionViewController(workspace: workspace, launchEnvironment: launchEnvironment)
        _ = session.view
        session.agents.selectItem(at: AgentPreset.allCases.firstIndex(of: .custom)!)
        session.selectAgent()
        session.customCommand = "sh -c " + AgentCommand.quotedArgument(SmokeAgent.script)
        session.updateAgentCommand()
        session.initializeSelection()
        session.prompt.string = "Do not send after shutdown"
        session.sendPrompt()
        await session.shutdown()
        await Task.yield()
        guard session.model.phase == .disconnected, session.model.messages.isEmpty,
              session.prompt.string == "Do not send after shutdown", !session.send.isEnabled else {
            throw SmokeError.failed("Shutdown allowed a queued first send")
        }
    }

    private func smokeTestConfigurationPickers() async throws {
        guard !modelPicker.isEnabled, !effortPicker.isEnabled else {
            throw SmokeError.failed("Disconnected pickers must be disabled")
        }
        command.stringValue = "sh -c " + AgentCommand.quotedArgument(ConfigurationSmokeAgent.script(variant: .permissionMode))
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: command))
        controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: command))
        try await wait { self.model.phase == .ready && self.operation == nil }
        guard model.messages.isEmpty else { throw SmokeError.failed("Configuration initialization sent a prompt") }
        guard modelPicker.isEnabled, effortPicker.isEnabled, permissionModePicker.isEnabled,
              modelPicker.selectedItem?.representedObject as? String == "fast",
              effortPicker.selectedItem?.representedObject as? String == "low",
              permissionModePicker.selectedItem?.representedObject as? String == "default" else {
            throw SmokeError.failed("Pickers did not display agent-provided defaults")
        }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        try smokeTestComposerBounds()
        for picker in [modelPicker, effortPicker, permissionModePicker] {
            let bounds = picker.convert(picker.bounds, to: view)
            guard bounds.minX >= 0, bounds.maxX <= view.bounds.width,
                  picker.controlSize == .large, picker.font?.pointSize == 14,
                  picker.frame.height >= picker.intrinsicContentSize.height,
                  picker.frame.height >= ComposerControlsView.controlHeight else {
                throw SmokeError.failed("Configuration picker is clipped")
            }
        }
        effortPicker.selectItem(at: 1)
        NSApp.sendAction(effortPicker.action!, to: effortPicker.target, from: effortPicker)
        prompt.string = "Wait for configuration"
        sendPrompt() // Must be blocked even before the configuration task enters the model.
        guard prompt.string == "Wait for configuration", operation == nil else {
            throw SmokeError.failed("Send raced a pending configuration selection")
        }
        try await wait { !self.changingConfiguration && !self.model.isChangingConfiguration && self.model.configuration.effort?.currentValue == "high" }
        prompt.string = ""
        refresh()
        modelPicker.selectItem(at: 1)
        NSApp.sendAction(modelPicker.action!, to: modelPicker.target, from: modelPicker)
        try await wait { !self.model.isChangingConfiguration && self.model.configuration.model?.currentValue == "deep" }
        guard modelPicker.selectedItem?.representedObject as? String == "deep",
              effortPicker.numberOfItems == 1,
              effortPicker.selectedItem?.representedObject as? String == "high" else {
            throw SmokeError.failed("Model selection did not refresh effort choices")
        }
        try await wait { !self.changingConfiguration }
        permissionModePicker.selectItem(at: 1)
        NSApp.sendAction(permissionModePicker.action!, to: permissionModePicker.target, from: permissionModePicker)
        guard permissionModePicker.selectedItem?.representedObject as? String == "default",
              !permissionModePicker.isEnabled else {
            throw SmokeError.failed("Permission mode changed optimistically before confirmation")
        }
        try await wait { !self.changingConfiguration && self.model.configuration.permissionMode?.currentValue == "plan" }
        guard permissionModePicker.selectedItem?.representedObject as? String == "plan",
              model.messages.isEmpty else {
            throw SmokeError.failed("Permission mode selection failed or sent a prompt")
        }
        prompt.string = "Keep working with this configuration"
        refresh()
        send.performClick(nil)
        try await wait { self.model.phase == .prompting && self.cancel.isEnabled }
        guard !modelPicker.isEnabled, !effortPicker.isEnabled, !permissionModePicker.isEnabled else {
            throw SmokeError.failed("Pickers must be disabled during a prompt")
        }
        cancel.performClick(nil)
        try await wait { self.model.phase == .ready }
        disconnect()
        try await wait { self.model.phase == .disconnected && self.operation == nil }
        guard !modelPicker.isEnabled, !effortPicker.isEnabled, !permissionModePicker.isEnabled,
              permissionModePicker.isHidden, permissionModePicker.selectedItem?.representedObject == nil,
              modelPicker.selectedItem?.representedObject == nil,
              effortPicker.selectedItem?.representedObject == nil else {
            throw SmokeError.failed("Disconnect retained stale picker state")
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            if ContinuousClock.now >= deadline { throw SmokeError.failed("Timed out: \(model.status) \(model.errorMessage ?? "")") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Measure at the assigned width; a stack view can otherwise keep a wrapping label one line tall.
@MainActor
private final class SettingsWrappingLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        guard bounds.width > 0, let cell else { return super.intrinsicContentSize }
        let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude))
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(measured.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

enum SmokeError: Error { case failed(String) }
