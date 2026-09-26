import AppKit
import LatchACP

/// The agent's slash commands, listed over the composer while a draft is a bare `/query`.
/// The composer keeps the keyboard: it forwards the arrows, Return, Tab and Escape here,
/// so typing carries on filtering the list.
@MainActor
final class SlashCommandMenu: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 32
    static let maximumVisibleRows = 8
    /// Concentric with the rows' selection, which sits 6 points in: 10 + 6.
    static let cornerRadius: CGFloat = 16
    private static let padding: CGFloat = 6

    var onAccept: ((ACPAvailableCommand) -> Void)?
    private(set) var matches: [ACPAvailableCommand] = []
    private var shownQuery: String?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    var selectedCommand: ACPAvailableCommand? {
        matches.indices.contains(table.selectedRow) ? matches[table.selectedRow] : nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            surface = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .menu
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = Self.cornerRadius
            material.layer?.masksToBounds = true
            surface = material
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        // The composer keeps focus; a click here only chooses.
        table.refusesFirstResponder = true
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Commands")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: Self.padding, left: 0, bottom: Self.padding, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: -6)
        layer?.shadowRadius = 16
        updateShadow()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// Name prefixes first, then names containing the query, then descriptions; each group
    /// keeps the agent's order. An empty query lists everything.
    nonisolated static func filter(_ commands: [ACPAvailableCommand], query: String) -> [ACPAvailableCommand] {
        guard !query.isEmpty else { return commands }
        var prefix: [ACPAvailableCommand] = [], inName: [ACPAvailableCommand] = [], inDescription: [ACPAvailableCommand] = []
        for command in commands {
            if command.name.range(of: query, options: [.caseInsensitive, .anchored]) != nil { prefix.append(command) }
            else if command.name.range(of: query, options: .caseInsensitive) != nil { inName.append(command) }
            else if command.description.range(of: query, options: .caseInsensitive) != nil { inDescription.append(command) }
        }
        return prefix + inName + inDescription
    }

    /// Returns whether anything matched; with no match the menu has nothing to show.
    @discardableResult
    func show(_ commands: [ACPAvailableCommand], query: String) -> Bool {
        // A new query highlights its best match; the agent refreshing its list under the
        // same query keeps whatever the arrows had reached.
        let kept = query == shownQuery ? selectedCommand : nil
        shownQuery = query
        let next = Self.filter(commands, query: query)
        if next != matches {
            matches = next
            table.reloadData()
        }
        let rows = min(matches.count, Self.maximumVisibleRows)
        height.constant = CGFloat(rows) * Self.rowHeight + Self.padding * 2
        select(matches.isEmpty ? nil : kept.flatMap { matches.firstIndex(of: $0) } ?? 0)
        return !matches.isEmpty
    }

    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        select(min(max(table.selectedRow + delta, 0), matches.count - 1))
    }

    private func select(_ row: Int?) {
        guard let row else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard matches.indices.contains(table.clickedRow) else { return }
        onAccept?(matches[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CommandRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("command")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CommandCellView ?? CommandCellView(identifier: identifier)
        cell.configure(matches[row])
        return cell
    }

    /// The composer keeps VoiceOver's focus, so the highlighted command is announced instead.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let command = selectedCommand, let window else { return }
        let spoken = command.description.isEmpty ? "/\(command.name)" : "/\(command.name), \(command.description)"
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func updateShadow() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowOpacity = dark ? 0.45 : 0.12
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadow()
    }
}

/// A rounded, always-emphasized highlight inset from the menu's edges, as a menu's own is:
/// the table never holds focus, but its selection is the one the keyboard is driving.
private final class CommandRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 1)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
    }
}

/// `/name` then its description, on one line; the description gives way first.
private final class CommandCellView: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [name, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func configure(_ command: ACPAvailableCommand) {
        name.stringValue = "/" + command.name
        detail.stringValue = command.description
        detail.isHidden = command.description.isEmpty
        setAccessibilityLabel(command.description.isEmpty ? "/\(command.name)" : "/\(command.name), \(command.description)")
    }
}
