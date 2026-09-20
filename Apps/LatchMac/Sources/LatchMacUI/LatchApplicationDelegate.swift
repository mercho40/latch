import AppKit

@MainActor
public final class LatchApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: SessionWindowController?
    private var terminating = false
    private var shutdownComplete = false
    private var recentMenu: NSMenu?
    private(set) var menuBar: MenuBarController?
    /// Built on first use and kept alive: the pane holds the selected agent and the
    /// window's frame, and reopening ⌘, should land where it was left.
    private var settingsWindow: SettingsWindowController?

    /// Agent install state and the custom command live here, not in any session.
    @objc func showSettings(_ sender: Any?) {
        let controller = settingsWindow ?? SettingsWindowController()
        settingsWindow = controller
        controller.show()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let smokeTest = CommandLine.arguments.contains("--smoke-test")
        // A smoke run keeps the Dock badge but never posts a notification or claims a slot
        // in the real menu bar: neither belongs to an automated check of this machine.
        let attention = AttentionCenter(presenter: smokeTest ? nil : UserNotificationPresenter.make(),
                                        dockTile: NSApp.dockTile)
        let menuBar = MenuBarController(installsStatusItem: !smokeTest)
        self.menuBar = menuBar
        // A smoke run gets its own preferences for the same reason it gets its own store:
        // it must assert on Latch's behaviour, not on the agents this Mac's owner happens
        // to have turned off.
        let controller = SessionWindowController(
            store: smokeTest ? nil : SessionStore(directory: SessionStore.defaultDirectory),
            attention: attention, menuBar: menuBar,
            settings: smokeTest ? AgentSettings(defaults: UserDefaults(suiteName: "LatchSmoke-\(UUID().uuidString)")!) : nil
        )
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate()
        if !smokeTest { Task { await controller.restoreSessions() } }
        if smokeTest {
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                FileHandle.standardError.write(Data("UI SMOKE: timed out\n".utf8))
                exit(EXIT_FAILURE)
            }
            Task {
                do {
                    try await controller.smokeTest()
                    print("UI SMOKE: agent service transport = \(controller.smokeTransportDescription()) (app pid \(getpid()))")
                    print("UI SMOKE: chat layout, streaming, composer keyboard controls, sidebar, model/effort pickers, cancel, disconnect, permission sheets, session close and undo, find, menu bar listing — PASS")
                    NSApp.terminate(nil)
                } catch {
                    await controller.shutdown()
                    FileHandle.standardError.write(Data("UI SMOKE: \(error)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
        }
    }

    /// Latch encodes nothing but its own window state, so the secure coder is free to
    /// use. Without this AppKit keeps the legacy unarchiver for restorable state.
    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Latch keeps agents running, so closing the window is not quitting; the menu bar
    /// extra and the Dock icon both still lead back to the sessions.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        menuBar?.isVisible != true
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller?.showWindow(nil) }
        return true
    }

    /// Folders dropped on the Dock icon, or opened from the Finder, become sessions.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            controller?.openWorkspace(url)
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownComplete { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            await controller?.shutdown()
            shutdownComplete = true
            // Avoid nesting AppKit's termination loop inside an active MainActor task.
            DispatchQueue.main.async { sender.terminate(nil) }
        }
        return .terminateCancel
    }

    /// Internal so a test can assert the shipped menu structure without launching the app.
    func installMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu(title: "Latch")
        application.addItem(withTitle: "About Latch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
            .target = self
        application.addItem(.separator())
        let servicesItem = application.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Latch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        application.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Latch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = application
        menu.addItem(applicationItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Session…", action: #selector(SessionWindowController.newSession(_:)), keyEquivalent: "n")
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = self
        recentItem.submenu = recent
        recentMenu = recent
        file.addItem(.separator())
        // ⌘⌫ rather than ⌘W: closing the session is not closing the window.
        file.addItem(withTitle: "Close Session", action: #selector(SessionWindowController.closeSession(_:)),
                     keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!))
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        // AppKit's own undo/redo actions: the responder chain routes them to the composer's
        // per-session undo manager while it edits, and to the window's otherwise.
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // The composer is plain text, but a paste carrying styles still arrives from other
        // apps, and macOS users look for this item rather than stripping it by hand.
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "Find")
        find.addItem(withTitle: "Find…", action: #selector(SessionWindowController.performFindPanelAction(_:)), keyEquivalent: "f")
        find.addItem(withTitle: "Find Next", action: #selector(SessionWindowController.findNextMatch(_:)), keyEquivalent: "g")
        find.addItem(withTitle: "Find Previous", action: #selector(SessionWindowController.findPreviousMatch(_:)), keyEquivalent: "g")
            .keyEquivalentModifierMask = [.command, .shift]
        findItem.submenu = find
        // Everything below already works in the composer through the responder chain; it
        // was only unreachable from the menu bar, which is where people look for it.
        let spellingItem = edit.addItem(withTitle: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spelling.addItem(withTitle: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        spelling.addItem(.separator())
        spelling.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spelling.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        spelling.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
        spellingItem.submenu = spelling
        // Latch starts these off so pasted code survives; the menu is how a user asks for
        // them back, and AppKit ticks each one from the composer's own state.
        let substitutionsItem = edit.addItem(withTitle: "Substitutions", action: nil, keyEquivalent: "")
        let substitutions = NSMenu(title: "Substitutions")
        substitutions.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        substitutions.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        substitutions.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        substitutionsItem.submenu = substitutions
        edit.addItem(.separator())
        edit.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
            .keyEquivalentModifierMask = [.command, .control]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy Conversation", action: #selector(SessionWindowController.copyConversation(_:)), keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(withTitle: "Show in Menu Bar", action: #selector(SessionWindowController.toggleMenuBarItem(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        // AppKit retitles this item itself once the window enters full screen.
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        let sessionItem = NSMenuItem()
        let session = NSMenu(title: "Session")
        session.addItem(withTitle: "Stop", action: #selector(SessionWindowController.stopSession(_:)), keyEquivalent: ".")
        session.addItem(withTitle: "Fork Session", action: #selector(SessionWindowController.forkSelectedSession(_:)), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .shift]
        session.addItem(withTitle: "Disconnect", action: #selector(SessionWindowController.disconnectSession(_:)), keyEquivalent: "")
        session.addItem(.separator())
        session.addItem(withTitle: "Rename…", action: #selector(SessionWindowController.renameSession(_:)), keyEquivalent: "")
        session.addItem(withTitle: "Reveal Workspace in Finder", action: #selector(SessionWindowController.revealWorkspace(_:)), keyEquivalent: "")
        session.addItem(withTitle: "Open Workspace in Terminal", action: #selector(SessionWindowController.openWorkspaceInTerminal(_:)), keyEquivalent: "")
        session.addItem(.separator())
        session.addItem(withTitle: "Previous Session", action: #selector(SessionWindowController.previousSession(_:)),
                        keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
            .keyEquivalentModifierMask = [.command, .option]
        session.addItem(withTitle: "Next Session", action: #selector(SessionWindowController.nextSession(_:)),
                        keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
            .keyEquivalentModifierMask = [.command, .option]
        sessionItem.submenu = session
        menu.addItem(sessionItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = window
        menu.addItem(windowItem)
        // AppKit appends the open windows below the items above.
        NSApp.windowsMenu = window
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Latch on GitHub", action: #selector(openProjectPage), keyEquivalent: "")
        helpItem.submenu = help
        menu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = menu
    }

    // MARK: Open Recent

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        guard !urls.isEmpty else {
            menu.addItem(withTitle: "No Recent Workspaces", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for url in urls {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecentWorkspace), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecentWorkspaces), keyEquivalent: "").target = self
    }

    @objc private func openRecentWorkspace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        controller?.openWorkspace(url)
    }

    @objc private func clearRecentWorkspaces() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    @objc private func openProjectPage() {
        guard let url = URL(string: "https://github.com/mercho40/latch") else { return }
        NSWorkspace.shared.open(url)
    }
}
