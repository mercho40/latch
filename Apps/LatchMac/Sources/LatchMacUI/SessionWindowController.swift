import AppKit

@MainActor
final class SessionWindowController: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate {
    private let model = SessionModel()
    private var permissionAlert: (id: UUID, alert: NSAlert, escapeMonitor: Any?)?
    private var workspace: URL?
    private let command = NSTextField(string: "")
    private let folder = NSButton(title: "Choose Folder…", target: nil, action: nil)
    private let path = NSTextField(labelWithString: "No workspace selected")
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Not connected")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let transcript = NSTextView()
    private let prompt = NSTextView()
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let transcriptScroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "Choose a workspace and connect an ACP agent.\nYour conversation will appear here.")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Latch"
        window.subtitle = "Local session"
        window.minSize = NSSize(width: 660, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        folder.target = self
        folder.action = #selector(chooseFolder)
        folder.bezelStyle = .rounded
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let workspaceRow = row([folder, path])
        root.addArrangedSubview(workspaceRow)

        command.placeholderString = "/absolute/path/to/agent acp"
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.delegate = self
        command.setAccessibilityLabel("ACP agent command")
        command.toolTip = "Executable and arguments. Quotes are supported; shell expansion is not."
        command.setContentHuggingPriority(.defaultLow, for: .horizontal)
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connect.target = self
        connect.action = #selector(toggleConnection)
        connect.bezelStyle = .rounded
        let commandRow = row([command, connect])
        root.addArrangedSubview(commandRow)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        root.addArrangedSubview(status)
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 12)
        error.setAccessibilityLabel("Session error")
        root.addArrangedSubview(error)
        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.font = .systemFont(ofSize: 14)
        transcript.textContainerInset = NSSize(width: 12, height: 14)
        transcript.drawsBackground = false
        transcript.setAccessibilityLabel("Conversation transcript")
        configureTextView(transcript, in: transcriptScroll)
        transcriptScroll.drawsBackground = false
        let conversation = NSView()
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        conversation.addSubview(transcriptScroll)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 14)
        empty.translatesAutoresizingMaskIntoConstraints = false
        conversation.addSubview(empty)
        NSLayoutConstraint.activate([
            transcriptScroll.leadingAnchor.constraint(equalTo: conversation.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: conversation.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: conversation.topAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: conversation.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: conversation.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: conversation.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: conversation.widthAnchor, constant: -32),
            conversation.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        root.addArrangedSubview(conversation)

        let composerLabel = NSTextField(labelWithString: "Message")
        composerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        root.addArrangedSubview(composerLabel)
        let composer = NSScrollView()
        composer.borderType = .bezelBorder
        prompt.font = .systemFont(ofSize: 14)
        prompt.textContainerInset = NSSize(width: 8, height: 8)
        prompt.isRichText = false
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.delegate = self
        prompt.setAccessibilityLabel("Message to agent")
        configureTextView(prompt, in: composer)
        composer.heightAnchor.constraint(equalToConstant: 88).isActive = true
        root.addArrangedSubview(composer)

        send.target = self
        send.action = #selector(sendPrompt)
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        cancel.target = self
        cancel.action = #selector(cancelPrompt)
        cancel.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "⌘ Return to send")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = row([hint, spacer, cancel, send])
        root.addArrangedSubview(actions)
        let footer = NSTextField(wrappingLabelWithString: "Local preview · Quit requests agent shutdown. Permissions require your decision; agent-side restrictions still apply.")
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
        refreshPermission()
        let disconnected = model.phase == .disconnected
        folder.isEnabled = disconnected
        command.isEnabled = disconnected
        connect.title = disconnected ? "Connect" : "Disconnect"
        connect.isEnabled = disconnected ? workspace != nil && !command.stringValue.isEmpty : model.phase != .stopping
        status.stringValue = model.status
        error.stringValue = model.errorMessage ?? ""
        error.isHidden = model.errorMessage == nil
        prompt.isEditable = model.phase == .ready || model.phase == .prompting
        send.isEnabled = model.phase == .ready && !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancel.isEnabled = model.phase == .prompting && !model.cancellationRequested
        empty.isHidden = !model.transcript.isEmpty
        if transcript.string != model.transcript {
            let atBottom = transcriptScroll.documentVisibleRect.maxY >= transcript.bounds.maxY - 30
            let selection = transcript.selectedRange()
            transcript.string = model.transcript
            let length = (transcript.string as NSString).length
            if atBottom { transcript.scrollRangeToVisible(NSRange(location: length, length: 0)) }
            else if NSMaxRange(selection) <= length { transcript.setSelectedRange(selection) }
        }
    }

    private func refreshPermission() {
        guard let window else { return }
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

    func textDidChange(_ notification: Notification) { refresh() }
    func controlTextDidChange(_ obj: Notification) { refresh() }

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Workspace"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.workspace = url
            self?.path.stringValue = url.path
            self?.path.toolTip = url.path
            self?.refresh()
        }
    }

    @objc private func toggleConnection() {
        if model.phase == .disconnected {
            let input = command.stringValue
            let directory = workspace
            Task { await model.connect(command: input, workspace: directory) }
        } else { Task { await model.disconnect() } }
    }

    @objc private func sendPrompt() {
        guard model.phase == .ready else { return }
        let text = prompt.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prompt.string = ""
        Task { await model.send(text) }
    }

    @objc private func cancelPrompt() { Task { await model.cancel() } }
    func shutdown() async { await model.disconnect() }

    /// Exercises actual AppKit controls without a model provider, file picker, or UI scripting permissions.
    func smokeTest() async throws {
        workspace = URL(fileURLWithPath: "/tmp", isDirectory: true)
        path.stringValue = "/tmp"
        command.stringValue = "/bin/sh -c '" + SmokeAgent.script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        refresh()
        window?.contentView?.layoutSubtreeIfNeeded()
        guard transcriptScroll.frame.height >= 140, !send.isEnabled, !cancel.isEnabled else {
            throw SmokeError.failed("Invalid initial layout or controls")
        }
        connect.performClick(nil)
        try await wait { self.model.phase == .ready }
        prompt.string = "Keep working"
        refresh()
        guard send.isEnabled else { throw SmokeError.failed("Send stayed disabled") }
        send.performClick(nil)
        try await wait { self.model.transcript.contains("working") && self.cancel.isEnabled }
        cancel.performClick(nil)
        try await wait { self.model.phase == .ready && self.model.status == "Cancelled" }
        connect.performClick(nil)
        try await wait { self.model.phase == .disconnected }
        guard model.errorMessage == nil else { throw SmokeError.failed(model.errorMessage!) }

        // Exercise safe default dismissal and explicit selection using the actual sheet buttons.
        for (buttonIndex, result) in [(-1, "permission cancelled"), (-2, "permission cancelled"), (0, "permission cancelled"), (1, "permission selected")] {
            command.stringValue = "/bin/sh -c '" + SmokeAgent.permissionScript.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            if ContinuousClock.now >= deadline { throw SmokeError.failed("Timed out: \(model.status) \(model.errorMessage ?? "")") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum SmokeError: Error { case failed(String) }
