import AppKit

/// Sidebar of workspaces and sessions beside the selected session's detail view.
@MainActor
final class SessionWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let detail = DetailHostViewController()
    private var shuttingDown = false
    private let store: SessionStore?
    private var persistenceReady = false
    private var restoreAttempted = false
    private var restoreFinished = false
    private var debounceSave: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Closed sessions still draining their agent, awaited before the app quits.
    private var closing: [UUID: Task<Void, Never>] = [:]
    /// Session closes are undoable; text editing keeps its own manager in the composer.
    private let sessionUndo = UndoManager()
    private let attention: AttentionCenter?
    private let menuBar: MenuBarController?
    private(set) var persistenceError: String?

    var savedLibrary: SavedSessionLibrary {
        SavedSessionLibrary(sessions: sidebar.allSessions.map(\.savedSession),
                            selectedSessionID: sidebar.selectedSession?.id)
    }

    /// Tests and UI smoke runs opt out unless given their own temporary store.
    /// They also run without an attention center or menu bar extra, so no test posts a
    /// notification, claims the Dock badge, or adds a status item.
    init(store: SessionStore? = nil, attention: AttentionCenter? = nil, menuBar: MenuBarController? = nil) {
        self.store = store
        self.attention = attention
        self.menuBar = menuBar
        persistenceReady = store == nil
        restoreFinished = store == nil
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.title = "Latch"
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(contentListWithViewController: detail)
        detailItem.minimumThickness = 560
        split.addSplitViewItem(detailItem)
        split.splitView.autosaveName = "LatchSessionSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.delegate = self

        let toolbar = NSToolbar(identifier: "LatchSessionToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        sidebar.onSelect = { [weak self] session in self?.show(session) }
        sidebar.onCloseSession = { [weak self] session in self?.close(session) }
        sidebar.onOpenWorkspace = { [weak self] url in self?.openWorkspace(url) }
        detail.onNewSession = { [weak self] in self?.newSession(nil) }
        detail.onOpenWorkspace = { [weak self] url in self?.openWorkspace(url) }
        attention?.isSessionVisible = { [weak self] id in
            guard let self, NSApp.isActive, self.window?.isVisible == true else { return false }
            return self.sidebar.selectedSession?.id == id
        }
        attention?.onReveal = { [weak self] id in self?.reveal(id) }
        attention?.onResolvePermission = { [weak self] id, request, option in
            guard let session = self?.sidebar.allSessions.first(where: { $0.id == id }) else { return }
            session.resolvePermission(request: request, optionID: option)
            self?.publishAttention()
        }
        menuBar?.sessions = { [weak self] in self?.sidebar.allSessions.map(\.menuBarRow) ?? [] }
        menuBar?.onSelect = { [weak self] id in self?.reveal(id) }
        menuBar?.onNewSession = { [weak self] in self?.newSession(nil) }
        menuBar?.apply()
        show(nil)
        // Centre only the first launch; afterwards the window reopens where it was left.
        if !window.setFrameUsingName(Self.frameAutosaveName) { window.center() }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    private static let frameAutosaveName = NSWindow.FrameAutosaveName("LatchSessionWindow")

    /// Reached through the responder chain whenever the first responder has no manager of
    /// its own, so ⌘Z undoes a closed session but never someone's half-typed prompt.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { sessionUndo }

    required init?(coder: NSCoder) { fatalError("Not used") }

    // MARK: Sessions

    @objc func newSession(_ sender: Any?) {
        guard let window, !shuttingDown, restoreFinished else { return }
        // The menu bar extra can start a session with the window closed; a sheet needs it.
        window.makeKeyAndOrderFront(nil)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Session"
        panel.message = "Choose the workspace folder for the new session."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.addSession(workspace: url)
        }
    }

    /// Every route to a new session — ⌘N, a dropped folder, Open Recent, or the Dock —
    /// arrives here, so all of them are remembered as recent workspaces.
    func openWorkspace(_ url: URL) {
        guard !shuttingDown, restoreFinished else { return }
        window?.makeKeyAndOrderFront(nil)
        addSession(workspace: url)
    }

    @discardableResult
    func addSession(workspace: URL, launchEnvironment: AgentLaunchEnvironment? = nil) -> SessionViewController {
        let session = SessionViewController(workspace: workspace, launchEnvironment: launchEnvironment)
        adopt(session)
        sidebar.add(session)
        NSDocumentController.shared.noteNewRecentDocumentURL(workspace)
        scheduleSave()
        return session
    }

    /// Bring a session on screen because something outside the window asked for it.
    func reveal(_ id: UUID) {
        guard let session = sidebar.allSessions.first(where: { $0.id == id }) else { return }
        window?.makeKeyAndOrderFront(nil)
        sidebar.select(session)
    }

    private func adopt(_ session: SessionViewController) {
        session.onChange = { [weak self] in self?.sessionChanged() }
        session.onTranscriptChange = { [weak self] in self?.scheduleSave() }
        session.onForkSession = { [weak self, weak session] agent, command in
            guard let self, let session else { return }
            self.forkSession(from: session, agent: agent, command: command)
        }
    }

    /// A session that already holds a transcript owns its harness. Selecting another one
    /// opens a sibling session beside it in the same workspace, so the original keeps its
    /// history and agent context and no folder has to be chosen again.
    private func forkSession(from session: SessionViewController, agent: AgentPreset, command: String) {
        guard !shuttingDown, restoreFinished else { return }
        let fork = SessionViewController(workspace: session.workspace,
                                         launchEnvironment: session.injectedEnvironment,
                                         initialAgent: agent, initialCommand: command)
        adopt(fork)
        sidebar.add(fork, after: session)
        scheduleSave()
    }

    @objc func closeSession(_ sender: Any?) {
        guard let session = sidebar.selectedSession else { return }
        close(session)
    }

    /// Takes the session out of the sidebar, stops its agent, and leaves an undo behind.
    /// The transcript, draft, and agent context survive in the snapshot, so undo restores
    /// the session rather than an empty row.
    private func close(_ session: SessionViewController) {
        guard !shuttingDown, restoreFinished else { return }
        let snapshot = session.savedSession
        let environment = session.injectedEnvironment
        guard let slot = sidebar.remove(session) else { return }
        let token = UUID()
        closing[token] = Task { [weak self] in
            await session.shutdown()
            self?.closing[token] = nil
        }
        sessionUndo.setActionName("Close Session")
        sessionUndo.registerUndo(withTarget: self) { controller in
            controller.reopen(snapshot, launchEnvironment: environment, at: slot)
        }
        show(sidebar.selectedSession)
    }

    /// Undo of a close. The agent process is gone, so this rebuilds the session from its
    /// saved snapshot exactly as a restore at launch would, and resumes context on select.
    private func reopen(_ snapshot: SavedSession, launchEnvironment: AgentLaunchEnvironment?, at slot: SidebarViewController.Slot) {
        guard !shuttingDown else { return }
        let session = SessionViewController(workspace: URL(fileURLWithPath: snapshot.workspacePath),
                                            launchEnvironment: launchEnvironment, savedSession: snapshot)
        adopt(session)
        sidebar.insert(session, at: slot)
        sessionUndo.setActionName("Close Session")
        sessionUndo.registerUndo(withTarget: self) { controller in
            controller.close(session)
        }
        show(session)
    }

    @objc func stopSession(_ sender: Any?) { sidebar.selectedSession?.stopActivity() }

    @objc func disconnectSession(_ sender: Any?) { sidebar.selectedSession?.disconnectSession() }

    @objc func forkSelectedSession(_ sender: Any?) { sidebar.selectedSession?.forkSession() }

    @objc func renameSession(_ sender: Any?) {
        guard let session = sidebar.selectedSession else { return }
        sidebar.beginRename(session)
    }

    @objc func nextSession(_ sender: Any?) { step(by: 1) }

    @objc func previousSession(_ sender: Any?) { step(by: -1) }

    private func step(by offset: Int) {
        let sessions = sidebar.allSessions
        guard !sessions.isEmpty else { return }
        let current = sidebar.selectedSession.flatMap { session in sessions.firstIndex { $0 === session } } ?? 0
        let next = (current + offset + sessions.count) % sessions.count
        sidebar.select(sessions[next])
    }

    @objc func revealWorkspace(_ sender: Any?) {
        guard let session = sidebar.selectedSession else { return }
        NSWorkspace.shared.activateFileViewerSelecting([session.workspace])
    }

    @objc func openWorkspaceInTerminal(_ sender: Any?) {
        guard let session = sidebar.selectedSession,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return }
        NSWorkspace.shared.open([session.workspace], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Find

    @objc func performFindPanelAction(_ sender: Any?) {
        guard let transcript = sidebar.selectedSession?.conversation else { return }
        transcript.beginFind()
    }

    @objc func findNextMatch(_ sender: Any?) { sidebar.selectedSession?.conversation.findNext() }

    @objc func findPreviousMatch(_ sender: Any?) { sidebar.selectedSession?.conversation.findPrevious() }

    @objc func toggleMenuBarItem(_ sender: Any?) {
        guard let menuBar else { return }
        menuBar.isVisible.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let session = sidebar.selectedSession
        switch menuItem.action {
        case #selector(closeSession(_:)), #selector(renameSession(_:)):
            return session != nil && restoreFinished && !shuttingDown
        case #selector(copyConversation(_:)):
            return !(session?.model.transcript.isEmpty ?? true)
        case #selector(newSession(_:)):
            return restoreFinished && !shuttingDown
        case #selector(stopSession(_:)):
            return session?.canStop ?? false
        case #selector(disconnectSession(_:)):
            return session?.canDisconnect ?? false
        case #selector(forkSelectedSession(_:)):
            return (session?.canFork ?? false) && restoreFinished && !shuttingDown
        case #selector(nextSession(_:)), #selector(previousSession(_:)):
            return sidebar.allSessions.count > 1
        case #selector(revealWorkspace(_:)):
            return session != nil
        case #selector(openWorkspaceInTerminal(_:)):
            return session != nil && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil
        case #selector(performFindPanelAction(_:)):
            return session != nil
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return session?.conversation.canStepMatches ?? false
        case #selector(toggleMenuBarItem(_:)):
            menuItem.state = menuBar?.isVisible == true ? .on : .off
            return menuBar != nil
        default:
            return true
        }
    }

    private func show(_ session: SessionViewController?) {
        detail.show(session)
        updateTitle()
        publishAttention()
        scheduleSave()
    }

    private func sessionChanged() {
        sidebar.refreshRows()
        updateTitle()
        publishAttention()
        scheduleSave()
    }

    /// The Dock badge, notifications, and the menu bar extra all read the same snapshot.
    private func publishAttention() {
        guard attention != nil || menuBar != nil else { return }
        var states: [UUID: AttentionCenter.State] = [:]
        for session in sidebar.allSessions { states[session.id] = session.attention }
        attention?.update(states)
        menuBar?.refresh()
    }

    func restoreSessions(launchEnvironment: AgentLaunchEnvironment? = nil) async {
        guard let store, !restoreAttempted, !shuttingDown else { return }
        restoreAttempted = true
        defer { restoreFinished = true }
        do {
            let library = try await store.load()
            guard !shuttingDown else { return }
            for saved in library.sessions {
                let session = SessionViewController(workspace: URL(fileURLWithPath: saved.workspacePath),
                                                    launchEnvironment: launchEnvironment, savedSession: saved)
                adopt(session)
                // Building the sidebar must not start every saved command.
                sidebar.add(session, selecting: false)
            }
            sidebar.select(sidebar.allSessions.first { $0.id == library.selectedSessionID })
            persistenceReady = true
        } catch {
            // Leave the original file intact; this run cannot overwrite unreadable data.
            reportPersistenceError(error)
        }
    }

    private func scheduleSave() {
        guard store != nil, persistenceReady, !shuttingDown else { return }
        // Throttle rather than restart a debounce on every chunk: a long response must
        // still reach disk periodically. The snapshot is taken after the delay.
        guard debounceSave == nil else { return }
        debounceSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self else { return }
            self.debounceSave = nil
            await self.flushPersistence()
        }
    }

    func flushPersistence() async {
        debounceSave?.cancel()
        debounceSave = nil
        guard let store, persistenceReady else { return }
        let snapshot = savedLibrary
        let previous = saveTask
        let task = Task { [weak self] in
            // A quit-time snapshot must never be overwritten by an older in-flight save.
            await previous?.value
            do {
                try await store.save(snapshot)
                self?.persistenceError = nil
            } catch {
                self?.reportPersistenceError(error)
            }
        }
        saveTask = task
        await task.value
    }

    private func reportPersistenceError(_ error: any Error) {
        let message = "\(error.localizedDescription) Existing saved data has not been discarded. Changes may not survive quitting Latch."
        guard persistenceError != message else { return }
        persistenceError = message
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sessions could not be saved or restored"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func updateTitle() {
        guard let window else { return }
        if let session = sidebar.selectedSession {
            window.title = session.sessionTitle
            window.subtitle = session.workspace.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        } else {
            window.title = "Latch"
            window.subtitle = ""
        }
    }

    func shutdown() async {
        shuttingDown = true
        sessionUndo.removeAllActions()
        attention?.clear()
        await flushPersistence()
        for task in closing.values { await task.value }
        for session in sidebar.allSessions { await session.shutdown() }
        // Teardown may deliver a final chunk. IDs, drafts and history survive disconnect.
        await flushPersistence()
    }

    @objc func copyConversation(_ sender: Any?) {
        guard let text = sidebar.selectedSession?.model.transcript, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Toolbar

    private static let newSessionItem = NSToolbarItem.Identifier("newSession")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.newSessionItem, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.newSessionItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "New Session"
        item.paletteLabel = "New Session"
        item.toolTip = "Open a session in a workspace folder (⌘N)"
        item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Session")
        item.target = self
        item.action = #selector(newSession(_:))
        item.isBordered = true
        return item
    }

    // MARK: Smoke test

    /// Exercises the sidebar and the selected session with real AppKit controls.
    /// Transport of the first remaining session after the smoke run, for the bundle script to assert on.
    func smokeTransportDescription() -> String {
        sidebar.allSessions.first?.model.serviceTransportDescription ?? "no session"
    }

    func smokeTest() async throws {
        let fixtureHome = FileManager.default.temporaryDirectory.appendingPathComponent("Latch agents \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureHome) }
        window?.contentView?.layoutSubtreeIfNeeded()
        guard sidebar.outline.numberOfRows == 0, detail.children.isEmpty, window?.title == "Latch" else {
            throw SmokeError.failed("Expected an empty sidebar and detail before any session")
        }
        let environment = AgentLaunchEnvironment(environment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome.path],
                                                 home: fixtureHome, includeCommonLocations: false)
        let first = addSession(workspace: fixtureHome, launchEnvironment: environment)
        let second = addSession(workspace: fixtureHome, launchEnvironment: environment)
        await first.shutdownInitialSmokeConnection()
        await second.shutdownInitialSmokeConnection()
        window?.contentView?.layoutSubtreeIfNeeded()
        guard sidebar.workspaces.count == 1, sidebar.outline.numberOfRows == 3,
              sidebar.selectedSession === second, detail.children.first === second else {
            throw SmokeError.failed("Sidebar did not group two sessions under one workspace and select the newest")
        }
        guard sidebar.view.frame.width >= 200, first.view.window == nil, second.view.window != nil else {
            throw SmokeError.failed("Only the selected session should be in the window")
        }
        try checkSidebarRowLayout()
        sidebar.select(first)
        guard sidebar.selectedSession === first, detail.children.first === first, second.view.window == nil else {
            throw SmokeError.failed("Selecting a sidebar row did not swap the detail view")
        }
        // The composer's preferred width must never become the window's maximum width:
        // at .defaultHigh it outranked the window's own 500, walling the window at ~1200pt.
        if let window, let screen = window.screen ?? NSScreen.main {
            let target = min(1500, screen.visibleFrame.width)
            if target > 1300 {
                let restore = window.frame
                window.setContentSize(NSSize(width: target, height: 800))
                window.contentView?.layoutSubtreeIfNeeded()
                let reached = window.contentView?.frame.width ?? 0
                guard reached >= target - 1 else {
                    throw SmokeError.failed(
                        "Window stopped widening at \(reached)pt of \(target)pt; a content constraint caps the window"
                    )
                }
                window.setFrame(restore, display: false)
            }
        }

        // Exercise the composer pickers at the smallest supported window size.
        let originalSize = window?.contentView?.frame.size
        if let window { window.setContentSize(window.contentMinSize) }
        defer { if let originalSize { window?.setContentSize(originalSize) } }
        try await first.smokeTestConversation(fixtureHome: fixtureHome)
        guard window?.title == "Keep working" else { throw SmokeError.failed("Window title did not follow the session title") }

        // A started conversation owns its harness: selecting another one forks a sibling
        // beside it and leaves this transcript and agent context alone.
        let transcript = first.model.transcript
        let context = first.savedSession.agentSessionID
        let fallback = try smokeFork(from: first, to: .codex, expecting: 3)
        guard first.model.transcript == transcript, !transcript.isEmpty,
              first.savedSession.agentID == AgentPreset.fx.rawValue,
              first.savedSession.agentSessionID == context, context != nil else {
            throw SmokeError.failed("Switching harness discarded the original conversation")
        }
        try await fallback.smokeTestFallbackHarness(fixtureHome: fixtureHome)
        let lifecycle = try smokeFork(from: fallback, to: .custom, expecting: 4)
        try await lifecycle.smokeTestLaunchLifecycle(fixtureHome: fixtureHome)
        split.splitViewItems[0].animator().isCollapsed = true
        guard split.splitViewItems[0].isCollapsed else { throw SmokeError.failed("Sidebar did not collapse") }
        split.splitViewItems[0].isCollapsed = false
        window?.contentView?.layoutSubtreeIfNeeded()
        try checkSidebarRowLayout()
        try smokeTestFind(first)
        try smokeTestMenuBarListing()
        try smokeTestCloseAndUndo(second)
    }

    /// ⌘F over a real transcript: the bar takes its strip above the conversation, matches
    /// the text that is actually on screen, steps, and gives the space back.
    private func smokeTestFind(_ session: SessionViewController) throws {
        sidebar.select(session)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let word = session.model.messages.first(where: { $0.role == .user })?.text
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init), word.count >= 3 else {
            throw SmokeError.failed("Expected a user message in the transcript to search for")
        }
        let transcript = session.conversation
        let closedTop = transcript.scrollView.frame.minY
        performFindPanelAction(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard transcript.isFindBarVisible, transcript.scrollView.frame.minY >= closedTop + TranscriptFindBar.height else {
            throw SmokeError.failed("The find bar did not open above the transcript")
        }
        transcript.search(word)
        guard transcript.matchCount >= 1, transcript.currentMatch == 1 else {
            throw SmokeError.failed("Find did not match \(word) in the visible transcript")
        }
        findNextMatch(nil)
        guard transcript.currentMatch == (transcript.matchCount == 1 ? 1 : 2) else {
            throw SmokeError.failed("Find Next did not step through matches")
        }
        transcript.endFind()
        window?.contentView?.layoutSubtreeIfNeeded()
        guard !transcript.isFindBarVisible, transcript.scrollView.frame.minY == closedTop, transcript.matchCount == 0 else {
            throw SmokeError.failed("Closing the find bar did not give its strip back")
        }
    }

    /// Every session is listed in the menu bar extra, not only the one on screen.
    private func smokeTestMenuBarListing() throws {
        guard let menuBar else { return }
        let rows = menuBar.buildMenu().items.filter { $0.representedObject is UUID }
        guard rows.count == sidebar.allSessions.count,
              rows.map(\.title) == sidebar.allSessions.map(\.sessionTitle),
              attention?.badgeCount == 0 else {
            throw SmokeError.failed("The menu bar extra does not list every session")
        }
    }

    /// Closing takes the session out of the sidebar, the detail view, and the saved library;
    /// undo puts it back in the same slot with its title and transcript.
    private func smokeTestCloseAndUndo(_ session: SessionViewController) throws {
        let expected = session.savedSession
        let rows = sidebar.outline.numberOfRows
        sidebar.select(session)
        guard sidebar.selectedSession === session else {
            throw SmokeError.failed("Could not select the session to close")
        }
        closeSession(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard sidebar.outline.numberOfRows == rows - 1,
              !sidebar.allSessions.contains(where: { $0 === session }),
              let successor = sidebar.selectedSession, successor !== session,
              detail.children.first === successor,
              !savedLibrary.sessions.contains(where: { $0.id == expected.id }) else {
            throw SmokeError.failed("Closing a session did not remove its row, selection, and saved entry")
        }
        guard let undo = window?.undoManager, undo.canUndo else {
            throw SmokeError.failed("Closing a session left nothing to undo")
        }
        undo.undo()
        window?.contentView?.layoutSubtreeIfNeeded()
        guard sidebar.outline.numberOfRows == rows, let restored = sidebar.selectedSession,
              restored.id == expected.id, restored.sessionTitle == expected.title,
              restored.model.messages.map(\.id) == expected.messages.map(\.id),
              detail.children.first === restored, undo.canRedo else {
            throw SmokeError.failed("Undo did not restore the closed session in place")
        }
    }

    /// Selecting another harness on a started conversation must open a sibling session in the
    /// same workspace, place it next to its parent, select it, and start it empty.
    private func smokeFork(from session: SessionViewController, to agent: AgentPreset,
                           expecting count: Int) throws -> SessionViewController {
        session.smokeSelectAgent(agent)
        window?.contentView?.layoutSubtreeIfNeeded()
        let sessions = sidebar.allSessions
        guard sessions.count == count, let fork = sidebar.selectedSession, fork !== session,
              let parent = sessions.firstIndex(where: { $0 === session }),
              sessions.firstIndex(where: { $0 === fork }) == parent + 1,
              sidebar.workspaces.count == 1,
              fork.workspace.standardizedFileURL == session.workspace.standardizedFileURL,
              fork.savedSession.agentID == agent.rawValue, fork.model.messages.isEmpty,
              fork.savedSession.agentSessionID == nil,
              session.view.window == nil, fork.view.window != nil else {
            throw SmokeError.failed("Selecting another harness did not fork a sibling session")
        }
        return fork
    }

    private func checkSidebarRowLayout() throws {
        guard let scroll = sidebar.outline.enclosingScrollView,
              abs(scroll.frame.height - sidebar.view.bounds.height) < 1,
              sidebar.view.subviews.count == 1 else {
            throw SmokeError.failed("Sidebar list must fill the pane without an extra footer button")
        }
        for row in 0..<sidebar.outline.numberOfRows {
            guard let cell = sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else {
                throw SmokeError.failed("Missing sidebar cell at row \(row)")
            }
            cell.layoutSubtreeIfNeeded()
            let rowBounds = sidebar.outline.rect(ofRow: row)
            let labels = cell.subviews.compactMap { $0 as? NSTextField }
            for label in labels {
                let frame = label.convert(label.bounds, to: sidebar.outline)
                guard frame.height + 0.5 >= label.intrinsicContentSize.height,
                      frame.minY >= rowBounds.minY - 0.5, frame.maxY <= rowBounds.maxY + 0.5 else {
                    throw SmokeError.failed("Sidebar row \(row) clips text: height \(frame.height), needs \(label.intrinsicContentSize.height), row height \(rowBounds.height)")
                }
            }
        }
    }
}

/// Hosts the selected session, or an empty state prompting for the first one.
@MainActor
final class DetailHostViewController: NSViewController {
    var onNewSession: (() -> Void)?
    var onOpenWorkspace: ((URL) -> Void)? {
        didSet { (view as? WorkspaceDropView)?.onDrop = onOpenWorkspace }
    }
    private let placeholder = NSStackView()

    override func loadView() {
        let drop = WorkspaceDropView()
        drop.onDrop = onOpenWorkspace
        view = drop
        let title = NSTextField(labelWithString: "No session selected")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: "Choose a workspace folder to get started, or drag one here from the Finder.")
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 360
        let button = NSButton(title: "New Session…", target: self, action: #selector(createSession))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 8
        placeholder.addArrangedSubview(title)
        placeholder.addArrangedSubview(body)
        placeholder.setCustomSpacing(18, after: body)
        placeholder.addArrangedSubview(button)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -80),
        ])
    }

    @objc private func createSession() { onNewSession?() }

    func show(_ session: SessionViewController?) {
        for child in children where child !== session {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        placeholder.isHidden = session != nil
        guard let session, session.parent !== self else { return }
        addChild(session)
        session.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(session.view)
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            session.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            session.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// The detail pane accepts a folder dropped from the Finder, so the empty state is a real
/// target rather than a label pointing at the toolbar.
@MainActor
final class WorkspaceDropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var highlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        highlighted = !folders(in: sender).isEmpty
        needsDisplay = true
        return highlighted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        highlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        needsDisplay = true
        let dropped = folders(in: sender)
        guard !dropped.isEmpty else { return false }
        for folder in dropped { onDrop?(folder) }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
    }

    private func folders(in info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else { return [] }
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
