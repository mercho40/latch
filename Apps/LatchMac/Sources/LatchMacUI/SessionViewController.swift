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
    /// Only the committed command is stored: an uncommitted edit is transient UI state,
    /// because committing one forks a sibling session rather than replacing this context.
    var savedSession: SavedSession {
        SavedSession(id: id, workspacePath: workspace.path, title: sessionTitle,
                     agentID: selectedAgent.rawValue,
                     customCommand: customCommand,
                     draft: prompt.string,
                     messages: pendingNewContext ? [] : model.messages,
                     agentSessionID: pendingNewContext ? nil : model.savedAgentSessionID)
    }

    /// Asks the window for a sibling session in this workspace on the given harness.
    var onForkSession: ((AgentPreset, String) -> Void)?
    /// A fork inherits the parent's environment when one was injected, so tests and smoke
    /// runs stay hermetic; a real session lets the fork rescan the filesystem itself.
    var injectedEnvironment: AgentLaunchEnvironment? { injectedLaunchEnvironment == nil ? nil : launchEnvironment }
    /// Once a transcript exists, this session owns its harness for the rest of its life.
    private var holdsConversation: Bool { !model.messages.isEmpty }
    /// Derived from the first prompt; the sidebar and window title show it.
    private(set) var sessionTitle = "New Session"
    var onChange: (() -> Void)?
    /// Marks persistence dirty without refreshing the sidebar or attention state.
    var onTranscriptChange: (() -> Void)?

    /// Built-in connections use the chosen provider name, not the protocol executable's identity.
    var displayStatus: String {
        if selectedAgent != .custom, model.status.hasPrefix("Connected · ") {
            return "Connected · \(selectedAgent.title)"
        }
        return model.status
    }

    /// What this session wants the user to know about, whether or not it is on screen.
    var attention: AttentionCenter.State {
        let pending = model.permissions.current
        return AttentionCenter.State(
            workspaceName: workspace.lastPathComponent,
            permission: pending?.id,
            allowOptionID: pending?.options.first { $0.kind == "allow_once" }?.optionId,
            rejectOptionID: pending?.options.first { $0.kind == "reject_once" }?.optionId,
            isPrompting: model.phase == .prompting
        )
    }

    var menuBarRow: MenuBarSession {
        MenuBarSession(id: id, title: sessionTitle, status: displayStatus,
                       phase: model.phase, needsPermission: model.permissions.current != nil)
    }

    /// A decision taken outside the sheet, from a notification action. The queue only
    /// accepts the request it is actually showing, and the open sheet closes on the next
    /// refresh because its request is no longer current.
    func resolvePermission(request: UUID, optionID: String?) {
        guard model.permissions.current?.id == request else { return }
        model.permissions.resolve(id: request, optionID: optionID)
        refresh()
    }

    /// The sidebar's inline rename. An empty name keeps the previous one.
    func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != sessionTitle else { return }
        sessionTitle = String(trimmed.prefix(60))
        onChange?()
    }

    var canStop: Bool {
        let preparing = operation != nil || model.phase == .connecting
        return !shuttingDown && model.phase != .stopping
            && (preparing || (model.phase == .prompting && !model.cancellationRequested))
    }

    var canDisconnect: Bool {
        !shuttingDown && model.phase != .disconnected && model.phase != .stopping
    }

    var canFork: Bool { !shuttingDown && restoredCommandIsUsable }

    private var restoredCommandIsUsable: Bool { isViewLoaded && launchProblem == nil }

    func stopActivity() {
        guard canStop else { return }
        cancelPrompt()
    }

    func disconnectSession() {
        guard canDisconnect else { return }
        disconnect()
    }

    /// Opens a sibling session on the same harness and command, beside this one.
    func forkSession() {
        guard canFork else { return }
        onForkSession?(selectedAgent, customCommand)
    }

    private var permissionAlert: (id: UUID, alert: NSAlert, escapeMonitor: Any?)?
    private let settings: AgentSettings
    /// One filesystem scan, shared by the picker and the banner. Rescanning replaces it.
    private var catalog: AgentCatalog
    private var launchEnvironment: AgentLaunchEnvironment
    private let injectedLaunchEnvironment: AgentLaunchEnvironment?
    private var drainTask: Task<Void, Never>?
    private var selectedAgent: AgentPreset = .custom
    private var customCommand = ""
    private var selectedRecipe: AgentLaunchRecipe?
    /// What Latch will actually run for the selected harness, resolved from the catalog.
    private var launchCommand = ""
    private var launchProblem: String?
    private var operation: UUID?
    private var operationTask: Task<Void, Never>?
    private var changingConfiguration = false
    private var actionGeneration = UUID()
    private let composerBox = ChatComposerBox()
    /// The composer keeps its own undo stack: each session edits its own draft, and ⌘Z
    /// there must never reach the window's session-level undo.
    private let composerUndo = UndoManager()
    private var shuttingDown = false
    /// Connection problems and their remedies. Fixed-height chrome is gone: the banner
    /// appears above the transcript only while there is something to say. It is the
    /// session's whole error surface, so tests read it rather than a hidden label.
    let banner = SessionBannerView()
    /// Collapses out of the stack with the banner, so a session with nothing wrong gives
    /// the whole column to the transcript.
    private let bannerRow = NSView()
    let conversation = ChatTranscriptView(frame: .zero)
    private let prompt = ChatInputView(frame: .zero)
    private let composer = ChatComposerScrollView(frame: .zero)
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let permissionModePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Only the settings that change between messages. The harness is chosen once per
    /// session and then locked, so it lives in the window's toolbar, not in the composer.
    private lazy var composerControls = ComposerControlsView(
        pickers: [.init(modelPicker, maximumWidth: 260),
                  .init(effortPicker, minimumWidth: 96, maximumWidth: 150),
                  .init(permissionModePicker)],
        actions: [cancel, send])
    private var renderedConfiguration: SessionConfiguration?
    private var renderedPickerPlaceholder: String?
    private lazy var transcriptUpdates = TranscriptRenderScheduler { [weak self] in
        self?.renderTranscript()
    }

    init(workspace: URL, launchEnvironment: AgentLaunchEnvironment? = nil, savedSession: SavedSession? = nil,
         initialAgent: AgentPreset? = nil, initialCommand: String? = nil,
         settings: AgentSettings? = nil) {
        self.id = savedSession?.id ?? UUID()
        self.workspace = workspace
        self.injectedLaunchEnvironment = launchEnvironment
        self.launchEnvironment = launchEnvironment ?? AgentLaunchEnvironment()
        let settings = settings ?? .shared
        self.settings = settings
        // A fresh session starts on the command configured in Settings; a restored or
        // forked one keeps the command it already connected with.
        let command = initialCommand ?? savedSession?.customCommand ?? settings.customCommand
        catalog = AgentCatalog(environment: self.launchEnvironment, customCommand: command)
        selectedAgent = savedSession.flatMap { AgentPreset(rawValue: $0.agentID) }
            ?? initialAgent ?? settings.suggested(in: catalog)
        super.init(nibName: nil, bundle: nil)
        customCommand = command
        if let savedSession {
            sessionTitle = savedSession.title
            prompt.string = savedSession.draft
            model.restore(messages: savedSession.messages, agentSessionID: savedSession.agentSessionID)
        }
        model.onChange = { [weak self] in
            self?.refresh()
            self?.onChange?()
        }
        model.onTranscriptChange = { [weak self] in
            self?.transcriptUpdates.request()
            self?.onTranscriptChange?()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(agentSettingsChanged),
                                               name: AgentSettings.didChangeNotification, object: settings)
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

        // The banner keeps the transcript's column so a failure reads as part of the
        // conversation rather than as a second header above it.
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerRow.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: bannerRow.leadingAnchor, constant: ChatTranscriptView.horizontalInset),
            banner.trailingAnchor.constraint(equalTo: bannerRow.trailingAnchor, constant: -ChatTranscriptView.horizontalInset),
            banner.topAnchor.constraint(equalTo: bannerRow.topAnchor),
            banner.bottomAnchor.constraint(equalTo: bannerRow.bottomAnchor),
        ])
        banner.isHidden = true
        bannerRow.isHidden = true
        root.addArrangedSubview(bannerRow)

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
        composer.borderType = .noBorder
        composer.drawsBackground = false
        prompt.drawsBackground = false
        prompt.onSubmit = { [weak self] in self?.sendPrompt() }
        prompt.font = .systemFont(ofSize: 14)
        prompt.textContainerInset = NSSize(width: 8, height: 8)
        prompt.isRichText = false
        prompt.allowsUndo = true
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        // Prompts are prose, so flag misspellings; but never rewrite what was typed —
        // autocorrect and text replacement mangle paths, flags, and identifiers.
        prompt.isContinuousSpellCheckingEnabled = true
        prompt.isGrammarCheckingEnabled = false
        prompt.isAutomaticSpellingCorrectionEnabled = false
        prompt.isAutomaticTextReplacementEnabled = false
        prompt.delegate = self
        prompt.setAccessibilityLabel("Message to agent")
        prompt.setAccessibilityHelp("Return to send. Shift Return to insert a new line.")
        configureTextView(prompt, in: composer)
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
        NSLayoutConstraint.activate([
            composerBox.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: ChatTranscriptView.horizontalInset),
            composerBox.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -ChatTranscriptView.horizontalInset),
            composerBox.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composerBox.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
        ])
        // No keyboard caption under the composer: the shortcuts stay in the field's
        // accessibility help, where they cost no chrome.
        root.addArrangedSubview(composerContainer)
        for view in root.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
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
        refreshBanner()
        // Drafting can continue during connection setup; only a queued send locks the ready composer.
        prompt.isEditable = !shuttingDown && (operation == nil || model.phase != .ready)
        refreshPickers()
        send.isEnabled = !shuttingDown && operation == nil && !changingConfiguration && model.phase == .ready && !model.isChangingConfiguration && !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let preparing = operation != nil || model.phase == .connecting
        cancel.isEnabled = canStop
        cancel.isHidden = !preparing && model.phase != .prompting
        composerControls.refreshLayout()
        prompt.placeholder = "Message \(selectedAgent.title)…"
        prompt.needsDisplay = true
        composer.refreshHeight()
        // State transitions must show their final text immediately, even when a
        // frame was queued. Late ACP chunks still schedule a subsequent render.
        transcriptUpdates.cancel()
        renderTranscript()
    }

    private func renderTranscript() {
        guard isViewLoaded else { return }
        conversation.update(messages: model.messages, isWorking: model.phase == .prompting)
    }

    /// What the window's harness control should show and offer for this session.
    var harnessSelection: HarnessSelection {
        // A session never loses the harness it is running on, even when Settings stops
        // offering it: the current selection always has to be representable.
        let presets = AgentPreset.allCases.filter { settings.isEnabled($0) || $0 == selectedAgent }
        let rows = presets.map { preset in
            HarnessSelection.Row(preset: preset, title: preset.title, detail: agentDetail(for: preset),
                                 isCurrent: preset == selectedAgent)
        }
        return HarnessSelection(rows: rows, current: selectedAgent,
                                problem: catalog.status(for: selectedAgent).readiness.problem,
                                isEditable: canEditLaunch && !shuttingDown)
    }

    /// Switching harness once a transcript exists opens a sibling session rather than
    /// replacing this one's context. Say so on the row, before it happens.
    private func agentDetail(for preset: AgentPreset) -> String {
        if holdsConversation, preset != selectedAgent { return "Opens a new session" }
        return catalog.status(for: preset).readiness.badge
    }

    /// The single place a connection problem is reported. Keyed on the failure itself, so
    /// dismissing one keeps it dismissed while nothing has changed, and a different failure
    /// always gets its say.
    private func refreshBanner() {
        let disconnected = model.phase == .disconnected
        let failure = model.errorMessage.map { message in
            selectedAgent != .custom && disconnected ? startupError(message) : message
        } ?? launchProblem
        guard let failure, !shuttingDown else {
            banner.update(key: nil, title: "", message: "", severity: .error, actions: [])
            bannerRow.isHidden = true
            return
        }
        banner.update(
            key: "\(model.phase)\u{0}\(selectedAgent.rawValue)\u{0}\(failure)",
            title: disconnected ? "\(selectedAgent.title) can’t start" : "\(selectedAgent.title) reported a problem",
            message: failure,
            severity: disconnected ? .error : .warning,
            actions: [
                SessionBannerView.Action(title: "Retry") { [weak self] in self?.retryConnection() },
                SessionBannerView.Action(title: "Agent Settings…") {
                    NSApp.sendAction(#selector(LatchApplicationDelegate.showSettings(_:)), to: nil, from: nil)
                },
            ])
        bannerRow.isHidden = banner.isHidden
    }

    /// The recovery path for everything the banner reports: rescan the filesystem, rebuild
    /// the catalog, connect again. Installing a prerequisite and pressing Retry is the whole
    /// loop — nothing here needs the harness reselected for the new state to be noticed.
    private func retryConnection() {
        guard canEditLaunch, !shuttingDown else { return }
        banner.resetDismissal()
        rescanLaunchEnvironment()
        updateAgentCommand()
        initializeSelection()
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

    func undoManager(for view: NSTextView) -> UndoManager? { view === prompt ? composerUndo : nil }

    /// Settings changed the offered agents or the custom command. A connected session keeps
    /// the harness it is running on; a disconnected one adopts the new command so the next
    /// connection uses what the user just configured.
    @objc private func agentSettingsChanged() {
        guard isViewLoaded, !shuttingDown else { return }
        let adopted = settings.customCommand
        if selectedAgent == .custom, model.phase == .disconnected, adopted != customCommand, !holdsConversation {
            customCommand = adopted
            pendingNewContext = true
        }
        rescanLaunchEnvironment()
        updateAgentCommand()
        refresh()
    }

    private var canEditLaunch: Bool {
        !shuttingDown && !changingConfiguration && !model.isChangingConfiguration &&
            model.phase != .prompting
    }

    /// The one route into changing this session's harness, whatever asked for it.
    func chooseHarness(_ selection: AgentPreset) {
        guard canEditLaunch else { return }
        // Choosing rescans, so installing a prerequisite and picking the agent again
        // still works; the banner's Retry is the same path with a name on it.
        rescanLaunchEnvironment()
        if selection != selectedAgent, holdsConversation {
            return fork(agent: selection, command: customCommand)
        }
        let unchanged = selection == selectedAgent
        if !unchanged { pendingNewContext = true }
        selectedAgent = selection
        updateAgentCommand()
        if unchanged && operation == nil && model.phase == .ready {
            refresh()
            return
        }
        banner.resetDismissal()
        initializeSelection()
    }

    /// Leave this session exactly as it was — its transcript, agent context, harness, and
    /// committed command all survive — and let the window open the sibling session.
    private func fork(agent: AgentPreset, command newCommand: String) {
        refresh()
        onForkSession?(agent, agent == .custom ? newCommand : customCommand)
        onChange?()
    }

    /// Re-reads installed agents and Node locations from the filesystem and rebuilds the
    /// catalog from them. Tests inject a fixed environment, which must not be replaced by a
    /// real scan — but its catalog is still rebuilt, because the custom command can change.
    private func rescanLaunchEnvironment() {
        if injectedLaunchEnvironment == nil { launchEnvironment = AgentLaunchEnvironment() }
        catalog = AgentCatalog(environment: launchEnvironment, customCommand: customCommand)
    }

    /// Re-resolves the selected harness. The command Latch will run and the problem stopping
    /// it are read from the catalog, never from the contents of a control.
    private func updateAgentCommand() {
        selectedRecipe = selectedAgent.recipe(in: launchEnvironment)
        let status = catalog.status(for: selectedAgent)
        launchCommand = status.command
        launchProblem = status.readiness.problem
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
        let input = launchCommand
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
              !model.isChangingConfiguration,
              model.phase == .ready else { return }
        let token = UUID()
        operation = token
        refresh()
        operationTask = Task {
            defer {
                if operation == token { operation = nil; operationTask = nil; refresh() }
            }
            guard !Task.isCancelled, !shuttingDown, operation == token,
                  model.phase == .ready else { return }
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

    private func smokeEnvironment(_ fixtureHome: URL) -> AgentLaunchEnvironment {
        AgentLaunchEnvironment(environment: [
            "PATH": [fixtureHome.appendingPathComponent(".local/bin").path,
                     fixtureHome.appendingPathComponent(".local/share/fnm/node-versions/v99.0.0/installation/bin").path,
                     "/usr/bin", "/bin"].joined(separator: ":"),
            "HOME": fixtureHome.path,
        ], home: fixtureHome, includeCommonLocations: false)
    }

    /// Drives the production selection path, the way the window's harness control does.
    func smokeSelectAgent(_ agent: AgentPreset) { chooseHarness(agent) }

    /// Sets the command a custom harness runs, the way the Agents settings pane does —
    /// including the new agent context a different command requires.
    func smokeSetCustomCommand(_ value: String) {
        if value != customCommand { pendingNewContext = true }
        customCommand = value
        rescanLaunchEnvironment()
        updateAgentCommand()
    }

    /// Phase one. Exercises actual AppKit controls without a model provider, file picker, or
    /// UI scripting permissions. The caller creates this session with `fixtureHome` as its workspace.
    func smokeTestConversation(fixtureHome: URL) async throws {
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
        launchEnvironment = smokeEnvironment(fixtureHome)
        // Default initialization is injected before loadView; only fixture executables exist here.
        // Inherit this run's settings, never the ones this Mac's owner configured.
        let initial = SessionViewController(workspace: workspace, launchEnvironment: launchEnvironment,
                                            settings: settings)
        _ = initial.view
        try await wait { initial.model.phase == .ready && initial.operation == nil }
        guard initial.selectedAgent == .fx, initial.model.messages.isEmpty else {
            throw SmokeError.failed("Default selection did not initialize without a prompt")
        }
        await initial.shutdown()
        smokeSelectAgent(.fx)
        prompt.string = "Unsent initialization draft"
        sendPrompt()
        guard prompt.string == "Unsent initialization draft", model.messages.isEmpty else {
            throw SmokeError.failed("Send during initialization consumed a draft")
        }
        try await wait { self.model.phase == .ready && self.operation == nil }
        prompt.string = ""
        refresh()
        guard launchCommand == "fx acp", launchProblem == nil else {
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
        guard bannerRow.isHidden, harnessSelection.isEditable else {
            throw SmokeError.failed("A connected agent must show no banner and stay switchable")
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
        // Model mutations are immediate; text-only rendering waits for its next frame.
        try await wait {
            self.model.messages.contains(where: { $0.role == .assistant && $0.text.contains("working") })
                && self.cancel.isEnabled && self.conversation.messageCount == self.model.messages.count
        }
        guard conversation.messageCount == model.messages.count,
              model.messages.contains(where: { $0.role == .user }),
              model.messages.contains(where: { $0.role == .assistant }), prompt.string.isEmpty else {
            throw SmokeError.failed("Chat did not render separate messages or clear the sent draft")
        }
        cancel.performClick(nil)
        try await wait { self.model.phase == .ready && self.model.status == "Cancelled" }
        guard harnessSelection.isEditable else { throw SmokeError.failed("Idle connected session cannot switch harness") }
        guard model.errorMessage == nil else { throw SmokeError.failed(model.errorMessage!) }
    }

    /// Phase two, on the sibling session that switching harness forked. Keeps fallback
    /// testing independent of integrations installed on the developer's Mac.
    func smokeTestFallbackHarness(fixtureHome: URL) async throws {
        let marker = fixtureHome.appendingPathComponent("npm-ran")
        launchEnvironment = smokeEnvironment(fixtureHome)
        try await wait { self.model.phase == .ready && self.operation == nil }
        guard model.messages.isEmpty, FileManager.default.fileExists(atPath: marker.path) else {
            throw SmokeError.failed("Harness selection did not initialize silently")
        }
        guard selectedRecipe?.requiresNode == true, launchProblem == nil, bannerRow.isHidden else {
            throw SmokeError.failed("Codex fallback was not ready, or reported a problem it does not have")
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
    }

    /// Phase three, on the session forked from the fallback harness: launch details,
    /// selection retry, drafts, configuration pickers, and permission sheets.
    func smokeTestLaunchLifecycle(fixtureHome: URL) async throws {
        launchEnvironment = smokeEnvironment(fixtureHome)
        try await wait { self.model.phase == .disconnected && self.operation == nil }
        try smokeTestLaunchDetailsBounds()
        try await smokeTestSelectionRetry()
        try await smokeTestShutdownDraft()
        try await smokeTestConfigurationPickers()

        // Exercise safe default dismissal and explicit selection using the actual sheet buttons.
        for (buttonIndex, result) in [(-1, "permission cancelled"), (-2, "permission cancelled"), (0, "permission cancelled"), (1, "permission selected")] {
            // Each pass needs an empty context, which a command change already declares:
            // an ordinary reconnection resumes, and this fixture reports loadSession: false.
            smokeSetCustomCommand("sh -c " + AgentCommand.quotedArgument(SmokeAgent.permissionScript))
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
                if let label = child as? NSTextField,
                   ["Local session, not saved", "Return to send"].contains(where: label.stringValue.contains) {
                    throw SmokeError.failed("Composer footer remains in the view hierarchy: \(label.stringValue)")
                }
                try checkRemovedControls(child)
            }
        }
        try checkRemovedControls(view)
        // Nothing may reintroduce launch plumbing above the transcript: the command field,
        // its hint, and the executable browser all belong to the Agents settings pane now.
        func checkRelocatedControls(_ container: NSView) throws {
            for child in container.subviews {
                if let button = child as? NSButton, button.title == "Choose Executable…" {
                    throw SmokeError.failed("The executable browser belongs in Settings, not in a session")
                }
                if let field = child as? NSTextField, field.isEditable, field !== prompt,
                   field.font?.fontName.contains("Mono") == true {
                    throw SmokeError.failed("A launch command field remains in the session view")
                }
                try checkRelocatedControls(child)
            }
        }
        try checkRelocatedControls(view)
        // The composer carries only the settings that change between messages.
        guard composerControls.pickerCount == 3 else {
            throw SmokeError.failed("The composer must not carry the harness picker")
        }
        let original = window.frame
        let restoredProblem = launchProblem
        defer {
            launchProblem = restoredProblem
            banner.resetDismissal()
            refresh()
            window.setFrame(original, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        // A long failure must wrap inside the banner rather than push the transcript away.
        launchProblem = String(repeating: "The agent could not start. Install Node.js 22+ with npm, then try again. ", count: 3)
        banner.resetDismissal()
        refresh()
        for size in [window.contentMinSize, NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            guard !bannerRow.isHidden, !banner.isHidden else {
                throw SmokeError.failed("A launch problem did not raise the banner at \(size)")
            }
            let controls: [NSView] = [banner, conversation, composerBox]
            let visible = controls.filter { !$0.isHiddenOrHasHiddenAncestor }
            for (index, control) in visible.enumerated() {
                let frame = control.convert(control.alignmentRect(forFrame: control.bounds), to: view)
                guard frame.width > 0, frame.height > 0,
                      view.bounds.insetBy(dx: -1, dy: -1).contains(frame) else {
                    throw SmokeError.failed("Session content clipped at \(size): \(frame)")
                }
                for other in visible.dropFirst(index + 1) {
                    let otherFrame = other.convert(other.alignmentRect(forFrame: other.bounds), to: view)
                    guard !frame.intersects(otherFrame) else {
                        throw SmokeError.failed("Session content overlaps at \(size): \(frame), \(otherFrame)")
                    }
                }
            }
            guard conversation.frame.height >= 40 else {
                throw SmokeError.failed("The banner squeezed the transcript out at \(size)")
            }
        }
        // Dismissing is final for that failure, and it gives the space straight back.
        banner.performDismissForSmokeTest()
        refresh()
        view.layoutSubtreeIfNeeded()
        guard bannerRow.isHidden else { throw SmokeError.failed("A dismissed banner kept its space") }
    }

    private func smokeTestComposerBounds() throws {
        guard let window = view.window else { throw SmokeError.failed("Missing smoke window") }
        let original = window.frame
        let draft = prompt.string
        defer {
            prompt.string = draft
            refresh()
            window.setFrame(original, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        for size in [window.contentMinSize, NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            let box = composerBox.convert(composerBox.bounds, to: view)
            let transcript = conversation.convert(conversation.bounds, to: view)
            let expected = transcript.width - ChatTranscriptView.horizontalInset * 2
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
            for (text, height) in [(String(repeating: "A long draft\n", count: 30), ChatComposerScrollView.maximumHeight),
                                   ("", ChatComposerScrollView.minimumHeight)] {
                prompt.string = text
                refresh()
                window.contentView?.layoutSubtreeIfNeeded()
                let resized = composerBox.convert(composerBox.bounds, to: view)
                guard abs(composer.frame.height - height) < 1,
                      resized.minY >= 0, resized.maxY <= view.bounds.height,
                      conversation.frame.height >= 40 else {
                    throw SmokeError.failed("Growing composer is clipped or incorrectly sized at \(size)")
                }
            }
        }
    }

    private func smokeTestSelectionRetry() async throws {
        smokeSetCustomCommand("/usr/bin/false")
        prompt.string = "Retain this draft"
        smokeSelectAgent(selectedAgent)
        try await wait { self.operation == nil && self.model.phase == .disconnected && self.model.errorMessage != nil }
        sendPrompt()
        guard prompt.string == "Retain this draft", !send.isEnabled, operation == nil else {
            throw SmokeError.failed("Disconnected Send retried or lost the draft")
        }
        // A failure states itself once, in the banner, with the actions that resolve it.
        guard !bannerRow.isHidden, !banner.isHidden else {
            throw SmokeError.failed("A failed connection did not raise the banner")
        }
        // Reselecting a failed harness retries, but never sends.
        smokeSelectAgent(selectedAgent)
        guard operation != nil else { throw SmokeError.failed("Reselection did not retry") }
        try await wait { self.operation == nil && self.model.phase == .disconnected }
        smokeSetCustomCommand("sh -c " + AgentCommand.quotedArgument("while IFS= read -r line; do :; done"))
        guard operation == nil else { throw SmokeError.failed("Configuring a command connected on its own") }
        retryConnection()
        try await wait { self.model.phase == .connecting }
        sendPrompt()
        guard cancel.isEnabled, harnessSelection.isEditable, prompt.isEditable, !send.isEnabled,
              model.messages.isEmpty, prompt.string == "Retain this draft" else {
            throw SmokeError.failed("Connecting must allow drafting, not sending")
        }
        cancel.performClick(nil)
        try await wait { self.operation == nil && self.model.phase == .disconnected }
        sendPrompt()
        guard operation == nil, model.messages.isEmpty else { throw SmokeError.failed("Stop allowed Send to reconnect") }

        // A hanging initialization must be disconnected before it is awaited; latest selection wins.
        smokeSelectAgent(selectedAgent)
        try await wait { self.model.phase == .connecting }
        for agent in [AgentPreset.fx, .codex, .fx] { smokeSelectAgent(agent) }
        try await wait { self.operation == nil && self.model.phase == .ready }
        guard selectedAgent == .fx, model.messages.isEmpty, prompt.string == "Retain this draft" else {
            throw SmokeError.failed("Rapid selection sent a draft or retained stale work")
        }
        smokeSelectAgent(selectedAgent)
        guard operation == nil, model.phase == .ready else { throw SmokeError.failed("Same ready harness restarted") }
        smokeSelectAgent(.custom)
        cancelPrompt() // Stop before the new initialization task starts.
        try await wait { self.operation == nil && self.model.phase == .disconnected }
        smokeSelectAgent(selectedAgent)
        cancelPrompt()
        smokeSelectAgent(selectedAgent) // A new selection wins even while Stop drains this same harness.
        try await wait { self.model.phase == .connecting }
        guard model.messages.isEmpty, prompt.string == "Retain this draft" else {
            throw SmokeError.failed("Reselecting during Stop consumed the draft")
        }
        cancel.performClick(nil)
        try await wait { self.operation == nil && self.model.phase == .disconnected }
        smokeSetCustomCommand("sh -c " + AgentCommand.quotedArgument(SmokeAgent.script))
        // Configuring a command never connects on its own, and Send must not do it either:
        // reconnecting is Retry's job, and it has to stay the only route back.
        sendPrompt()
        guard operation == nil, model.messages.isEmpty, model.phase == .disconnected else {
            throw SmokeError.failed("Send connected a disconnected session")
        }
        retryConnection()
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
        smokeSelectAgent(selectedAgent)
        try await wait { self.operation == nil && self.model.phase == .ready }
        guard model.messages.filter({ $0.role == .user }).count == sent,
              prompt.string == "Reselection retains draft" else {
            throw SmokeError.failed("Reselecting the connected agent sent a prompt or lost the draft")
        }
        disconnect()
        try await wait { self.operation == nil && self.model.phase == .disconnected }
    }

    private func smokeTestShutdownDraft() async throws {
        let session = SessionViewController(workspace: workspace, launchEnvironment: launchEnvironment,
                                            settings: settings)
        _ = session.view
        session.smokeSelectAgent(.custom)
        session.smokeSetCustomCommand("sh -c " + AgentCommand.quotedArgument(SmokeAgent.script))
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
        // Selection retry left a transcript here, so committing an edit would fork a sibling
        // instead (covered in SessionWindowController.smokeTest). Reconfigure in place: the
        // committed-edit path is already exercised by smokeTestSelectionRetry.
        smokeSetCustomCommand("sh -c " + AgentCommand.quotedArgument(ConfigurationSmokeAgent.script(variant: .permissionMode)))
        pendingNewContext = true
        initializeSelection()
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

    private func wait(in phase: String = #function, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            if ContinuousClock.now >= deadline {
                throw SmokeError.failed("Timed out in \(phase): \(selectedAgent.title) \(model.status) \(launchProblem ?? model.errorMessage ?? "")")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

enum SmokeError: Error { case failed(String) }
