import AppKit

/// One row of the menu bar extra.
struct MenuBarSession: Equatable {
    let id: UUID
    let title: String
    let status: String
    let phase: SessionModel.Phase
    let needsPermission: Bool
}

/// A menu bar extra listing every session, so agents that keep running while Latch is
/// behind another app stay reachable without raising the window first.
///
/// It can be hidden from its own menu, because Latch has no settings window yet; View →
/// Show in Menu Bar brings it back. The choice is remembered.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let visibilityDefaultsKey = "LatchShowsMenuBarItem"

    var sessions: () -> [MenuBarSession] = { [] }
    var onSelect: ((UUID) -> Void)?
    var onNewSession: (() -> Void)?

    private let defaults: UserDefaults
    private let installsStatusItem: Bool
    private var item: NSStatusItem?

    init(defaults: UserDefaults = .standard, installsStatusItem: Bool = true) {
        self.defaults = defaults
        self.installsStatusItem = installsStatusItem
        if defaults.object(forKey: Self.visibilityDefaultsKey) == nil {
            defaults.set(true, forKey: Self.visibilityDefaultsKey)
        }
        super.init()
    }

    var isVisible: Bool {
        get { defaults.bool(forKey: Self.visibilityDefaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.visibilityDefaultsKey)
            apply()
        }
    }

    func apply() {
        guard installsStatusItem else { return }
        guard isVisible else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            created.button?.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                                            accessibilityDescription: "Latch sessions")
            created.button?.imagePosition = .imageLeading
            created.menu = NSMenu()
            created.menu?.delegate = self
            item = created
        }
        refresh()
    }

    /// The count of sessions waiting on a decision rides next to the icon; the menu bar is
    /// monochrome by design, so a tint would not survive appearance changes.
    func refresh() {
        guard let button = item?.button else { return }
        let waiting = sessions().filter(\.needsPermission).count
        button.title = waiting > 0 ? " \(waiting)" : ""
        button.setAccessibilityLabel(waiting > 0 ? "Latch, \(waiting) waiting for a decision" : "Latch sessions")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    /// Built separately so a test can read the menu without a status bar.
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        populate(menu)
        return menu
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = sessions()
        let header = NSMenuItem(title: headline(rows), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for row in rows {
            let item = NSMenuItem(title: row.title, action: #selector(selectSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.subtitle = row.needsPermission ? "Waiting for a decision" : row.status
            item.image = Self.indicator(for: row)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New Session…", action: #selector(newSession), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hide), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(NSMenuItem(title: "Quit Latch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func headline(_ rows: [MenuBarSession]) -> String {
        let waiting = rows.filter(\.needsPermission).count
        if waiting > 0 { return "\(waiting) waiting for a decision" }
        let running = rows.filter { $0.phase == .prompting }.count
        if running > 0 { return "\(running) running" }
        return rows.isEmpty ? "No sessions" : "\(rows.count) session\(rows.count == 1 ? "" : "s")"
    }

    private static func indicator(for row: MenuBarSession) -> NSImage? {
        if row.needsPermission {
            return NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Waiting for a decision")
        }
        let symbol = switch row.phase {
        case .disconnected: "circle"
        case .connecting, .stopping: "circle.dotted"
        case .ready: "circle.fill"
        case .prompting: "circle.hexagonpath.fill"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: row.status)
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        NSApplication.shared.activate()
        onSelect?(id)
    }

    @objc private func newSession() {
        NSApplication.shared.activate()
        onNewSession?()
    }

    @objc private func hide() { isVisible = false }
}
