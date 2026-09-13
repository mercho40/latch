import AppKit

/// Source list of saved and newly opened sessions, grouped by workspace.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Workspace {
        let url: URL
        var sessions: [SessionViewController] = []
        init(url: URL) { self.url = url }
    }

    private(set) var workspaces: [Workspace] = []
    var onSelect: ((SessionViewController?) -> Void)?

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

    func add(_ session: SessionViewController, selecting: Bool = true) {
        let workspace: Workspace
        if let existing = workspaces.first(where: { $0.url.standardizedFileURL == session.workspace.standardizedFileURL }) {
            workspace = existing
        } else {
            workspace = Workspace(url: session.workspace)
            workspaces.append(workspace)
        }
        workspace.sessions.append(session)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        if selecting { select(session) }
    }

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
        cell.configure(title: session.sessionTitle, phase: session.model.phase, status: session.displayStatus)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedSession)
    }
}

/// Title, a phase indicator, and the model's status line.
final class SessionCellView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let indicator = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
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

    func configure(title text: String, phase: SessionModel.Phase, status: String) {
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
