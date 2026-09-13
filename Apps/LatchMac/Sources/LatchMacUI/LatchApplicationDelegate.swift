import AppKit

@MainActor
public final class LatchApplicationDelegate: NSObject, NSApplicationDelegate {
    private var controller: SessionWindowController?
    private var terminating = false
    private var shutdownComplete = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let smokeTest = CommandLine.arguments.contains("--smoke-test")
        let controller = SessionWindowController(store: smokeTest ? nil : SessionStore(directory: SessionStore.defaultDirectory))
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
                    print("UI SMOKE: chat layout, streaming, composer keyboard controls, sidebar, model/effort pickers, cancel, disconnect, permission sheets — PASS")
                    NSApp.terminate(nil)
                } catch {
                    await controller.shutdown()
                    FileHandle.standardError.write(Data("UI SMOKE: \(error)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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

    private func installMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu(title: "Latch")
        application.addItem(withTitle: "About Latch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Latch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Latch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = application
        menu.addItem(applicationItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Session…", action: #selector(SessionWindowController.newSession(_:)), keyEquivalent: "n")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy Conversation", action: #selector(SessionWindowController.copyConversation(_:)), keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        NSApp.mainMenu = menu
    }
}
