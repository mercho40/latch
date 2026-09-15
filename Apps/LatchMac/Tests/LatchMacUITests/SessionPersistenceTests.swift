import AppKit
import XCTest
@testable import LatchMacUI

final class SessionPersistenceTests: XCTestCase {
    @MainActor func testUnopenedSessionSnapshotPreservesAllFieldsWithoutLoadingView() async throws {
        try await withFixture { fixture in
            let saved = fixture.session(1, workspace: fixture.firstWorkspace)
            let session = SessionViewController(workspace: fixture.firstWorkspace,
                                                launchEnvironment: fixture.environment, savedSession: saved)
            XCTAssertFalse(session.isViewLoaded)
            XCTAssertEqual(session.id, saved.id)
            XCTAssertEqual(session.savedSession, saved)
            XCTAssertFalse(session.isViewLoaded, "Taking a snapshot must not initialize the agent")
            XCTAssertEqual(session.model.phase, .disconnected)
            await session.shutdown()
            XCTAssertEqual(session.savedSession, saved)
            XCTAssertFalse(session.isViewLoaded)
        }
    }

    @MainActor func testRestoreGroupsWorkspacesPreservesSelectionAndLeavesOtherSessionsUnloaded() async throws {
        try await withFixture { fixture in
            let first = fixture.session(1, workspace: fixture.firstWorkspace)
            let second = fixture.session(2, workspace: fixture.firstWorkspace)
            var third = fixture.session(3, workspace: fixture.secondWorkspace)
            third.agentID = AgentPreset.fx.rawValue
            third.customCommand = ""
            let library = SavedSessionLibrary(sessions: [first, second, third], selectedSessionID: second.id)
            try await fixture.store.save(library)
            let window = fixture.window()
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let sidebar = try fixture.sidebar(in: window)

            XCTAssertEqual(window.savedLibrary, library)
            XCTAssertNil(window.persistenceError)
            XCTAssertEqual(sidebar.workspaces.map(\.url.path), [fixture.firstWorkspace.path, fixture.secondWorkspace.path])
            XCTAssertEqual(sidebar.workspaces.map { $0.sessions.count }, [2, 1])
            XCTAssertEqual(sidebar.outline.numberOfRows, 5)
            XCTAssertEqual(sidebar.selectedSession?.id, second.id)
            XCTAssertEqual(window.window?.title, second.title)
            for session in sidebar.allSessions {
                XCTAssertEqual(session.isViewLoaded, session.id == second.id)
                XCTAssertEqual(session.model.phase, .disconnected)
                XCTAssertNil(session.model.errorMessage)
            }
            let selected = try XCTUnwrap(sidebar.selectedSession)
            XCTAssertTrue(selected.view.window === window.window)
            XCTAssertEqual(try fixture.composer(in: selected).string, second.draft)
            // Restore is one-shot, not an append operation.
            await window.restoreSessions(launchEnvironment: fixture.environment)
            XCTAssertEqual(window.savedLibrary, library)
            await window.flushPersistence()
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted, library)
        }
    }

    @MainActor func testMissingWorkspacesKeepHistoryAndOnlySelectedSessionReportsError() async throws {
        try await withFixture { fixture in
            let missing = fixture.root.appendingPathComponent("deleted-workspace")
            var first = fixture.session(1, workspace: missing)
            var second = fixture.session(2, workspace: missing)
            // Resolvable command, but workspace validation fails before any runtime starts.
            first.customCommand = "/bin/sh"
            second.customCommand = "/bin/sh"
            let library = SavedSessionLibrary(sessions: [first, second], selectedSessionID: second.id)
            try await fixture.store.save(library)
            let window = fixture.window()
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let sidebar = try fixture.sidebar(in: window)
            let selected = try XCTUnwrap(sidebar.selectedSession)
            try await eventually("Selected missing workspace should report validation failure") {
                selected.model.errorMessage != nil
            }
            XCTAssertEqual(selected.model.errorMessage, CommandError.workspaceRequired.localizedDescription)
            XCTAssertEqual(sidebar.outline.numberOfRows, 3)
            XCTAssertEqual(window.savedLibrary, library)
            XCTAssertEqual(selected.model.messages, second.messages)
            XCTAssertTrue(selected.view.window === window.window)
            XCTAssertFalse(selected.banner.isHidden, "A failed session must say so in its banner")
            XCTAssertEqual(selected.banner.displayedMessage, selected.model.errorMessage)
            let unopened = try XCTUnwrap(sidebar.allSessions.first)
            XCTAssertFalse(unopened.isViewLoaded)
            XCTAssertNil(unopened.model.errorMessage)
            XCTAssertEqual(unopened.model.messages, first.messages)
            XCTAssertEqual(unopened.model.phase, .disconnected)
            XCTAssertNil(window.persistenceError, "A missing workspace is not corrupt persistence")
            await window.shutdown()
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted, library)
        }
    }

    @MainActor func testDraftEditsAutosaveAndFlushShutdownRelaunchPreserveLatestSnapshot() async throws {
        try await withFixture { fixture in
            let saved = fixture.session(1, workspace: fixture.firstWorkspace)
            var expected = SavedSessionLibrary(sessions: [saved], selectedSessionID: saved.id)
            try await fixture.store.save(expected)
            let window = fixture.window()
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let selected = try XCTUnwrap(try fixture.sidebar(in: window).selectedSession)
            let composer = try fixture.composer(in: selected)
            // Observe setup completion, then drain pending saves so only the edit
            // can schedule this autosave. Keep the composer live and editable.
            let stop: NSButton = try fixture.control(in: selected.view, label: "Stop response")
            try await eventually("Invalid agent setup should finish without launching") { !stop.isEnabled }
            XCTAssertTrue(composer.isEditable)
            await window.flushPersistence()
            fixture.edit(composer, text: "Autosaved draft\nwith Unicode: café")
            expected.sessions[0].draft = composer.string
            let autosaved = expected
            try await eventually("Delegate edit should reach disk without an explicit flush") {
                try await fixture.store.load() == autosaved
            }
            fixture.edit(composer, text: "Explicit flush draft")
            expected.sessions[0].draft = composer.string
            await window.flushPersistence()
            let flushed = try await fixture.store.load()
            XCTAssertEqual(flushed, expected)
            fixture.edit(composer, text: "Final quit-time draft")
            expected.sessions[0].draft = composer.string
            await window.shutdown()
            let quitSnapshot = try await fixture.store.load()
            XCTAssertEqual(quitSnapshot, expected)

            // A new store instance reads disk, not any in-memory store state.
            let relaunched = fixture.window()
            await relaunched.restoreSessions(launchEnvironment: fixture.environment)
            XCTAssertEqual(relaunched.savedLibrary, expected)
            let restored = try XCTUnwrap(try fixture.sidebar(in: relaunched).selectedSession)
            XCTAssertEqual(try fixture.composer(in: restored).string, expected.sessions[0].draft)
            XCTAssertEqual(restored.model.messages, saved.messages, "Persistence must not submit drafts as prompts")
            XCTAssertEqual(restored.model.savedAgentSessionID, saved.agentSessionID)
            XCTAssertEqual(restored.model.phase, .disconnected)
            XCTAssertNil(relaunched.persistenceError)
            await relaunched.shutdown()
            let final = try await fixture.store.load()
            XCTAssertEqual(final, expected)
        }
    }

    @MainActor func testCorruptFileSurvivesRestoreEditsFlushShutdownAndRelaunch() async throws {
        try await withFixture { fixture in
            try FileManager.default.createDirectory(at: fixture.storeDirectory, withIntermediateDirectories: true)
            let file = fixture.storeDirectory.appendingPathComponent(SessionStore.fileName)
            let corrupt = Data("{\"version\":1,\"sessions\":[broken-private-draft".utf8)
            try corrupt.write(to: file)
            let window = fixture.window()
            await window.restoreSessions(launchEnvironment: fixture.environment)
            XCTAssertTrue(window.savedLibrary.sessions.isEmpty)
            XCTAssertNil(window.savedLibrary.selectedSessionID)
            let failure = try XCTUnwrap(window.persistenceError)
            XCTAssertTrue(failure.contains(SessionStore.StoreError.corrupt.localizedDescription))
            XCTAssertFalse(failure.contains("broken-private-draft"))
            let session = window.addSession(workspace: fixture.firstWorkspace, launchEnvironment: fixture.environment)
            fixture.edit(try fixture.composer(in: session), text: "Do not replace corrupt history")
            await window.flushPersistence()
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
            XCTAssertEqual(window.persistenceError, failure)
            await window.shutdown()
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
            let relaunched = fixture.window()
            await relaunched.restoreSessions(launchEnvironment: fixture.environment)
            XCTAssertEqual(relaunched.persistenceError, failure)
            XCTAssertTrue(relaunched.savedLibrary.sessions.isEmpty)
            await relaunched.shutdown()
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
        }
    }

    @MainActor private func eventually(
        _ message: String, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                return
            }
            // Poll observable state with a deadline; never assume a fixed settling delay.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    @MainActor private final class Fixture {
        let root: URL
        let firstWorkspace: URL
        let secondWorkspace: URL
        let storeDirectory: URL
        let store: SessionStore
        let environment: AgentLaunchEnvironment
        private var windows: [SessionWindowController] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionPersistenceTests-\(UUID().uuidString)")
            firstWorkspace = root.appendingPathComponent("workspace-one")
            secondWorkspace = root.appendingPathComponent("workspace-two")
            storeDirectory = root.appendingPathComponent("store")
            store = SessionStore(directory: storeDirectory)
            let home = root.appendingPathComponent("home")
            environment = AgentLaunchEnvironment(environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
                                                 home: home, includeCommonLocations: false)
            do {
                for directory in [firstWorkspace, secondWorkspace, home] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func session(_ number: Int, workspace: URL) -> SavedSession {
            SavedSession(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
                         workspacePath: workspace.path, title: "Saved title \(number)", agentID: AgentPreset.custom.rawValue,
                         customCommand: AgentCommand.quotedArgument(root.appendingPathComponent("missing-agent").path) + " --profile 'test profile'",
                         draft: "Unsent draft \(number)\nsecond line", messages: [
                            ChatMessage(id: messageID(number, 1), role: .user, text: "Question \(number)"),
                            ChatMessage(id: messageID(number, 2), role: .assistant, text: "Answer \(number)"),
                            ChatMessage(id: messageID(number, 3), role: .tool, text: "Read file \(number) · completed"),
                         ], agentSessionID: "saved-agent-context-\(number)")
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

        func composer(in session: SessionViewController) throws -> NSTextView {
            try control(in: session.view, label: "Message to agent")
        }

        func edit(_ composer: NSTextView, text: String) {
            XCTAssertNotNil(composer.delegate)
            composer.string = text
            composer.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: composer))
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
