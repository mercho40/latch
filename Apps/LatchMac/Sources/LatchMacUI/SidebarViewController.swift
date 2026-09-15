import AppKit

/// Source list of saved and newly opened sessions, grouped by workspace.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class Workspace {
        let url: URL
        var sessions: [SessionViewController] = []
        init(url: URL) { self.url = url }
    }

    /// Where a session sat, so closing one can be undone back into the same place.
    struct Slot {
        let workspace: URL
        let workspaceIndex: Int
        let sessionIndex: Int
    }

    private(set) var workspaces: [Workspace] = []
    var onSelect: ((SessionViewController?) -> Void)?
    var onCloseSession: ((SessionViewController) -> Void)?
    /// A folder dropped on the list opens a session in it.
    var onOpenWorkspace: ((URL) -> Void)?

    let outline = NSOutlineView()
    private let scroll = NSScrollView()

    var selectedSession: SessionViewController? {
        outline.item(atRow: outline.selectedRow) as? SessionViewController
    }

    override func loadView() {
        view = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        // Session cells contain two lines; the system source-list size is single-line.
        outline.rowSizeStyle = .custom
        outline.usesAutomaticRowHeights = false
        outline.allowsEmptySelection = true
        outline.setAccessibilityLabel("Sessions")
        outline.dataSource = self
        outline.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.registerForDraggedTypes([.fileURL])
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: Mutations

    /// A fork is placed next to the session it came from; anything else goes last.
    func add(_ session: SessionViewController, after sibling: SessionViewController? = nil, selecting: Bool = true) {
        let workspace: Workspace
        if let existing = workspaces.first(where: { $0.url.standardizedFileURL == session.workspace.standardizedFileURL }) {
            workspace = existing
        } else {
            workspace = Workspace(url: session.workspace)
            workspaces.append(workspace)
        }
        if let sibling, let index = workspace.sessions.firstIndex(where: { $0 === sibling }) {
            workspace.sessions.insert(session, at: index + 1)
        } else {
            workspace.sessions.append(session)
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        if selecting { select(session) }
    }

    /// Drops a session, selects a neighbour, and reports the slot it came out of.
    /// The workspace group goes with its last session.
    func remove(_ session: SessionViewController) -> Slot? {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.sessions.contains(where: { $0 === session }) }),
              let sessionIndex = workspaces[workspaceIndex].sessions.firstIndex(where: { $0 === session })
        else { return nil }
        let workspace = workspaces[workspaceIndex]
        let slot = Slot(workspace: workspace.url, workspaceIndex: workspaceIndex, sessionIndex: sessionIndex)
        let wasSelected = selectedSession === session
        workspace.sessions.remove(at: sessionIndex)
        if workspace.sessions.isEmpty { workspaces.remove(at: workspaceIndex) }
        let successor = wasSelected ? neighbour(of: slot) : selectedSession
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        // reloadData keeps the old row index selected, which is now a different session.
        select(successor)
        if successor == nil {
            outline.deselectAll(nil)
            onSelect?(nil)
        }
        return slot
    }

    /// Puts a closed session back where it was, recreating its workspace group if needed.
    func insert(_ session: SessionViewController, at slot: Slot) {
        let workspace: Workspace
        if let existing = workspaces.first(where: { $0.url.standardizedFileURL == slot.workspace.standardizedFileURL }) {
            workspace = existing
        } else {
            workspace = Workspace(url: slot.workspace)
            workspaces.insert(workspace, at: min(slot.workspaceIndex, workspaces.count))
        }
        workspace.sessions.insert(session, at: min(slot.sessionIndex, workspace.sessions.count))
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        select(session)
    }

    /// The next session in the same workspace, else the previous one, else anything left.
    private func neighbour(of slot: Slot) -> SessionViewController? {
        if let workspace = workspaces.first(where: { $0.url.standardizedFileURL == slot.workspace.standardizedFileURL }) {
            if slot.sessionIndex < workspace.sessions.count { return workspace.sessions[slot.sessionIndex] }
            return workspace.sessions.last
        }
        let remaining = allSessions
        guard !remaining.isEmpty else { return nil }
        let workspaceIndex = min(slot.workspaceIndex, workspaces.count - 1)
        return workspaces[workspaceIndex].sessions.first ?? remaining.first
    }

    /// NSOutlineView leaves ⌫ unhandled, so it arrives here through the responder chain.
    override func deleteBackward(_ sender: Any?) {
        guard let session = selectedSession else { return }
        onCloseSession?(session)
    }

    override func deleteForward(_ sender: Any?) { deleteBackward(sender) }

    func select(_ session: SessionViewController?) {
        guard let session else {
            outline.deselectAll(nil)
            return
        }
        let row = outline.row(forItem: session)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// Titles and status text changed; row structure did not.
    func refreshRows() {
        let rows = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    var allSessions: [SessionViewController] { workspaces.flatMap(\.sessions) }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: workspaces.count
        case let workspace as Workspace: workspace.sessions.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: workspaces[index]
        case let workspace as Workspace: workspace.sessions[index]
        default: fatalError("Unexpected outline item")
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is Workspace ? 28 : 44
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Workspace }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Workspace }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is SessionViewController }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let workspace = item as? Workspace {
            let identifier = NSUserInterfaceItemIdentifier("workspace")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingMiddle
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = workspace.url.lastPathComponent
            cell.toolTip = workspace.url.path
            return cell
        }
        guard let session = item as? SessionViewController else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("session")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SessionCellView ?? SessionCellView(identifier: identifier)
        cell.onRename = { [weak session] name in session?.rename(to: name) }
        cell.configure(title: session.sessionTitle, phase: session.model.phase, status: session.displayStatus)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedSession)
    }

    // MARK: Dropping a folder

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard !folders(in: info).isEmpty else { return [] }
        // A workspace is not inserted at a position; the drop targets the whole list.
        outlineView.setDropItem(nil, dropChildIndex: -1)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        let dropped = folders(in: info)
        guard !dropped.isEmpty else { return false }
        for folder in dropped { onOpenWorkspace?(folder) }
        return true
    }

    /// Only real directories; a dropped file has no workspace to run an agent in.
    private func folders(in info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else { return [] }
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    // MARK: Context menu

    /// Acts on the right-clicked row, which is not necessarily the selected one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let workspace = outline.item(atRow: outline.clickedRow) as? Workspace {
            add(to: menu, title: "Reveal in Finder", action: #selector(revealClicked), object: workspace.url)
            add(to: menu, title: "Open in Terminal", action: #selector(openClickedInTerminal), object: workspace.url)
            add(to: menu, title: "Copy Path", action: #selector(copyClickedPath), object: workspace.url)
            return
        }
        guard let session = outline.item(atRow: outline.clickedRow) as? SessionViewController else { return }
        add(to: menu, title: "Rename…", action: #selector(renameClickedSession), object: session)
        menu.addItem(.separator())
        add(to: menu, title: "Fork Session", action: #selector(forkClickedSession), object: session)
        menu.addItem(.separator())
        add(to: menu, title: "Reveal Workspace in Finder", action: #selector(revealClicked), object: session.workspace)
        add(to: menu, title: "Open Workspace in Terminal", action: #selector(openClickedInTerminal), object: session.workspace)
        add(to: menu, title: "Copy Workspace Path", action: #selector(copyClickedPath), object: session.workspace)
        menu.addItem(.separator())
        add(to: menu, title: "Close Session", action: #selector(closeClickedSession), object: session)
    }

    private func add(to menu: NSMenu, title: String, action: Selector, object: Any) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        menu.addItem(item)
    }

    @objc private func closeClickedSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionViewController else { return }
        onCloseSession?(session)
    }

    @objc private func forkClickedSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionViewController else { return }
        session.forkSession()
    }

    /// Inline editing in the row, as a source list renames anywhere else on the system.
    @objc private func renameClickedSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionViewController else { return }
        beginRename(session)
    }

    func beginRename(_ session: SessionViewController) {
        let row = outline.row(forItem: session)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionCellView else { return }
        cell.beginRename()
    }

    @objc private func revealClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openClickedInTerminal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func copyClickedPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

/// Title, a phase indicator, and the model's status line.
final class SessionCellView: NSTableCellView, NSTextFieldDelegate {
    var onRename: ((String) -> Void)?
    private var committedTitle = ""
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let indicator = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        // Editable only for the duration of a rename, so clicking a row never starts one.
        title.isEditable = false
        title.isBordered = false
        title.drawsBackground = false
        title.delegate = self
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        indicator.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        for view in [title, subtitle, indicator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            indicator.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 10),
            title.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func beginRename() {
        committedTitle = title.stringValue
        title.isEditable = true
        window?.makeFirstResponder(title)
        title.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        title.stringValue = committedTitle
        title.isEditable = false
        window?.makeFirstResponder(nil)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard title.isEditable else { return }
        title.isEditable = false
        let entered = title.stringValue
        title.stringValue = committedTitle
        onRename?(entered)
    }

    func configure(title text: String, phase: SessionModel.Phase, status: String) {
        guard !title.isEditable else { return }
        committedTitle = text
        title.stringValue = text
        subtitle.stringValue = status
        let (symbol, color): (String, NSColor) = switch phase {
        case .disconnected: ("circle", .tertiaryLabelColor)
        case .connecting, .stopping: ("circle.dotted", .secondaryLabelColor)
        case .ready: ("circle.fill", .systemGreen)
        case .prompting: ("circle.fill", .systemOrange)
        }
        indicator.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status)
        indicator.contentTintColor = color
        setAccessibilityLabel("\(text), \(status)")
    }
}
