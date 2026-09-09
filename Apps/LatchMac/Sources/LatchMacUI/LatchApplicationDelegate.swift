import AppKit

@MainActor
public final class LatchApplicationDelegate: NSObject, NSApplicationDelegate {
    private var controller: SessionWindowController?
    private var terminating = false
    private var shutdownComplete = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let controller = SessionWindowController()
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                FileHandle.standardError.write(Data("UI SMOKE: timed out\n".utf8))
                exit(EXIT_FAILURE)
            }
            Task {
                do {
                    try await controller.smokeTest()
                    print("UI SMOKE: AppKit window, connect, streamed transcript, cancel, disconnect, permission sheets — PASS")
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
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
