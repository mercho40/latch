import AppKit
import XCTest
@testable import LatchMacUI

/// A session that already holds a transcript owns its harness: switching forks a sibling
/// session in the same workspace instead of discarding the original's context.
final class SessionForkTests: XCTestCase {
    @MainActor func testSwitchingHarnessWithHistoryForksSiblingAndKeepsOriginal() async throws {
        try await withFixture { fixture in
            let saved = fixture.session(1, messages: true)
            try await fixture.store.save(SavedSessionLibrary(sessions: [saved], selectedSessionID: saved.id))
            let window = fixture.window()
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let sidebar = try fixture.sidebar(in: window)
            let original = try XCTUnwrap(sidebar.selectedSession)

            try fixture.selectAgent(.fx, in: original)

            // The original is untouched: same harness, transcript, agent context, and command.
            XCTAssertEqual(original.savedSession, saved)
            XCTAssertEqual(original.model.messages.map(\.text), saved.messages.map(\.text))
            XCTAssertEqual(original.model.savedAgentSessionID, saved.agentSessionID)

            // The fork sits beside it under the same workspace and is now selected.
            XCTAssertEqual(sidebar.workspaces.count, 1)
            let sessions = try XCTUnwrap(sidebar.workspaces.first).sessions
            XCTAssertEqual(sessions.count, 2)
            XCTAssertTrue(sessions.first === original)
            let fork = try XCTUnwrap(sessions.last)
            XCTAssertTrue(sidebar.selectedSession === fork)
            XCTAssertEqual(fork.workspace.standardizedFileURL, original.workspace.standardizedFileURL)
            XCTAssertEqual(fork.savedSession.agentID, AgentPreset.fx.rawValue)
            XCTAssertTrue(fork.model.messages.isEmpty)
            XCTAssertNil(fork.model.savedAgentSessionID)
            XCTAssertNotEqual(fork.id, original.id)

            await window.flushPersistence()
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted.sessions.count, 2)
            XCTAssertEqual(persisted.sessions.first, saved, "Forking must not rewrite the original")
        }
    }

    @MainActor func testSwitchingHarnessWithoutHistorySwitchesInPlace() async throws {
        try await withFixture { fixture in
            let saved = fixture.session(1, messages: false)
            try await fixture.store.save(SavedSessionLibrary(sessions: [saved], selectedSessionID: saved.id))
            let window = fixture.window()
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let sidebar = try fixture.sidebar(in: window)
            let session = try XCTUnwrap(sidebar.selectedSession)

            try fixture.selectAgent(.fx, in: session)

            // Nothing to preserve, so the session keeps its identity and changes harness.
            XCTAssertEqual(sidebar.allSessions.count, 1)
            XCTAssertTrue(sidebar.selectedSession === session)
            XCTAssertEqual(session.id, saved.id)
            XCTAssertEqual(session.savedSession.agentID, AgentPreset.fx.rawValue)
            XCTAssertNil(session.savedSession.agentSessionID)
        }
    }

    @MainActor func testCommittedCommandChangeWithHistoryForksOntoTheNewCommand() async throws {
        try await withFixture { fixture in
            let saved = fixture.session(1, messages: true)
            try await fixture.store.save(SavedSessionLibrary(sessions: [saved], selectedSessionID: saved.id))
            let window = fixture.window()
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let sidebar = try fixture.sidebar(in: window)
            let original = try XCTUnwrap(sidebar.selectedSession)
            let field: NSTextField = try fixture.control(in: original.view, label: "ACP agent command")
            let replacement = "/usr/bin/false --forked"

            field.stringValue = replacement
            original.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            original.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))

            XCTAssertEqual(original.savedSession, saved, "A committed edit must not rewrite the original")
            XCTAssertEqual(field.stringValue, saved.customCommand, "The field reverts to the committed command")
            XCTAssertEqual(sidebar.allSessions.count, 2)
            let fork = try XCTUnwrap(sidebar.allSessions.last)
            XCTAssertTrue(sidebar.selectedSession === fork)
            XCTAssertEqual(fork.savedSession.agentID, AgentPreset.custom.rawValue)
            XCTAssertEqual(fork.savedSession.customCommand, replacement)
            XCTAssertTrue(fork.model.messages.isEmpty)
        }
    }

    @MainActor func testUncommittedCommandEditKeepsSavedHistoryAndContext() async throws {
        try await withFixture { fixture in
            let saved = fixture.session(1, messages: true)
            try await fixture.store.save(SavedSessionLibrary(sessions: [saved], selectedSessionID: saved.id))
            let window = fixture.window()
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let sidebar = try fixture.sidebar(in: window)
            let session = try XCTUnwrap(sidebar.selectedSession)
            let field: NSTextField = try fixture.control(in: session.view, label: "ACP agent command")

            field.stringValue = "/usr/bin/false --half-typed"
            session.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

            // Typing is transient UI state; a quit here must not lose the conversation.
            XCTAssertEqual(session.savedSession, saved)
            XCTAssertEqual(sidebar.allSessions.count, 1, "Typing must not fork")
            await window.flushPersistence()
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted.sessions, [saved])
        }
    }

    // MARK: Fixture

    @MainActor private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        do { try await body(fixture) } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    @MainActor private final class Fixture {
        let root: URL
        let workspace: URL
        let storeDirectory: URL
        let store: SessionStore
        let environment: AgentLaunchEnvironment
        private var windows: [SessionWindowController] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionForkTests-\(UUID().uuidString)")
            workspace = root.appendingPathComponent("workspace")
            storeDirectory = root.appendingPathComponent("store")
            store = SessionStore(directory: storeDirectory)
            let home = root.appendingPathComponent("home")
            // No harness is installed here, so no selection can launch a process.
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

        func session(_ number: Int, messages: Bool) -> SavedSession {
            let history = [
                ChatMessage(id: messageID(number, 1), role: .user, text: "Question \(number)"),
                ChatMessage(id: messageID(number, 2), role: .assistant, text: "Answer \(number)"),
            ]
            return SavedSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
                workspacePath: workspace.path, title: "Saved title \(number)",
                agentID: AgentPreset.custom.rawValue,
                customCommand: AgentCommand.quotedArgument(root.appendingPathComponent("missing-agent").path),
                draft: "Unsent draft \(number)",
                messages: messages ? history : [],
                agentSessionID: messages ? "saved-agent-context-\(number)" : nil
            )
        }

        private func messageID(_ session: Int, _ message: Int) -> UUID {
            UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", session * 10 + message))!
        }

        func window() -> SessionWindowController {
            let window = SessionWindowController(store: SessionStore(directory: storeDirectory))
            windows.append(window)
            return window
        }

        func sidebar(in window: SessionWindowController) throws -> SidebarViewController {
            let split = try XCTUnwrap(window.window?.contentViewController as? NSSplitViewController)
            return try XCTUnwrap(split.children.compactMap { $0 as? SidebarViewController }.first)
        }

        func control<T: NSView>(in view: NSView, label: String) throws -> T {
            func find(_ view: NSView) -> T? {
                if let control = view as? T, control.accessibilityLabel() == label { return control }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return try XCTUnwrap(find(view), "Missing accessible control: \(label)")
        }

        /// Drives the real popup action rather than calling into private selection code.
        func selectAgent(_ agent: AgentPreset, in session: SessionViewController) throws {
            let popup: NSPopUpButton = try control(in: session.view, label: "ACP agent")
            popup.selectItem(at: try XCTUnwrap(AgentPreset.allCases.firstIndex(of: agent)))
            NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup)
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
}
