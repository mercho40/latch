import AppKit

/// Sidebar of workspaces and sessions beside the selected session's detail view.
@MainActor
final class SessionWindowController: NSWindowController, NSToolbarDelegate {
    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let detail = DetailHostViewController()
    private var shuttingDown = false

    init() {
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

        let toolbar = NSToolbar(identifier: "LatchSessionToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        sidebar.onSelect = { [weak self] session in self?.show(session) }
        detail.onNewSession = { [weak self] in self?.newSession(nil) }
        show(nil)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    // MARK: Sessions

    @objc func newSession(_ sender: Any?) {
        guard let window, !shuttingDown else { return }
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

    @discardableResult
    func addSession(workspace: URL, launchEnvironment: AgentLaunchEnvironment? = nil) -> SessionViewController {
        let session = SessionViewController(workspace: workspace, launchEnvironment: launchEnvironment)
        session.onChange = { [weak self] in self?.sessionChanged() }
        sidebar.add(session)
        return session
    }

    private func show(_ session: SessionViewController?) {
        detail.show(session)
        updateTitle()
    }

    private func sessionChanged() {
        sidebar.refreshRows()
        updateTitle()
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
        for session in sidebar.allSessions { await session.shutdown() }
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
        // Exercise the composer pickers at the smallest supported window size.
        let originalSize = window?.contentView?.frame.size
        if let window { window.setContentSize(window.contentMinSize) }
        defer { if let originalSize { window?.setContentSize(originalSize) } }
        try await first.smokeTest(fixtureHome: fixtureHome)
        guard window?.title == "Keep working" else { throw SmokeError.failed("Window title did not follow the session title") }
        split.splitViewItems[0].animator().isCollapsed = true
        guard split.splitViewItems[0].isCollapsed else { throw SmokeError.failed("Sidebar did not collapse") }
        split.splitViewItems[0].isCollapsed = false
        window?.contentView?.layoutSubtreeIfNeeded()
        try checkSidebarRowLayout()
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
    private let placeholder = NSStackView()

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "No session selected")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: "Choose a workspace folder to get started.")
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
