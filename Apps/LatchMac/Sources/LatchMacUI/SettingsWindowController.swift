import AppKit

/// The ⌘, window. It hosts one pane today; the tab controller is what lets a second one
/// arrive later without moving the window, the menu item, or the shortcut.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(settings: AgentSettings = .shared) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The tab controller supplies the toolbar; this is what makes macOS lay it out as
        // a Settings window rather than a document one.
        window.toolbarStyle = .preference
        super.init(window: window)
        tabs.tabStyle = .toolbar
        let agents = AgentsSettingsViewController(settings: settings)
        agents.title = "Agents"
        let item = NSTabViewItem(viewController: agents)
        item.label = "Agents"
        item.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Agents")
        tabs.addTabViewItem(item)
        window.contentViewController = tabs
        window.center()
        window.setFrameAutosaveName("LatchSettingsWindow")
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
