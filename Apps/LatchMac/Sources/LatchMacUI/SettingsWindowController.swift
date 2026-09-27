import AppKit
import LatchSessionKit

/// The ⌘, window: Agents, then Servers, as toolbar tabs.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = SettingsTabViewController()
    private let serversPane: ServersSettingsViewController

    init(settings: AgentSettings = .shared, servers: (any ServerStore)? = nil, serverCheck: ServerCheck? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The tab controller supplies the toolbar; this is what makes macOS lay it out as
        // a Settings window rather than a document one.
        window.toolbarStyle = .preference
        serversPane = ServersSettingsViewController(store: servers ?? FileServerStore.shared,
                                                    check: serverCheck ?? ServerCheckText.live)
        super.init(window: window)
        tabs.tabStyle = .toolbar
        let agents = AgentsSettingsViewController(settings: settings)
        agents.title = "Agents"
        let item = NSTabViewItem(viewController: agents)
        item.label = "Agents"
        item.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Agents")
        tabs.addTabViewItem(item)
        let serversItem = NSTabViewItem(viewController: serversPane)
        serversItem.label = "Servers"
        serversItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Servers")
        tabs.addTabViewItem(serversItem)
        window.contentViewController = tabs
        // The tab controller titles the window when a tab is selected, but its first selection
        // happens before it has a window, which left the title bar blank.
        window.title = item.label
        // A settings window is as large as its pane, not a fixed sheet with a pane floating in it.
        window.setContentSize(tabs.view.fittingSize)
        window.center()
        window.setFrameAutosaveName("LatchSettingsWindow")
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// Brings a pane forward by its label, as clicking its toolbar item does.
    func select(pane label: String) {
        guard let index = tabs.tabViewItems.firstIndex(where: { $0.label == label }) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    /// The Servers pane, with `id` selected, so what the user does next is about that server.
    func select(server id: UUID) {
        select(pane: "Servers")
        serversPane.select(serverID: id)
    }

    var selectedPane: String? {
        tabs.tabViewItems.indices.contains(tabs.selectedTabViewItemIndex)
            ? tabs.tabViewItems[tabs.selectedTabViewItemIndex].label : nil
    }

    /// The window's title, for tests.
    var title: String? { window?.title }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Names a server to `showServerSettings(_:)` as the action's sender.
final class ServerReference: NSObject {
    let serverID: UUID

    init(_ serverID: UUID) {
        self.serverID = serverID
    }
}

/// Titles the window after the pane on show and fits the window to it, as System Settings
/// panes do: a short pane after a tall one does not keep the tall one's empty space.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let window = view.window, let tabViewItem, let pane = tabViewItem.viewController?.view else { return }
        window.title = tabViewItem.label
        let size = pane.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // Grow and shrink from the top edge, which is where the toolbar the user clicked stays.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
