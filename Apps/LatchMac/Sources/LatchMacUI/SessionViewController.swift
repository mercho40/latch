import AppKit

/// One ACP session: agent selection, connection controls, transcript, and composer.
/// The workspace is fixed at creation; the sidebar owns the list of sessions.
@MainActor
final class SessionViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    let model = SessionModel()
    let workspace: URL
    /// Derived from the first prompt; the sidebar and window title show it.
    private(set) var sessionTitle = "New Session"
    var onChange: (() -> Void)?

    private var permissionAlert: (id: UUID, alert: NSAlert, escapeMonitor: Any?)?
    private let command = NSTextField(string: "")
    private let agents = NSPopUpButton(frame: .zero, pullsDown: false)
    private let agentHint = NSTextField(wrappingLabelWithString: "")
    private let rescan = NSButton(title: "Refresh", target: nil, action: nil)
    private let browse = NSButton(title: "Choose Executable…", target: nil, action: nil)
    private var launchEnvironment = AgentLaunchEnvironment()
    private var selectedAgent: AgentPreset = .custom
    private var customCommand = ""
    private var selectedRecipe: AgentLaunchRecipe?
    private var launchProblem: String?
    private var downloadAlert: NSAlert?
    private var confirmingDownload: Bool { downloadAlert != nil }
    private var shuttingDown = false
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Not connected")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let conversation = ChatTranscriptView(frame: .zero)
    private let prompt = ChatInputView(frame: .zero)
    private let connectionDetails = NSStackView()
    private let settings = NSButton(title: "Settings", target: nil, action: nil)
    private var showsConnectionDetails = false
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var renderedConfiguration: SessionConfiguration?
    private var renderedPickerPlaceholder: String?

    init(workspace: URL) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
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
        refresh()
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
        connect.target = self
        connect.action = #selector(toggleConnection)
        connect.bezelStyle = .rounded
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        settings.target = self
        settings.action = #selector(toggleSettings)
        settings.bezelStyle = .rounded
        root.addArrangedSubview(row([agents, status, settings, connect]))
        connectionDetails.orientation = .vertical
        connectionDetails.alignment = .leading
        connectionDetails.spacing = 8
        connectionDetails.addArrangedSubview(command)
        agentHint.font = .systemFont(ofSize: 11)
        agentHint.textColor = .secondaryLabelColor
        agentHint.maximumNumberOfLines = 2
        agentHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rescan.target = self
        rescan.action = #selector(refreshAgents)
        rescan.bezelStyle = .rounded
        rescan.toolTip = "Look again for installed agents and Node.js without running shell startup files."
        browse.target = self
        browse.action = #selector(chooseExecutable)
        browse.bezelStyle = .rounded
        connectionDetails.addArrangedSubview(row([agentHint, browse, rescan]))
        for item in connectionDetails.arrangedSubviews {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: connectionDetails.widthAnchor).isActive = true
        }
        root.addArrangedSubview(connectionDetails)
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 12)
        error.setAccessibilityLabel("Session error")
        root.addArrangedSubview(error)
        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)

        conversation.setAccessibilityLabel("Conversation")
        conversation.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        root.addArrangedSubview(conversation)

        let composerBox = ChatComposerBox()
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
        let modelLabel = NSTextField(labelWithString: "Model")
        let effortLabel = NSTextField(labelWithString: "Effort")
        for label in [modelLabel, effortLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        for picker in [modelPicker, effortPicker] {
            picker.target = self
            picker.cell?.lineBreakMode = .byTruncatingTail
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
            picker.menu?.autoenablesItems = false
        }
        modelPicker.action = #selector(selectModel)
        effortPicker.action = #selector(selectEffort)
        modelPicker.setAccessibilityLabel("Session model")
        effortPicker.setAccessibilityLabel("Reasoning effort")
        modelPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        effortPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        effortPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
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
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        send.setAccessibilityLabel("Send message")
        send.toolTip = "Send message (Return or ⌘ Return)"
        cancel.setAccessibilityLabel("Stop response")
        cancel.toolTip = "Stop the current response"
        composerContent.addArrangedSubview(row([modelLabel, modelPicker, effortLabel, effortPicker, cancel, send]))
        for item in composerContent.arrangedSubviews {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: composerContent.widthAnchor).isActive = true
        }
        root.addArrangedSubview(composerBox)
        let footer = NSTextField(wrappingLabelWithString: "Return to send · Shift Return for a new line · Local session, not saved")
        footer.toolTip = "Quit requests agent shutdown. Permission requests still require your decision; agent-side restrictions apply."
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        root.addArrangedSubview(footer)
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
        let editable = disconnected && !confirmingDownload && !shuttingDown
        agents.isEnabled = editable
        rescan.isEnabled = editable
        browse.isEnabled = editable
        browse.isHidden = selectedAgent != .custom
        command.isEnabled = editable
        command.isEditable = editable && selectedAgent == .custom
        connect.title = disconnected ? "Connect" : "Disconnect"
        connect.isEnabled = disconnected ? editable && launchProblem == nil : model.phase != .stopping && !shuttingDown
        status.stringValue = model.status
        error.stringValue = model.errorMessage ?? ""
        error.isHidden = model.errorMessage == nil
        prompt.isEditable = model.phase == .ready || model.phase == .prompting
        refreshPickers()
        send.isEnabled = model.phase == .ready && !model.isChangingConfiguration && !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancel.isEnabled = model.phase == .prompting && !model.cancellationRequested
        cancel.isHidden = model.phase != .prompting
        connectionDetails.isHidden = !disconnected && !showsConnectionDetails
        settings.isEnabled = !disconnected
        settings.title = showsConnectionDetails ? "Hide Settings" : "Settings"
        prompt.placeholder = disconnected ? "Connect an agent to start chatting…" : "Message the agent…"
        prompt.needsDisplay = true
        conversation.update(messages: model.messages, isWorking: model.phase == .prompting)
    }

    @objc private func toggleSettings() {
        showsConnectionDetails.toggle()
        refresh()
    }

    private func refreshPickers() {
        let placeholder = model.phase == .disconnected || model.phase == .connecting ? "Connect first" : "Not available"
        if renderedConfiguration != model.configuration || renderedPickerPlaceholder != placeholder {
            populate(modelPicker, from: model.configuration.model, placeholder: placeholder)
            populate(effortPicker, from: model.configuration.effort, placeholder: placeholder)
            renderedConfiguration = model.configuration
            renderedPickerPlaceholder = placeholder
        }
        let editable = model.phase == .ready && !model.isChangingConfiguration && !shuttingDown
        modelPicker.isEnabled = editable && !(model.configuration.model?.choices.isEmpty ?? true)
        effortPicker.isEnabled = editable && !(model.configuration.effort?.choices.isEmpty ?? true)
    }

    private func populate(_ button: NSPopUpButton, from picker: SessionPicker?, placeholder: String) {
        button.removeAllItems()
        guard let picker else {
            button.addItem(withTitle: placeholder)
            button.toolTip = placeholder == "Connect first" ? "Options are supplied by the connected agent." : "This agent does not expose this setting for the current session."
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

    private func select(_ kind: SessionPicker.Kind, from button: NSPopUpButton) {
        guard let value = button.selectedItem?.representedObject as? String else { return }
        // A pop-up selects optimistically; restore the confirmed value until the reply arrives.
        renderedConfiguration = nil
        refreshPickers()
        Task { await model.select(kind, value: value) }
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

    func textDidChange(_ notification: Notification) { refresh() }
    func controlTextDidChange(_ obj: Notification) {
        if selectedAgent == .custom { customCommand = command.stringValue }
        updateAgentHint()
        refresh()
    }

    @objc private func selectAgent() {
        guard model.phase == .disconnected, !confirmingDownload else { return }
        if selectedAgent == .custom { customCommand = command.stringValue }
        selectedAgent = AgentPreset.allCases[agents.indexOfSelectedItem]
        updateAgentCommand()
        refresh()
    }

    @objc private func refreshAgents() {
        guard model.phase == .disconnected, !confirmingDownload else { return }
        launchEnvironment = AgentLaunchEnvironment()
        updateAgentCommand()
        refresh()
    }

    private func updateAgentCommand() {
        selectedRecipe = selectedAgent.recipe(in: launchEnvironment)
        command.stringValue = selectedRecipe?.command ?? customCommand
        updateAgentHint()
    }

    private func updateAgentHint() {
        launchProblem = selectedRecipe?.problem(in: launchEnvironment)
        do {
            let resolved = try launchEnvironment.resolve(AgentCommand(command.stringValue))
            if let package = selectedRecipe?.downloadPackage {
                agentHint.stringValue = launchProblem ?? "Uses npm to download or reuse \(package). Connect asks before running it."
            } else {
                agentHint.stringValue = "Found: \(resolved.executable)"
            }
        } catch {
            launchProblem = launchProblem ?? error.localizedDescription
            agentHint.stringValue = launchProblem!
        }
        agentHint.toolTip = [agentHint.stringValue, selectedRecipe?.setup].compactMap { $0 }.joined(separator: "\n")
    }

    @objc private func chooseExecutable() {
        guard let window = view.window, selectedAgent == .custom, model.phase == .disconnected else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Executable"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let arguments = (try? AgentCommand(self.command.stringValue))?.arguments ?? []
            self.customCommand = ([url.path] + arguments).map(AgentCommand.quotedArgument).joined(separator: " ")
            self.updateAgentCommand()
            self.refresh()
        }
    }

    @objc private func toggleConnection() {
        guard !shuttingDown, !confirmingDownload else { return }
        guard model.phase == .disconnected else {
            Task { await model.disconnect() }
            return
        }
        guard launchProblem == nil else { return }
        let input = command.stringValue
        let environment = launchEnvironment
        if let package = selectedRecipe?.downloadPackage, let window = view.window {
            let alert = NSAlert()
            alert.messageText = "Run the \(selectedAgent.title) ACP adapter?"
            alert.informativeText = "npm will download or reuse and execute \(package).\n\n\(selectedRecipe?.setup ?? "")\n\nCommand: \(input)"
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
            alert.addButton(withTitle: "Run Adapter and Connect").keyEquivalent = ""
            downloadAlert = alert
            refresh()
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                self.downloadAlert = nil
                self.refresh()
                guard response == .alertSecondButtonReturn, !self.shuttingDown else { return }
                self.startConnection(input, environment: environment)
            }
        } else { startConnection(input, environment: environment) }
    }

    private func startConnection(_ input: String, environment: AgentLaunchEnvironment) {
        Task {
            guard !shuttingDown else { return }
            await model.connect(command: input, workspace: workspace, launchEnvironment: environment)
        }
    }

    @objc private func sendPrompt() {
        guard model.phase == .ready, !model.isChangingConfiguration else { return }
        let text = prompt.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prompt.string = ""
        if sessionTitle == "New Session" {
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            sessionTitle = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
            onChange?()
        }
        Task { await model.send(text) }
    }

    @objc private func cancelPrompt() { Task { await model.cancel() } }

    func shutdown() async {
        shuttingDown = true
        if confirmingDownload, let sheet = view.window?.attachedSheet { view.window?.endSheet(sheet, returnCode: .abort) }
        await model.disconnect()
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
            (localBin.appendingPathComponent("npx"), "#!/bin/sh\nprintf invoked > " + AgentCommand.quotedArgument(marker.path) + "\nexit 99\n"),
        ]
        for (file, contents) in fixtures {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        // Match a Finder-style environment: no terminal-initialized Node or agent PATH.
        launchEnvironment = AgentLaunchEnvironment(environment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome.path], home: fixtureHome)
        agents.selectItem(at: AgentPreset.allCases.firstIndex(of: .fx)!)
        selectAgent()
        guard command.stringValue == "fx acp", !command.isEditable, launchProblem == nil else {
            throw SmokeError.failed("fx preset did not discover the local executable")
        }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        try conversation.smokeTest()
        guard conversation.frame.height >= 140, !send.isEnabled, !cancel.isEnabled else {
            throw SmokeError.failed("Invalid initial layout or controls")
        }
        connect.performClick(nil)
        try await wait { self.model.phase == .ready }
        guard !modelPicker.isEnabled, !effortPicker.isEnabled else {
            throw SmokeError.failed("Agent without configuration must not expose editable pickers")
        }
        guard connectionDetails.isHidden else { throw SmokeError.failed("Connection settings stayed expanded") }
        settings.performClick(nil)
        guard !connectionDetails.isHidden else { throw SmokeError.failed("Settings did not reopen") }
        settings.performClick(nil)
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
        connect.performClick(nil)
        try await wait { self.model.phase == .disconnected }
        guard model.errorMessage == nil else { throw SmokeError.failed(model.errorMessage!) }

        agents.selectItem(at: AgentPreset.allCases.firstIndex(of: .codex)!)
        selectAgent()
        guard selectedRecipe?.downloadPackage != nil, launchProblem == nil else {
            throw SmokeError.failed("Codex did not offer its ACP adapter")
        }
        connect.performClick(nil)
        try await wait { self.confirmingDownload && self.view.window?.attachedSheet != nil }
        let downloadSheet = view.window!.attachedSheet!
        try await wait { NSApp.keyWindow === downloadSheet }
        NSApp.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: downloadSheet.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!)
        try await wait { !self.confirmingDownload }
        guard model.phase == .disconnected, !FileManager.default.fileExists(atPath: marker.path) else {
            throw SmokeError.failed("Adapter ran without explicit approval")
        }
        agents.selectItem(at: AgentPreset.allCases.firstIndex(of: .custom)!)
        selectAgent()
        try await smokeTestConfigurationPickers()

        // Exercise safe default dismissal and explicit selection using the actual sheet buttons.
        for (buttonIndex, result) in [(-1, "permission cancelled"), (-2, "permission cancelled"), (0, "permission cancelled"), (1, "permission selected")] {
            customCommand = "sh -c " + AgentCommand.quotedArgument(SmokeAgent.permissionScript)
            updateAgentCommand()
            refresh()
            connect.performClick(nil)
            try await wait { self.model.phase == .ready }
            prompt.string = "Read example.txt"
            refresh()
            send.performClick(nil)
            try await wait { self.permissionAlert != nil }
            guard let alert = permissionAlert?.alert,
                  alert.buttons.first?.keyEquivalent == "\r",
                  alert.buttons.dropFirst().allSatisfy({ $0.keyEquivalent.isEmpty }) else {
                throw SmokeError.failed("Approval must not be a default action")
            }
            if buttonIndex < 0 {
                try await wait { NSApp.keyWindow === alert.window }
                let character = buttonIndex == -1 ? "\u{1b}" : "\r"
                let key = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: alert.window.windowNumber, context: nil,
                    characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: buttonIndex == -1 ? 53 : 36
                )!
                NSApp.sendEvent(key)
            } else { alert.buttons[buttonIndex].performClick(nil) }
            try await wait { self.model.phase == .ready && self.model.transcript.contains(result) && self.permissionAlert == nil }
            connect.performClick(nil)
            try await wait { self.model.phase == .disconnected }
        }
    }

    private func smokeTestConfigurationPickers() async throws {
        guard !modelPicker.isEnabled, !effortPicker.isEnabled else {
            throw SmokeError.failed("Disconnected pickers must be disabled")
        }
        customCommand = "sh -c " + AgentCommand.quotedArgument(ConfigurationSmokeAgent.script)
        updateAgentCommand()
        refresh()
        connect.performClick(nil)
        try await wait { self.model.phase == .ready }
        guard modelPicker.isEnabled, effortPicker.isEnabled,
              modelPicker.selectedItem?.representedObject as? String == "fast",
              effortPicker.selectedItem?.representedObject as? String == "low" else {
            throw SmokeError.failed("Pickers did not display agent-provided defaults")
        }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        for picker in [modelPicker, effortPicker] {
            let bounds = picker.convert(picker.bounds, to: view)
            guard bounds.minX >= 0, bounds.maxX <= view.bounds.width,
                  picker.frame.height >= picker.intrinsicContentSize.height else {
                throw SmokeError.failed("Configuration picker is clipped")
            }
        }
        effortPicker.selectItem(at: 1)
        NSApp.sendAction(effortPicker.action!, to: effortPicker.target, from: effortPicker)
        try await wait { !self.model.isChangingConfiguration && self.model.configuration.effort?.currentValue == "high" }
        modelPicker.selectItem(at: 1)
        NSApp.sendAction(modelPicker.action!, to: modelPicker.target, from: modelPicker)
        try await wait { !self.model.isChangingConfiguration && self.model.configuration.model?.currentValue == "deep" }
        guard modelPicker.selectedItem?.representedObject as? String == "deep",
              effortPicker.numberOfItems == 1,
              effortPicker.selectedItem?.representedObject as? String == "high" else {
            throw SmokeError.failed("Model selection did not refresh effort choices")
        }
        prompt.string = "Keep working with this configuration"
        refresh()
        send.performClick(nil)
        try await wait { self.model.phase == .prompting && self.cancel.isEnabled }
        guard !modelPicker.isEnabled, !effortPicker.isEnabled else {
            throw SmokeError.failed("Pickers must be disabled during a prompt")
        }
        cancel.performClick(nil)
        try await wait { self.model.phase == .ready }
        connect.performClick(nil)
        try await wait { self.model.phase == .disconnected }
        guard !modelPicker.isEnabled, !effortPicker.isEnabled,
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

enum SmokeError: Error { case failed(String) }
