import AppKit
import LatchACP
import LatchAgentCore
import LatchRemoteProtocol
import LatchSessionKit
import UniformTypeIdentifiers

/// One ACP session: agent selection, settings, transcript, and composer.
/// The workspace is fixed at creation; the sidebar owns the list of sessions.
@MainActor
final class SessionViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    let model: SessionModel
    let id: UUID
    /// A folder on this Mac or a path on a server; fixed for the session's life.
    let location: WorkspaceLocation
    /// The folder on this Mac, for everything that needs one. Nil for a remote session.
    var localURL: URL? { location.localURL }
    /// The folder of a local session. Kept for callers that predate remote sessions; new code
    /// asks `localURL`, so a remote session cannot be treated as a folder here by accident.
    @available(*, deprecated, message: "Local sessions only: use localURL or location")
    var workspace: URL { location.localURL ?? URL(fileURLWithPath: location.path) }
    private var pendingNewContext = false

    /// No view loading or process launch is needed to save an unopened sidebar row.
    /// Only the committed command is stored: an uncommitted edit is transient UI state,
    /// because committing one forks a sibling session rather than replacing this context.
    var savedSession: SavedSession {
        SavedSession(id: id, workspacePath: location.path, title: sessionTitle,
                     agentID: selectedAgent.rawValue,
                     customCommand: customCommand,
                     draft: prompt.string,
                     messages: pendingNewContext ? [] : model.messages,
                     agentSessionID: pendingNewContext ? nil : model.savedAgentSessionID,
                     lastActiveAt: model.lastActiveAt,
                     serverID: location.serverID,
                     remote: pendingNewContext ? nil : model.remoteBinding,
                     adoptedAgentTitle: adoptedAgentTitle == sessionTitle ? adoptedAgentTitle : nil)
    }

    /// The server's name for a remote session, even once the server has left Settings.
    var serverName: String? {
        location.serverID.map { servers.server(id: $0)?.name ?? "Removed server" }
    }

    /// Where the session works, as the window's subtitle says it: a path with `~` for this
    /// Mac's home, or `server · path`.
    var locationTitle: String {
        switch location {
        case let .local(url): url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case let .remote(_, path): "\(serverName ?? "") · \(path)"
        }
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
        // Named as Settings has the server now, in case it was renamed since.
        if model.stoppedOnServer, let serverName { return "Stopped on \(serverName)" }
        if selectedAgent != .custom, model.status.hasPrefix("Connected · ") {
            return "Connected · \(selectedAgent.title)"
        }
        // An idle saved session is the ordinary case, and the hollow indicator already says it is
        // not connected. Repeating that on every row told the reader nothing; which agent the
        // session belongs to is what differs between rows.
        if model.phase == .disconnected, model.errorMessage == nil, model.status == SessionModel.idleSavedStatus {
            return selectedAgent.title
        }
        return model.status
    }

    /// A reply finished while another session was on screen. Selecting this one clears it.
    var hasUnseenReply = false

    /// The sidebar row. Only working, a pending decision, a failure and an unread reply get a
    /// mark; a session at rest says which agent it belongs to and nothing else, so "Ready ·
    /// end_turn" and "Connected ·" never reach the list.
    func sidebarRow(now: Date) -> (status: SessionCellView.Status, detail: String) {
        if model.permissions.current != nil { return (.waiting, "Waiting for a decision") }
        if model.questions.current != nil { return (.waiting, "Waiting for an answer") }
        // Ahead of a failure: a live session's error is an earlier prompt's or change's, and
        // the lost link is what matters now.
        if let reconnecting = reconnectingTitle { return (.working, reconnecting) }
        if model.errorMessage != nil {
            return (.failed, model.status == "Not connected" ? "Couldn’t connect" : displayStatus)
        }
        switch model.phase {
        case .prompting where model.status == "Working…":
            // How long this turn has run, so a long one looks long.
            let elapsed = model.promptStartedAt.map { RelativeTime.duration(now.timeIntervalSince($0)) }
            return (.working, elapsed.map { "Working · \($0)" } ?? model.status)
        case .connecting, .stopping, .prompting: return (.working, model.status)
        case .ready: return (hasUnseenReply ? .unseen : .resting, selectedAgent.title)
        case .disconnected: return (.resting, displayStatus)
        }
    }

    /// Whether the sidebar should tick every second for this session.
    var isWorkingTurn: Bool { model.phase == .prompting }

    /// What this session wants the user to know about, whether or not it is on screen.
    var attention: AttentionCenter.State {
        let pending = model.permissions.current
        return AttentionCenter.State(
            workspaceName: serverName.map { "\($0) · \(location.folderName)" } ?? location.folderName,
            permission: pending?.id,
            question: model.questions.current?.id,
            allowOptionID: pending?.options.first { $0.kind == "allow_once" }?.optionId,
            rejectOptionID: pending?.options.first { $0.kind == "reject_once" }?.optionId,
            isPrompting: model.phase == .prompting,
            turnsEnded: model.turnsEnded,
            lastTurnStopped: model.lastTurnEndedByStop
        )
    }

    var menuBarRow: MenuBarSession {
        MenuBarSession(id: id, title: sessionTitle, status: reconnectingTitle ?? displayStatus,
                       phase: model.phase, needsPermission: model.permissions.current != nil || model.questions.current != nil)
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
    /// The agent's question on screen. One sheet at a time: a question waits for a request's
    /// sheet to close, and a request for a question's.
    private(set) var questionSheet: QuestionSheet?
    private let settings: AgentSettings
    /// Names and custom commands of the servers remote sessions run on.
    private let servers: any ServerStore
    /// How a remote session reaches its server. Never consulted for a local one.
    private let remoteConnector: any RemoteSessionConnector
    /// Something refused on its way into the composer, said once on the banner. The ID keys
    /// the banner, so a second refusal is shown even after the first was dismissed.
    private var attachmentNotice: (id: UUID, title: String, message: String)?
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
    /// Attached to a runtime left on a server before the view was ever loaded.
    private var reattachedAtLaunch = false
    /// Connection problems and their remedies. Fixed-height chrome is gone: the banner
    /// appears above the transcript only while there is something to say. It is the
    /// session's whole error surface, so tests read it rather than a hidden label.
    let banner = SessionBannerView()
    /// Whether a draft can be typed, for tests.
    var composerAcceptsText: Bool { prompt.isEditable }
    var composerPlaceholder: String { prompt.placeholder }
    /// Collapses out of the stack with the banner, so a session with nothing wrong gives
    /// the whole column to the transcript.
    private let bannerRow = NSView()
    private let composerContainer = NSView()
    let conversation = ChatTranscriptView(frame: .zero)
    /// A session with nothing in it yet opens on its workspace, not on an empty page.
    private let emptyHeading = NSTextField(labelWithString: "")
    private let commandMenu = SlashCommandMenu()
    /// The agent's plan, over the composer while it has one.
    private let planPanel = PlanPanel()
    /// Pasted or dropped into the composer, sent with the next prompt, then cleared with it.
    /// Not saved with the draft: an image's bytes would bloat the session library.
    private(set) var attachments: [ComposerAttachment] = []
    private let attachmentStrip = ComposerAttachmentStrip()
    /// Escape closes the menu for this draft only; typing on, or starting over, opens it again.
    private var dismissedCommandDraft: String?
    private let prompt = ChatInputView(frame: .zero)
    private let composer = ChatComposerScrollView(frame: .zero)
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let attach = NSButton(title: "", target: nil, action: nil)
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let permissionModePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The agent's other options, such as Claude Code's Fast mode, in its order; hidden when
    /// it offers none, and any past these are not shown.
    private let extraPickers = [NSPopUpButton(frame: .zero, pullsDown: false), NSPopUpButton(frame: .zero, pullsDown: false)]
    /// How full the agent's context is, before the composer's buttons.
    private let usageLabel = NSTextField(labelWithString: "")
    /// Only the settings that change between messages. The harness is chosen once per
    /// session and then locked, so it lives in the window's toolbar, not in the composer.
    private lazy var composerControls = ComposerControlsView(
        pickers: [.init(modelPicker, maximumWidth: 260),
                  .init(effortPicker, maximumWidth: 150),
                  .init(permissionModePicker)] + extraPickers.map { .init($0, maximumWidth: 180) },
        actions: [attach, cancel, send], accessory: usageLabel)
    /// The agent's title the session took last, so a later one may replace it but a rename
    /// is never overwritten.
    private var adoptedAgentTitle: String?
    private var renderedConfiguration: SessionConfiguration?
    private var renderedPickerPlaceholder: String?
    private lazy var transcriptUpdates = TranscriptRenderScheduler { [weak self] in
        self?.renderTranscript()
    }

    /// A session in a folder on this Mac.
    convenience init(workspace: URL, launchEnvironment: AgentLaunchEnvironment? = nil, savedSession: SavedSession? = nil,
                     initialAgent: AgentPreset? = nil, initialCommand: String? = nil,
                     settings: AgentSettings? = nil) {
        self.init(location: .local(workspace), launchEnvironment: launchEnvironment, savedSession: savedSession,
                  initialAgent: initialAgent, initialCommand: initialCommand, settings: settings)
    }

    init(location: WorkspaceLocation, launchEnvironment: AgentLaunchEnvironment? = nil, savedSession: SavedSession? = nil,
         initialAgent: AgentPreset? = nil, initialCommand: String? = nil,
         settings: AgentSettings? = nil, servers: (any ServerStore)? = nil,
         remoteConnector: (any RemoteSessionConnector)? = nil) {
        self.id = savedSession?.id ?? UUID()
        self.location = location
        let servers = servers ?? FileServerStore.shared
        self.servers = servers
        let remoteConnector = remoteConnector ?? UnconnectedRemoteSessionConnector()
        self.remoteConnector = remoteConnector
        if let serverID = location.serverID {
            model = SessionModel(makeClient: { remoteConnector.makeClient(serverID: serverID) })
            model.sendsAttachmentsRemotely = true
        } else {
            model = SessionModel(makeClient: AgentServiceClients.makeDefault)
        }
        self.injectedLaunchEnvironment = launchEnvironment
        // A remote agent's readiness is the server's business, so a remote session never
        // scans this Mac for agents: its environment searches nowhere.
        self.launchEnvironment = launchEnvironment
            ?? (location.isRemote ? Self.remoteEnvironment : AgentLaunchEnvironment())
        let settings = settings ?? .shared
        self.settings = settings
        // A fresh session starts on the command configured in Settings; a restored or
        // forked one keeps the command it already connected with. A remote one runs its
        // server's command.
        let server = location.serverID.flatMap { servers.server(id: $0) }
        let command = initialCommand ?? savedSession?.customCommand ?? server?.customCommand ?? settings.customCommand
        catalog = AgentCatalog(environment: self.launchEnvironment, customCommand: location.isRemote ? "" : command)
        selectedAgent = savedSession.flatMap { AgentPreset(rawValue: $0.agentID) }
            ?? initialAgent
            ?? (location.isRemote ? .fx : settings.suggested(in: catalog))
        super.init(nibName: nil, bundle: nil)
        customCommand = command
        if let savedSession {
            sessionTitle = savedSession.title
            adoptedAgentTitle = savedSession.adoptedAgentTitle
            prompt.string = savedSession.draft
            model.restore(messages: savedSession.messages, agentSessionID: savedSession.agentSessionID,
                          lastActiveAt: savedSession.lastActiveAt,
                          remote: location.isRemote ? savedSession.remote : nil)
        } else {
            // A new session was last active when it was made, so it sorts and reads as "now".
            model.restore(messages: [], agentSessionID: nil, lastActiveAt: model.now())
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
        if location.isRemote {
            NotificationCenter.default.addObserver(self, selector: #selector(serversChanged),
                                                   name: .serverStoreDidChange, object: servers)
        }
    }

    private static let remoteEnvironment = AgentLaunchEnvironment(
        environment: [:], home: URL(fileURLWithPath: "/var/empty"), includeCommonLocations: false)

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func loadView() {
        view = NSView()
        buildContent()
        updateAgentCommand()
        // Already on its way back to its server's runtime; connecting again would stop it.
        if reattachedAtLaunch { refresh() } else { initializeSelection() }
    }

    private func buildContent() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            // Edge to edge: the transcript's own inset is the only side margin, and its scroll bar
            // sits at the window's edge where a Mac scroll bar belongs.
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The transcript runs from the toolbar to the window's bottom edge; the composer floats
            // over its end rather than sitting below it.
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // The banner keeps the transcript's column so a failure reads as part of the
        // conversation rather than as a second header above it.
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerRow.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: bannerRow.leadingAnchor, constant: ChatTranscriptView.horizontalInset),
            banner.trailingAnchor.constraint(equalTo: bannerRow.trailingAnchor, constant: -ChatTranscriptView.horizontalInset),
            banner.topAnchor.constraint(equalTo: bannerRow.topAnchor, constant: 12),
            banner.bottomAnchor.constraint(equalTo: bannerRow.bottomAnchor),
        ])
        banner.isHidden = true
        bannerRow.isHidden = true
        // A dismissed refusal is done with; whatever it was covering gets its say again.
        banner.onDismiss = { [weak self] in
            guard let self, self.attachmentNotice != nil else { return }
            self.attachmentNotice = nil
            self.refresh()
        }
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
        usageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        usageLabel.textColor = .secondaryLabelColor
        for picker in [modelPicker, effortPicker, permissionModePicker] + extraPickers {
            // Three bezelled pop-ups in a row made the composer look like a form. Borderless, a
            // pop-up is its title and the system's own arrows, which is all the affordance it needs.
            if #available(macOS 26.0, *) {
                // The same control as the agent picker in the toolbar above it: large, glass, a
                // capsule, one chevron. It stays a select-style pop-up underneath, because its menu
                // belongs over the button down here, so the chevron is ours and the arrows are off.
                // A pop-up's own glass bezel is a flat fill, not the clear, rimmed glass the toolbar
                // control and Send get, so the capsule is a glass surface ComposerControlsView puts
                // behind a borderless pop-up.
                picker.controlSize = .large
                picker.isBordered = false
                (picker.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
                _ = PickerChevron(in: picker)
            } else {
                picker.controlSize = .regular
                picker.font = .systemFont(ofSize: NSFont.systemFontSize)
                picker.isBordered = false
                picker.contentTintColor = .secondaryLabelColor
            }
            picker.target = self
            picker.cell?.lineBreakMode = .byTruncatingTail
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            picker.setContentHuggingPriority(.required, for: .horizontal)
            picker.menu?.autoenablesItems = false
        }
        modelPicker.action = #selector(selectModel)
        for picker in extraPickers { picker.action = #selector(selectExtra(_:)) }
        effortPicker.action = #selector(selectEffort)
        permissionModePicker.action = #selector(selectPermissionMode)
        modelPicker.setAccessibilityLabel("Session model")
        effortPicker.setAccessibilityLabel("Reasoning effort")
        permissionModePicker.setAccessibilityLabel("Permission mode")
        composer.borderType = .noBorder
        composer.drawsBackground = false
        prompt.drawsBackground = false
        prompt.onSubmit = { [weak self] in self?.sendPrompt() }
        prompt.onMenuKey = { [weak self] key in self?.handleCommandMenuKey(key) ?? false }
        commandMenu.onAccept = { [weak self] command in self?.acceptCommand(command) }
        prompt.onAttach = { [weak self] pasteboard in self?.attach(from: pasteboard) ?? false }
        attachmentStrip.onRemove = { [weak self] id in self?.removeAttachment(id) }
        attachmentStrip.isHidden = true
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
        composerContent.addArrangedSubview(attachmentStrip)
        composerContent.addArrangedSubview(composer)

        send.target = self
        send.action = #selector(sendPrompt)
        send.bezelStyle = .circular
        if #available(macOS 26.0, *) {
            for button in [send, cancel] {
                button.bezelStyle = .glass
                button.borderShape = .circle
            }
            // The system's own accent treatment: a white arrow on the fill, and the plain rim
            // while disabled. A forced bezel colour drew the arrow black.
            send.tintProminence = .primary
        }
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        cancel.target = self
        cancel.action = #selector(cancelPrompt)
        cancel.bezelStyle = .circular
        send.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send message")
        cancel.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop response")
        for button in [send, cancel] {
            button.imagePosition = .imageOnly
            button.controlSize = .large
        }
        // Plain, not glass: beside Send it is a quiet way in, as the paperclip is elsewhere.
        attach.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach files")
        attach.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        attach.isBordered = false
        attach.imagePosition = .imageOnly
        attach.contentTintColor = .secondaryLabelColor
        attach.target = self
        attach.action = #selector(chooseAttachments(_:))
        attach.toolTip = "Attach Files… (⇧⌘A)"
        attach.setAccessibilityLabel("Attach files")
        send.setAccessibilityLabel("Send message")
        send.toolTip = "Send message (Return or ⌘ Return)"
        cancel.setAccessibilityLabel("Stop response")
        cancel.toolTip = "Stop the current response"
        composerContent.addArrangedSubview(composerControls)
        for item in composerContent.arrangedSubviews {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: composerContent.widthAnchor).isActive = true
        }
        composerBox.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.addSubview(composerBox)
        NSLayoutConstraint.activate([
            composerBox.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: ChatTranscriptView.horizontalInset),
            composerBox.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -ChatTranscriptView.horizontalInset),
            composerBox.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composerBox.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
        ])
        for view in root.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        // No keyboard caption under the composer: the shortcuts stay in the field's
        // accessibility help, where they cost no chrome.
        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerContainer, positioned: .above, relativeTo: root)
        NSLayoutConstraint.activate([
            composerContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composerContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            composerContainer.topAnchor.constraint(greaterThanOrEqualTo: bannerRow.bottomAnchor, constant: 12),
        ])

        emptyHeading.stringValue = "What should we build in \(location.folderName)?"
        emptyHeading.font = .systemFont(ofSize: 26)
        emptyHeading.alignment = .center
        emptyHeading.lineBreakMode = .byTruncatingMiddle
        emptyHeading.setAccessibilityRole(.staticText)
        emptyHeading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyHeading, positioned: .above, relativeTo: root)
        // Centred in the part of the transcript the composer leaves visible.
        let open = NSLayoutGuide()
        view.addLayoutGuide(open)
        NSLayoutConstraint.activate([
            open.topAnchor.constraint(equalTo: conversation.topAnchor),
            open.bottomAnchor.constraint(equalTo: composerContainer.topAnchor),
            emptyHeading.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            emptyHeading.centerXAnchor.constraint(equalTo: conversation.centerXAnchor),
            emptyHeading.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: ChatTranscriptView.horizontalInset),
        ])

        // Like the command menu, over the transcript and attached to the composer; the menu,
        // while open, takes its place.
        planPanel.isHidden = true
        planPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(planPanel, positioned: .above, relativeTo: composerContainer)
        NSLayoutConstraint.activate([
            planPanel.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 12),
            planPanel.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor, constant: -12),
            planPanel.bottomAnchor.constraint(equalTo: composerBox.topAnchor, constant: -8),
        ])

        // Over the transcript and the heading, attached to the composer it belongs to.
        commandMenu.isHidden = true
        commandMenu.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(commandMenu, positioned: .above, relativeTo: composerContainer)
        NSLayoutConstraint.activate([
            commandMenu.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 12),
            commandMenu.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor, constant: -12),
            commandMenu.bottomAnchor.constraint(equalTo: composerBox.topAnchor, constant: -8),
        ])
    }

    /// Tells the transcript how much of its end the composer covers, which changes as a draft grows.
    override func viewDidLayout() {
        super.viewDidLayout()
        // The plan, when shown, covers the transcript's end too.
        let composerTop = planPanel.isHidden ? composerContainer.frame.maxY : max(composerContainer.frame.maxY, planPanel.frame.maxY)
        let transcriptBottom = conversation.convert(conversation.bounds, to: view).minY
        conversation.bottomOverlay = max(0, composerTop - transcriptBottom + 12)
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
        refreshQuestion()
        adoptAgentTitle()
        refreshBanner()
        // Drafting can continue during connection setup; only a queued send locks the ready composer.
        // A read-only archive has nowhere to send a draft; an editable field there would promise otherwise.
        let readOnlyArchive = model.archivedWithoutContext && model.phase == .disconnected
        prompt.isEditable = !shuttingDown && !readOnlyArchive && (operation == nil || model.phase != .ready)
        refreshPickers()
        send.isEnabled = !shuttingDown && operation == nil && !changingConfiguration && model.phase == .ready && !model.isChangingConfiguration && hasSomethingToSend
        let preparing = operation != nil || model.phase == .connecting
        // A forced bezel colour ignores the disabled state, so a button that could not send looked ready to.
        if #unavailable(macOS 26.0) {
            // A forced bezel colour ignores the disabled state, so a button that could not send looked ready to.
            send.bezelColor = send.isEnabled ? .controlAccentColor : nil
        }
        cancel.isEnabled = canStop
        cancel.isHidden = !preparing && model.phase != .prompting
        composerControls.refreshLayout()
        prompt.placeholder = readOnlyArchive ? "This conversation is read-only" : "Message \(selectedAgent.title)…"
        attachmentStrip.show(attachments)
        attach.isEnabled = canAttachFiles
        refreshCommandMenu()
        // A banner is the more important thing on an empty page, so the heading yields to it,
        // and to the command menu, whose glass it would otherwise show through.
        emptyHeading.isHidden = !model.messages.isEmpty || model.phase == .prompting || !bannerRow.isHidden
            || !commandMenu.isHidden
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
        // offering it: the current selection always has to be representable. A server
        // offers every preset, whatever this Mac's Agents pane has switched off, and Custom
        // only when it has a command for it.
        let presets = AgentPreset.allCases.filter { preset in
            guard preset != selectedAgent else { return true }
            guard let serverID = location.serverID else { return settings.isEnabled(preset) }
            if preset == .custom { return !(servers.server(id: serverID)?.customCommand.isEmpty ?? true) }
            return true
        }
        let rows = presets.map { preset in
            HarnessSelection.Row(preset: preset, title: preset.title, detail: agentDetail(for: preset),
                                 isCurrent: preset == selectedAgent)
        }
        return HarnessSelection(rows: rows, current: selectedAgent,
                                problem: location.isRemote ? launchProblem : catalog.status(for: selectedAgent).readiness.problem,
                                isEditable: canEditLaunch && !shuttingDown)
    }

    /// Switching harness once a transcript exists opens a sibling session rather than
    /// replacing this one's context. Say so on the row, before it happens. A remote agent
    /// has no readiness here to report: the server says what it lacks when it launches.
    private func agentDetail(for preset: AgentPreset) -> String {
        if holdsConversation, preset != selectedAgent { return "Opens a new session" }
        if let serverName { return "Runs on \(serverName)" }
        return catalog.status(for: preset).readiness.badge
    }

    /// "Reconnecting to vps…" while a live remote session's server is out of reach. The
    /// session stays as it was: the turn, the agent and any pending decision wait for it.
    /// Named as Settings has the server now, in case it was renamed since the launch.
    private var reconnectingTitle: String? {
        guard case let .reconnecting(server, _) = model.linkState, model.phase != .disconnected else { return nil }
        let name = serverName ?? server
        return model.phase == .connecting ? "Connecting to \(name)…" : "Reconnecting to \(name)…"
    }

    /// The single place a connection problem is reported. Keyed on the failure itself, so
    /// dismissing one keeps it dismissed while nothing has changed, and a different failure
    /// always gets its say.
    private func refreshBanner() {
        // Waiting for a server is not a failure, but it explains why nothing is arriving, and
        // it outranks an earlier prompt's error. Keyed on the outage, so a dismissed one stays
        // dismissed. A server not yet reached may be misconfigured, so Settings is offered.
        if let reconnecting = reconnectingTitle, case let .reconnecting(_, since) = model.linkState,
           launchProblem == nil, !shuttingDown {
            let message = switch model.phase {
            case .connecting: "It has not answered yet. Latch keeps trying for a few seconds."
            case .prompting: "The agent keeps working on the server. Latch catches up once it answers again."
            default: "The agent is still running there. Latch reconnects on its own."
            }
            banner.update(key: "link\u{0}\(since.timeIntervalSinceReferenceDate)\u{0}\(message)", title: reconnecting,
                          message: message, severity: .info,
                          actions: model.phase == .connecting ? [serverSettingsAction] : [])
            bannerRow.isHidden = banner.isHidden
            return
        }
        // A refused attachment is said once, and never over a failure, which has its own
        // remedy to offer.
        if let notice = attachmentNotice, model.errorMessage == nil, launchProblem == nil, !shuttingDown {
            banner.update(key: "attachments\u{0}\(notice.id)", title: notice.title, message: notice.message,
                          severity: .warning, actions: [])
            bannerRow.isHidden = banner.isHidden
            return
        }
        let disconnected = model.phase == .disconnected
        if disconnected, model.archivedWithoutContext, model.errorMessage == nil, !shuttingDown {
            // A saved transcript that cannot be continued is a state, not a failure: no red, no Retry.
            banner.update(
                key: "archive\u{0}\(selectedAgent.rawValue)",
                title: "This conversation is read-only",
                message: "It was saved without the agent’s context, so it can’t be picked up where it left off. Its history stays here.",
                severity: .info,
                actions: canFork ? [SessionBannerView.Action(title: "Continue in New Session") { [weak self] in self?.forkSession() }] : [])
            bannerRow.isHidden = banner.isHidden
            return
        }
        // The agent's words go on their own line, then one line of advice: Latch's own for this
        // failure when it has some, otherwise the agent's setup hint for one that cannot start.
        let failure: (detail: String, advice: String)? = model.errorMessage.map { message in
            let builtIn = selectedAgent != .custom && disconnected
            let advice = model.errorAdvice ?? (builtIn ? selectedRecipe?.setup : nil) ?? ""
            if model.stoppedOnServer, let serverName { return ("The agent was stopped on \(serverName).", advice) }
            return (Self.agentWords(builtIn ? withoutLaunchInternals(message) : message), advice)
        } ?? launchProblem.map { ("", $0) }
        guard let failure, !shuttingDown else {
            banner.update(key: nil, title: "", message: "", severity: .error, actions: [])
            bannerRow.isHidden = true
            return
        }
        // Each attempt to connect is keyed apart, so one that fails the way a dismissed one did,
        // such as after a change in Settings, still has its say.
        banner.update(
            key: "\(model.phase)\u{0}\(model.connectionAttempts)\u{0}\(selectedAgent.rawValue)\u{0}\(failure.detail)\u{0}\(failure.advice)",
            title: failureTitle(disconnected: disconnected),
            message: failure.advice,
            detail: failure.detail,
            // An agent stopped on purpose, by another client or the server, is not a fault.
            severity: disconnected && !model.stoppedOnServer ? .error : .warning,
            actions: [
                SessionBannerView.Action(title: "Retry") { [weak self] in self?.retryConnection() },
                location.isRemote
                    ? serverSettingsAction
                    : SessionBannerView.Action(title: "Agent Settings…") {
                        NSApp.sendAction(#selector(LatchApplicationDelegate.showAgentSettings(_:)), to: nil, from: nil)
                    },
            ])
        bannerRow.isHidden = banner.isHidden
    }

    /// Opens Settings on this session's server, not whichever one the list shows first.
    private var serverSettingsAction: SessionBannerView.Action {
        let server = location.serverID.map(ServerReference.init)
        return SessionBannerView.Action(title: "Server Settings…") {
            NSApp.sendAction(#selector(LatchApplicationDelegate.showServerSettings(_:)), to: nil, from: server)
        }
    }

    /// Whose failure it is. A remote session names its server: an unreachable server is not
    /// the agent's fault, and an agent that cannot start there may start fine on this Mac.
    private func failureTitle(disconnected: Bool) -> String {
        guard let serverName else {
            return disconnected ? "\(selectedAgent.title) can’t start" : "\(selectedAgent.title) reported a problem"
        }
        if model.errorIsConnectionFailure { return "Can’t connect to \(serverName)" }
        if disconnected, model.stoppedOnServer {
            return "\(selectedAgent.title) stopped on \(serverName)"
        }
        if disconnected, case .failed(_, _, runtimeGone: true) = model.linkState {
            return "\(selectedAgent.title) stopped on \(serverName)"
        }
        return disconnected ? "\(selectedAgent.title) can’t start on \(serverName)" : "\(selectedAgent.title) reported a problem"
    }

    /// The banner's title already names the agent, so the service's "Agent reported:" prefix
    /// would only repeat it.
    static func agentWords(_ message: String) -> String {
        let prefix = "Agent reported: "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
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

    private func withoutLaunchInternals(_ message: String) -> String {
        // Preserve the actual failure, but keep launch implementation details out of built-in UI.
        var detail = message
        if let recipe = selectedRecipe, let parsed = try? AgentCommand(recipe.command) {
            let internals = [recipe.command, launchEnvironment.executable(named: parsed.executable),
                             parsed.executable] + parsed.arguments.filter { $0.hasPrefix("@agentclientprotocol/") }.map(Optional.some)
            for value in internals.compactMap({ $0 }).sorted(by: { $0.count > $1.count }) {
                detail = detail.replacingOccurrences(of: value, with: selectedAgent.title)
            }
        }
        return detail
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
        for (index, picker) in extraPickers.enumerated() {
            let extra = model.configuration.extras.indices.contains(index) ? model.configuration.extras[index] : nil
            if picker.identifier?.rawValue != extra.map(Self.configID) || picker.titleOfSelectedItem != extra.flatMap(Self.currentName) {
                populate(picker, from: extra, placeholder: placeholder)
                picker.identifier = extra.map { NSUserInterfaceItemIdentifier(Self.configID($0)) }
                picker.setAccessibilityLabel(extra?.name)
                picker.toolTip = extra.map { [$0.name, $0.description].compactMap { $0 }.joined(separator: ": ") }
            }
            picker.isHidden = extra == nil
            picker.isEnabled = editable && extra != nil
        }
        refreshUsage()
    }

    private static func configID(_ picker: SessionPicker) -> String {
        if case let .config(id) = picker.route { return id }
        return ""
    }

    private static func currentName(_ picker: SessionPicker) -> String? {
        picker.choices.first { $0.value == picker.currentValue }?.name
    }

    @objc private func selectExtra(_ sender: NSPopUpButton) {
        guard let configID = sender.identifier?.rawValue, !configID.isEmpty else { return }
        select(from: sender) { [model] value in await model.select(option: configID, value: value) }
    }

    /// "25% context", with the tokens and what the conversation has cost so far in its tooltip;
    /// amber once the context is mostly full, when the agent is about to compact it.
    private func refreshUsage() {
        guard let usage = model.usage else {
            usageLabel.stringValue = ""
            return
        }
        let percent = Int((usage.fraction * 100).rounded())
        usageLabel.stringValue = "\(percent)% context"
        usageLabel.textColor = usage.fraction >= 0.8 ? .systemOrange : .secondaryLabelColor
        let tokens = "\(usage.used.formatted()) of \(usage.size.formatted()) tokens"
        let cost = usage.cost.map { $0.formatted(.currency(code: usage.currency ?? "USD")) }
        usageLabel.toolTip = [tokens, cost.map { "\($0) so far" }].compactMap { $0 }.joined(separator: " · ")
        usageLabel.setAccessibilityLabel("Context \(percent)% full" + (cost.map { ", \($0) so far" } ?? ""))
        composerControls.refreshLayout()
    }

    private func adoptAgentTitle() {
        let firstPrompt = model.messages.first { $0.role == .user }?.text
        guard let title = Self.adoptedTitle(current: sessionTitle, agentTitle: model.agentTitle,
                                            firstPrompt: firstPrompt, adoptedBefore: adoptedAgentTitle) else { return }
        sessionTitle = title
        adoptedAgentTitle = title
        onChange?()
    }

    /// The agent's own title for the conversation replaces one taken from the first prompt, or
    /// one it gave before; never a name the user chose.
    static func adoptedTitle(current: String, agentTitle: String?, firstPrompt: String?, adoptedBefore: String?) -> String? {
        guard let agentTitle else { return nil }
        let title = String(agentTitle.prefix(60))
        guard title != current else { return nil }
        let fromPrompt = firstPrompt.map { text in
            String((text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).prefix(60))
        }
        return current == "New Session" || current == fromPrompt || current == adoptedBefore ? title : nil
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
            // Read in the menu, as a second line, rather than only after hovering an item.
            item.subtitle = choice.description
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
        button.toolTip = picker.description ?? selected?.subtitle ?? selected?.title
    }

    @objc private func selectModel() { select(.model, from: modelPicker) }
    @objc private func selectEffort() { select(.effort, from: effortPicker) }
    @objc private func selectPermissionMode() { select(.permissionMode, from: permissionModePicker) }

    private func select(_ kind: SessionPicker.Kind, from button: NSPopUpButton) {
        select(from: button) { [model] value in await model.select(kind, value: value) }
    }

    /// One choice at a time, and none while the session is busy; the pop-up shows the agent's
    /// value until the agent confirms the new one.
    private func select(from button: NSPopUpButton, _ change: @escaping @MainActor (String) async -> Void) {
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
            await change(value)
        }
    }

    private func refreshPermission() {
        guard let window = view.window else { return }
        let pending = model.permissions.current
        if let existing = permissionAlert {
            if existing.id != pending?.id { window.endSheet(existing.alert.window, returnCode: .abort) }
            return
        }
        guard let pending, questionSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        // Latch says what this is; the agent's heading, such as "Ready to code?", says what it wants.
        alert.messageText = "Agent requests permission"
        alert.informativeText = [pending.heading, pending.reason, "Review the agent-provided details below. “Always” is remembered by the agent, not by Latch. Cancel Request declines only this request; it doesn’t restrict the agent."]
            .compactMap { $0 }.joined(separator: "\n\n")
        // Return and Escape both cancel. No approval receives a default key equivalent.
        alert.addButton(withTitle: "Cancel Request").keyEquivalent = "\r"
        for option in pending.options { alert.addButton(withTitle: option.permissionLabel!).keyEquivalent = "" }
        let details = NSTextView()
        details.isEditable = false
        details.isSelectable = true
        details.isRichText = true
        details.setAccessibilityLabel("Agent-provided permission request details")
        details.textStorage?.setAttributedString(Self.permissionBody(pending))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: pending.plan == nil ? 220 : 300))
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
            self.refreshQuestion()
        }
    }

    /// The plan to approve, as Markdown, or the tool call's details; then each choice by
    /// Latch's own label, with the agent's words for it beside the label, never in its place.
    static func permissionBody(_ prompt: PermissionQueue.Prompt) -> NSAttributedString {
        let body = NSMutableAttributedString()
        if let plan = prompt.plan {
            body.append(ChatMarkdown.render(plan))
        } else {
            body.append(ToolTranscriptStyle.render(prompt.toolDetails, titled: false))
        }
        let words = prompt.options.compactMap { option in prompt.detail(for: option).map { (option.permissionLabel!, $0) } }
        if !words.isEmpty {
            let font = NSFont.systemFont(ofSize: 12)
            body.append(NSAttributedString(string: "\n\nWhat the agent says each choice means\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]))
            for (label, detail) in words {
                body.append(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                                           .foregroundColor: NSColor.labelColor]))
                body.append(NSAttributedString(string: ": " + detail + "\n", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        // All of it, below what is clipped for reading, so a long command's end is there to check.
        // A plan is shown whole already.
        if prompt.plan == nil {
            body.append(NSAttributedString(string: "\n\nFull request\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]))
            body.append(NSAttributedString(string: prompt.fullRequest, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return body
    }

    private func refreshQuestion() {
        guard let window = view.window else { return }
        let pending = model.questions.current
        if let sheet = questionSheet {
            // Withdrawn, or answered elsewhere: the sheet goes with it.
            guard sheet.question.id != pending?.id else { return }
            questionSheet = nil
            window.endSheet(sheet.panel)
            // What waited behind it comes up now; a blocked agent sends nothing else to bring it.
            refreshPermission()
        }
        guard let pending, permissionAlert == nil else { return }
        let sheet = QuestionSheet(question: pending)
        sheet.onFinish = { [weak self, weak sheet] outcome in
            guard let self, let sheet, self.questionSheet === sheet else { return }
            self.questionSheet = nil
            self.view.window?.endSheet(sheet.panel)
            switch outcome {
            case let .answer(answers): self.model.questions.answer(id: pending.id, with: answers)
            case .skip: self.model.questions.skip(id: pending.id)
            case .cancel: self.model.questions.cancel(id: pending.id)
            }
            self.refresh()
        }
        questionSheet = sheet
        window.beginSheet(sheet.panel)
    }

    /// Permission sheets need a window; a session selected while a request is pending attaches it now.
    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    func textDidChange(_ notification: Notification) {
        attachmentNotice = nil
        refresh()
        onChange?()
    }

    // MARK: Slash commands

    /// The query while the draft is a bare `/query`: one token, nothing after it yet.
    private var commandQuery: String? {
        let draft = prompt.string
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    private func refreshCommandMenu() {
        let draft = prompt.string
        if dismissedCommandDraft != nil, !draft.hasPrefix("/") { dismissedCommandDraft = nil }
        let open = prompt.isEditable && !model.commands.isEmpty && dismissedCommandDraft != draft
            && commandQuery.map { commandMenu.show(model.commands, query: $0) } == true
        commandMenu.isHidden = !open
        // Once a command is chosen, what it expects next shows after it until typing starts.
        let chosen = draft.hasPrefix("/") && draft.hasSuffix(" ") && draft.dropFirst().dropLast().allSatisfy { !$0.isWhitespace }
            ? model.commands.first { "/\($0.name) " == draft } : nil
        prompt.inputHint = chosen?.inputHint
        refreshPlan()
    }

    /// The plan shows while the agent has one, except under an open command menu.
    private func refreshPlan() {
        planPanel.show(model.plan)
        let hidden = model.plan.isEmpty || !commandMenu.isHidden
        guard planPanel.isHidden != hidden else { return }
        planPanel.isHidden = hidden
        view.needsLayout = true
    }

    private func handleCommandMenuKey(_ key: ChatInputView.MenuKey) -> Bool {
        guard !commandMenu.isHidden else { return false }
        switch key {
        case .up: commandMenu.moveSelection(by: -1)
        case .down: commandMenu.moveSelection(by: 1)
        case .accept:
            guard let command = commandMenu.selectedCommand else { return false }
            acceptCommand(command)
        case .dismiss:
            dismissedCommandDraft = prompt.string
            refreshCommandMenu()
        }
        return true
    }

    /// Replaces the draft through the text system, so undo returns to the typed query.
    private func acceptCommand(_ command: ACPAvailableCommand) {
        let whole = NSRange(location: 0, length: (prompt.string as NSString).length)
        let replacement = "/\(command.name) "
        guard prompt.shouldChangeText(in: whole, replacementString: replacement) else { return }
        prompt.replaceCharacters(in: whole, with: replacement)
        prompt.didChangeText()
        prompt.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
        view.window?.makeFirstResponder(prompt)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { view === prompt ? composerUndo : nil }

    /// Settings changed the offered agents or the custom command. A connected session keeps
    /// the harness it is running on; a disconnected one adopts the new command so the next
    /// connection uses what the user just configured.
    @objc private func agentSettingsChanged() {
        guard isViewLoaded, !shuttingDown else { return }
        let adopted = settings.customCommand
        // A remote session's command is its server's, never the one for this Mac.
        if !location.isRemote, selectedAgent == .custom, model.phase == .disconnected, adopted != customCommand,
           !holdsConversation {
            customCommand = adopted
            pendingNewContext = true
        }
        rescanLaunchEnvironment()
        updateAgentCommand()
        refresh()
        // The window's harness control renders from this session's catalog, so it can only
        // be told after the rescan — telling it from its own observer would race this one
        // and leave it reporting the previous scan.
        onChange?()
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
        guard !location.isRemote else { return }
        if injectedLaunchEnvironment == nil { launchEnvironment = AgentLaunchEnvironment() }
        catalog = AgentCatalog(environment: launchEnvironment, customCommand: customCommand)
    }

    /// Re-resolves the selected harness. The command Latch will run and the problem stopping
    /// it are read from the catalog, never from the contents of a control.
    private func updateAgentCommand() {
        if let serverID = location.serverID {
            // The server resolves its own agents; all that can be wrong here is a missing
            // server or a Custom agent the server has no command for.
            selectedRecipe = nil
            let server = servers.server(id: serverID)
            if let server { customCommand = server.customCommand }
            launchCommand = selectedAgent == .custom ? customCommand : ""
            launchProblem = if server == nil {
                "This session’s server is no longer in Settings."
            } else if selectedAgent == .custom, customCommand.isEmpty {
                "No custom agent command is set for \(server?.name ?? "this server")."
            } else {
                nil
            }
            return
        }
        selectedRecipe = selectedAgent.recipe(in: launchEnvironment)
        let status = catalog.status(for: selectedAgent)
        launchCommand = status.command
        launchProblem = status.readiness.problem
    }

    /// Serialize teardown, asking the model to unblock initialization BEFORE awaiting it.
    /// `detaching` leaves a remote runtime running rather than stopping it.
    private func drainConnection(detaching: Bool = false) -> Task<Void, Never> {
        actionGeneration = UUID()
        let pending = operationTask
        pending?.cancel()
        let previousDrain = drainTask
        let drain = Task {
            await previousDrain?.value
            if detaching { await model.detach() } else { await model.disconnect() }
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
        if location.isRemote { return initializeRemoteSelection() }
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
            await model.connect(command: input, workspace: localURL, launchEnvironment: environment, startNewSession: startNewSession)
            if operation == token, model.phase == .ready { pendingNewContext = false }
            onChange?()
        }
        refresh()
        onChange?()
    }

    /// The remote counterpart of a launch: the same drain and operation bookkeeping, but the
    /// model's channel came from the connector, so the launch goes to the server and nothing
    /// runs on this Mac. A server gone from Settings is a launch problem, so it never gets here.
    private func initializeRemoteSelection() {
        guard case let .remote(_, path) = location else { return }
        let drain = drainConnection()
        let token = UUID()
        let agent: LatchRemoteAgent = selectedAgent == .custom ? .custom(customCommand) : .preset(selectedAgent.rawValue)
        let valid = launchProblem == nil
        let startNewSession = pendingNewContext
        operation = token
        operationTask = Task {
            defer {
                if operation == token { operation = nil; operationTask = nil; refresh() }
            }
            await drain.value
            guard !Task.isCancelled, !shuttingDown, operation == token, valid else { return }
            await model.connect(remote: agent, path: path, startNewSession: startNewSession)
            if operation == token, model.phase == .ready { pendingNewContext = false }
            onChange?()
        }
        refresh()
        onChange?()
    }

    /// Attaches, as Latch launches, to the runtime its last run left on a server, whether or
    /// not this session is on screen: a turn that finished while Latch was closed, or a
    /// decision the agent is waiting for, reaches the notifications, the Dock badge and the
    /// menu bar now rather than when the session is next selected.
    func reattachAtLaunch() {
        guard location.isRemote, !isViewLoaded, !reattachedAtLaunch, model.remoteBinding != nil else { return }
        reattachedAtLaunch = true
        updateAgentCommand()
        initializeSelection()
    }

    /// A server was renamed, removed, or given another custom command.
    @objc private func serversChanged() {
        guard isViewLoaded, !shuttingDown else { return }
        updateAgentCommand()
        refresh()
        onChange?()
    }

    /// Send never initializes or retries a connection, nor commits an in-progress command edit.
    private var hasSomethingToSend: Bool {
        !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: Attachments

    /// Takes a paste or drop that holds files or an image. Returns false for anything else, so
    /// the field pastes it as text.
    private func attach(from pasteboard: NSPasteboard) -> Bool {
        guard prompt.isEditable else { return false }
        return add(ComposerAttachment.attachments(from: pasteboard))
    }

    var canAttachFiles: Bool { prompt.isEditable && attachments.count < ComposerAttachment.maximumCount }

    /// The paperclip and Session ▸ Attach Files…: a panel over the window, starting in the
    /// workspace, for files and folders alike. A remote session can send only images, and
    /// has no folder on this Mac, so its panel offers images and starts in the home folder.
    @objc func chooseAttachments(_ sender: Any?) {
        guard let window = view.window, canAttachFiles, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        if let localURL {
            panel.canChooseDirectories = true
            panel.directoryURL = localURL
            panel.message = "Choose files or folders to send with your message."
        } else {
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image]
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            panel.message = "Choose images to send with your message."
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.add(panel.urls.map(ComposerAttachment.fromFile))
            window.makeFirstResponder(self.prompt)
        }
    }

    /// Up to the limit; anything past it is refused with a beep rather than silently dropped.
    /// Paste, drop and the panel all arrive here, so this is where a remote session turns
    /// away what its agent cannot receive. A refused drop is still taken, so a file's path
    /// is not typed into the draft instead.
    @discardableResult
    private func add(_ added: [ComposerAttachment]) -> Bool {
        guard !added.isEmpty else { return false }
        var added = added
        attachmentNotice = nil
        let refused = added.filter { model.refusesRemotely($0.prompt) }
        if !refused.isEmpty {
            refuse(refused)
            added.removeAll { model.refusesRemotely($0.prompt) }
            guard !added.isEmpty else { return true }
        }
        let room = ComposerAttachment.maximumCount - attachments.count
        guard room > 0 else {
            NSSound.beep()
            return true
        }
        attachments += added.prefix(room)
        if added.count > room { NSSound.beep() }
        refresh()
        return true
    }

    /// Says why a remote agent cannot have these. Files and folders never reach a server; an
    /// image reaches only an agent that takes images.
    private func refuse(_ refused: [ComposerAttachment]) {
        attachmentNotice = if refused.allSatisfy(\.isImage) {
            (UUID(), "\(selectedAgent.title) on \(serverName ?? "this server") can’t receive images.",
             "Send your message without the image, or start a session with an agent that accepts images.")
        } else {
            (UUID(), ComposerAttachment.remoteRefusal,
             "Files and folders stay on this Mac. Paste or drop an image to send one.")
        }
        NSSound.beep()
        refresh()
    }

    private func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        refresh()
        view.window?.makeFirstResponder(prompt)
    }

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
            // An image added before the agent said it takes none. Take it out and keep the
            // draft, so the user can send the rest as it is.
            let refused = attachments.filter { model.refusesRemotely($0.prompt) }
            guard refused.isEmpty else {
                attachments.removeAll { model.refusesRemotely($0.prompt) }
                return refuse(refused)
            }
            prompt.string = ""
            // Its recorded edits point into the draft that just left; undoing one against
            // the empty field corrupts the text system.
            composerUndo.removeAllActions()
            let sent = attachments
            attachments = []
            attachmentNotice = nil
            if sessionTitle == "New Session" {
                let firstLine = draft.split(whereSeparator: \.isNewline).first.map(String.init) ?? draft
                let title = firstLine.trimmingCharacters(in: .whitespaces)
                sessionTitle = String((title.isEmpty ? sent.first?.name ?? title : title).prefix(60))
                onChange?()
            }
            operation = nil
            operationTask = nil
            await model.send(draft, attachments: sent.map(\.prompt))
        }
    }

    @objc private func sendPrompt() {
        guard hasSomethingToSend else { return }
        beginOperation(draft: prompt.string)
    }

    @objc private func cancelPrompt() {
        if operation != nil || model.phase == .connecting {
            disconnect()
        } else {
            Task { await model.cancel() }
        }
    }

    /// Why a session is being taken down.
    enum Teardown {
        /// Closed, or its harness switched: its agent stops, wherever it runs.
        case close
        /// Latch is quitting. An agent on this Mac stops with it; one on a server keeps
        /// running, and the next launch attaches to it again.
        case quit
    }

    func shutdown(for teardown: Teardown = .close) async {
        shuttingDown = true
        let drain = drainConnection(detaching: teardown == .quit && location.isRemote)
        operation = nil
        operationTask = nil
        refresh()
        await drain.value
        // A runtime left by the last run of Latch that this one never attached to.
        if teardown == .close { await model.discardRemoteBinding() }
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
    /// The agent sends its commands just before its session reply, on the event stream, so
    /// they may land either side of it; either way they must arrive. Keys go through the
    /// field, the way typing does.
    private func smokeTestCommandMenu() async throws {
        func key(_ code: UInt16, _ characters: String) {
            prompt.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: view.window!.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
        }
        func type(_ text: String) {
            prompt.insertText(text, replacementRange: prompt.selectedRange())
        }
        try await wait { !self.model.commands.isEmpty }
        guard model.commands.map(\.name) == ["review", "compact", "init"] else {
            throw SmokeError.failed("Commands sent with the session reply were lost")
        }
        prompt.string = ""
        refresh()
        type("/")
        guard !commandMenu.isHidden, commandMenu.matches.count == 3, commandMenu.selectedCommand?.name == "review" else {
            throw SmokeError.failed("A bare slash must list every command")
        }
        type("c")
        guard commandMenu.matches.first?.name == "compact", commandMenu.selectedCommand?.name == "compact" else {
            throw SmokeError.failed("The command menu did not filter by name")
        }
        prompt.string = ""
        type("/")
        key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        guard commandMenu.selectedCommand?.name == "compact" else { throw SmokeError.failed("Arrows did not move the command selection") }
        key(53, "\u{1b}")
        guard commandMenu.isHidden, prompt.string == "/" else { throw SmokeError.failed("Escape did not close the command menu") }
        // Setting the string above recorded nothing, so start undo from here, and group the
        // typing and the choice separately, as two key events would be.
        composerUndo.removeAllActions()
        composerUndo.groupsByEvent = false
        composerUndo.beginUndoGrouping()
        type("r")
        composerUndo.endUndoGrouping()
        guard !commandMenu.isHidden else { throw SmokeError.failed("Typing on did not reopen the command menu") }
        composerUndo.beginUndoGrouping()
        key(36, "\r")
        composerUndo.endUndoGrouping()
        guard prompt.string == "/review ", commandMenu.isHidden, prompt.inputHint == "what to focus on",
              model.phase == .ready, model.messages.isEmpty else {
            throw SmokeError.failed("Return must choose the command, not send the draft")
        }
        composerUndo.undo()
        // Before any further edit: with grouping off, an edit outside a group raises.
        composerUndo.groupsByEvent = true
        guard prompt.string == "/r" else { throw SmokeError.failed("Undo did not return to the typed query") }
        composerUndo.removeAllActions()
        prompt.string = "/review "
        type("a")
        guard prompt.inputHint == nil else { throw SmokeError.failed("The input hint stayed after typing began") }
        prompt.string = ""
        composerUndo.removeAllActions()
        refresh()
    }

    /// A pasted image joins the composer without touching the draft, can be sent on its own,
    /// keeps the composer inside the window at the smallest size, and can be taken out again.
    /// Uses a private pasteboard, never the user's clipboard.
    private func smokeTestAttachments() throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SmokeError.failed("Could not make a smoke image")
        }
        let board = NSPasteboard(name: NSPasteboard.Name("dev.latchapp.smoke.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(png, forType: .png)
        prompt.string = ""
        refresh()
        view.window?.contentView?.layoutSubtreeIfNeeded()
        let paperclip = attach.convert(attach.bounds, to: composerBox)
        let sendFrame = send.convert(send.bounds, to: composerBox)
        guard !attach.isHidden, attach.isEnabled, canAttachFiles, composerBox.bounds.contains(paperclip),
              paperclip.maxX <= sendFrame.minX, abs(paperclip.midY - sendFrame.midY) < 1 else {
            throw SmokeError.failed("The attach button must sit before Send, inside the composer, and be enabled")
        }
        guard attach(from: board), attachments.count == 1, prompt.string.isEmpty else {
            throw SmokeError.failed("A pasted image did not become an attachment")
        }
        guard !attachmentStrip.isHidden, send.isEnabled else {
            throw SmokeError.failed("An attachment must show in the composer and be sendable without text")
        }
        try smokeTestComposerBounds()
        board.clearContents()
        board.setString("Just text", forType: .string)
        guard !attach(from: board), attachments.count == 1 else {
            throw SmokeError.failed("Pasted text was taken as an attachment")
        }
        board.clearContents()
        board.setData(png, forType: .png)
        for _ in 1..<ComposerAttachment.maximumCount { _ = attach(from: board) }
        guard attachments.count == ComposerAttachment.maximumCount, !attach.isEnabled, !canAttachFiles else {
            throw SmokeError.failed("The attach button stayed enabled at the attachment limit")
        }
        for extra in attachments.dropFirst() { removeAttachment(extra.id) }
        removeAttachment(attachments[0].id)
        guard attachments.isEmpty, attachmentStrip.isHidden, !send.isEnabled, attach.isEnabled else {
            throw SmokeError.failed("Removing the attachment did not clear the composer")
        }
    }

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
        let initial = SessionViewController(location: location, launchEnvironment: launchEnvironment,
                                            settings: settings, servers: servers, remoteConnector: remoteConnector)
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
        try await smokeTestCommandMenu()
        try smokeTestAttachments()
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

    /// The remote smoke's conversation, through the real composer and sheet on a session whose
    /// agent runs on a server: a streamed reply, a permission approved in its sheet, and a turn
    /// that goes on through a dropped connection, runs once, and whose output from while the
    /// link was down is replayed once it is back.
    func smokeTestRemoteConversation(workspace: URL, dropConnection: () -> Void,
                                     reconnect: () async -> Void) async throws {
        try await wait { self.model.phase == .ready && self.operation == nil }
        guard model.errorMessage == nil, bannerRow.isHidden, model.linkState == .connected else {
            throw SmokeError.failed("The remote session did not connect cleanly: \(model.status)")
        }
        func submit(_ text: String) {
            prompt.string = text
            refresh()
            send.performClick(nil)
        }
        submit("Say hello")
        try await wait { self.model.phase == .ready && self.model.messages.last?.text == "one two three" }

        submit("Ask permission")
        try await wait { self.permissionAlert != nil }
        // The sheet's first button cancels the request; the agent's own options follow it.
        guard let alert = permissionAlert?.alert, alert.buttons.count == 3 else {
            throw SmokeError.failed("The permission sheet did not offer the agent's two options")
        }
        alert.buttons[1].performClick(nil)
        try await wait {
            self.model.phase == .ready && self.permissionAlert == nil && self.model.messages.last?.text == "asking allowed"
        }

        submit("Go slow")
        try await wait { self.model.phase == .prompting && self.model.messages.last?.text == "one " }
        dropConnection()
        try await wait { if case .reconnecting = self.model.linkState { true } else { false } }
        guard banner.displayedTitle == "Reconnecting to \(serverName ?? "")…", model.phase == .prompting else {
            throw SmokeError.failed("A dropped link did not read as reconnecting: \(banner.displayedTitle)")
        }
        // The agent finishes the turn on the server while the link is down.
        try await wait { FileManager.default.fileExists(atPath: workspace.appendingPathComponent("slow.log").path) }
        guard model.phase == .prompting, model.messages.last?.text == "one ", case .reconnecting = model.linkState else {
            throw SmokeError.failed("The turn went on without the link: \(model.messages.map(\.text))")
        }
        await reconnect()
        try await wait {
            self.model.phase == .ready && self.model.linkState == .connected
                && self.model.messages.last?.text == "one two three"
        }
        let prompts = (try? String(contentsOf: workspace.appendingPathComponent("prompts.log"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        guard model.status == "Ready · end_turn", model.errorMessage == nil, bannerRow.isHidden, prompts == 3,
              model.messages.map(\.text) == ["Say hello", "one two three", "Ask permission", "asking allowed",
                                              "Go slow", "one two three"] else {
            throw SmokeError.failed("The turn did not survive the dropped link exactly once "
                + "(\(model.status), \(prompts) prompts, \(model.messages.map(\.text)))")
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
        guard composerControls.pickerCount == 3 + extraPickers.count else {
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
            // The composer floats over the transcript by design; the transcript keeps its end clear of it.
            let composer = composerBox.convert(composerBox.bounds, to: view)
            let transcriptFrame = conversation.convert(conversation.bounds, to: view)
            guard transcriptFrame.insetBy(dx: -1, dy: -1).contains(composer),
                  conversation.bottomOverlay >= composer.maxY - transcriptFrame.minY else {
                throw SmokeError.failed("The composer does not float within the transcript at \(size)")
            }
            let controls: [NSView] = [banner, conversation, composerBox]
            let visible = controls.filter { !$0.isHiddenOrHasHiddenAncestor }
            for (index, control) in visible.enumerated() {
                let frame = control.convert(control.alignmentRect(forFrame: control.bounds), to: view)
                guard frame.width > 0, frame.height > 0,
                      view.bounds.insetBy(dx: -1, dy: -1).contains(frame) else {
                    throw SmokeError.failed("Session content clipped at \(size): \(frame)")
                }
                for other in visible.dropFirst(index + 1) where !(control === conversation && other === composerBox) {
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
                  box.minX >= transcript.minX + ChatTranscriptView.horizontalInset - 1,
                  box.maxX <= transcript.maxX - ChatTranscriptView.horizontalInset + 1,
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
        let session = SessionViewController(location: location, launchEnvironment: launchEnvironment,
                                            settings: settings, servers: servers, remoteConnector: remoteConnector)
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

/// The single down chevron a pull-down shows, for a pop-up that has had its own arrows turned off.
/// It never takes a click: the button underneath is the control.
@MainActor
private final class PickerChevron: NSImageView {
    init(in button: NSPopUpButton) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        button.addSubview(self)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: button.trailingAnchor),
            centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

