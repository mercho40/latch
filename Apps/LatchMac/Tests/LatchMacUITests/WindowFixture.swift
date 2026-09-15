import AppKit
import XCTest
@testable import LatchMacUI

/// A temporary store, workspace, and window for tests that drive the real window controller.
/// The launch environment has no harness installed, so no selection can launch a process,
/// and no attention center or menu bar extra is attached unless a test asks for one.
@MainActor
final class WindowFixture {
    let root: URL
    let workspace: URL
    let storeDirectory: URL
    let store: SessionStore
    let environment: AgentLaunchEnvironment
    private var windows: [SessionWindowController] = []

    /// Runs `body` against a fresh fixture and tears its windows down afterwards.
    static func run(_ body: (WindowFixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        let fixture = try WindowFixture()
        do { try await body(fixture) } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LatchWindowFixture-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        storeDirectory = root.appendingPathComponent("store")
        store = SessionStore(directory: storeDirectory)
        let home = root.appendingPathComponent("home")
        environment = AgentLaunchEnvironment(environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
                                             home: home, includeCommonLocations: false)
        do {
            for directory in [workspace, home] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    func session(_ number: Int, messages: Bool = true, workspace: URL? = nil) -> SavedSession {
        SavedSession(
            id: id(number), workspacePath: (workspace ?? self.workspace).path, title: "Saved title \(number)",
            agentID: AgentPreset.custom.rawValue,
            customCommand: AgentCommand.quotedArgument(root.appendingPathComponent("missing-agent").path),
            draft: "Unsent draft \(number)",
            messages: messages ? [
                ChatMessage(id: messageID(number, 1), role: .user, text: "Question \(number)"),
                ChatMessage(id: messageID(number, 2), role: .assistant, text: "Answer \(number)"),
            ] : [],
            agentSessionID: messages ? "saved-agent-context-\(number)" : nil
        )
    }

    private func messageID(_ session: Int, _ message: Int) -> UUID {
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", session * 10 + message))!
    }

    /// A window restored from the given saved sessions, with the first one selected.
    func restored(_ sessions: SavedSession..., attention: AttentionCenter? = nil,
                  menuBar: MenuBarController? = nil) async throws -> (SessionWindowController, SidebarViewController) {
        try await store.save(SavedSessionLibrary(sessions: sessions, selectedSessionID: sessions.first?.id))
        let window = self.window(attention: attention, menuBar: menuBar)
        await window.restoreSessions(launchEnvironment: environment)
        return (window, try sidebar(in: window))
    }

    func window(attention: AttentionCenter? = nil, menuBar: MenuBarController? = nil) -> SessionWindowController {
        let window = SessionWindowController(store: SessionStore(directory: storeDirectory),
                                             attention: attention, menuBar: menuBar)
        windows.append(window)
        return window
    }

    func sidebar(in window: SessionWindowController) throws -> SidebarViewController {
        let split = try XCTUnwrap(window.window?.contentViewController as? NSSplitViewController)
        return try XCTUnwrap(split.children.compactMap { $0 as? SidebarViewController }.first)
    }

    func detail(in window: SessionWindowController) throws -> NSViewController {
        let split = try XCTUnwrap(window.window?.contentViewController as? NSSplitViewController)
        return try XCTUnwrap(split.children.last { !($0 is SidebarViewController) })
    }

    func control<T: NSView>(in view: NSView, label: String) throws -> T {
        func find(_ view: NSView) -> T? {
            if let control = view as? T, control.accessibilityLabel() == label { return control }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(view), "Missing accessible control: \(label)")
    }

    /// Waits for an in-flight connection attempt to finish. A restored session starts one
    /// as soon as it is selected, even when its command cannot launch.
    struct SettleTimeout: Error, CustomStringConvertible {
        let description: String
    }

    func settle(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5,
                file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("The session did not settle within \(timeout)s", file: file, line: line)
                throw SettleTimeout(description: "Session did not settle")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A folder that exists only for the length of the test.
    func makeFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("not a workspace".utf8).write(to: url)
        return url
    }

    func cleanup() async {
        for window in windows {
            await window.shutdown()
            window.close()
        }
        windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }
}
