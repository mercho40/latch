import AppKit
import XCTest
@testable import LatchMacUI

/// Closing a session removes it from the sidebar, the detail view, and the saved library,
/// and stops its agent. Undo puts it back in the same slot with everything it held.
final class SessionCloseTests: XCTestCase {
    @MainActor func testClosingRemovesTheRowSelectsANeighbourAndForgetsIt() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1), fixture.session(2))
            let first = try XCTUnwrap(sidebar.allSessions.first)
            let second = try XCTUnwrap(sidebar.allSessions.last)
            sidebar.select(first)

            window.closeSession(nil)

            XCTAssertEqual(sidebar.allSessions.count, 1)
            XCTAssertTrue(sidebar.allSessions.first === second)
            XCTAssertTrue(sidebar.selectedSession === second, "Selection moves to the next session")
            XCTAssertEqual(sidebar.workspaces.count, 1, "The workspace keeps its remaining session")
            XCTAssertEqual(window.savedLibrary.sessions.map(\.id), [second.id])

            await window.flushPersistence()
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted.sessions.map(\.id), [second.id])
            XCTAssertEqual(persisted.selectedSessionID, second.id)
        }
    }

    @MainActor func testClosingTheLastSessionEmptiesTheWindow() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1))
            let detail = try fixture.detail(in: window)

            window.closeSession(nil)

            XCTAssertTrue(sidebar.allSessions.isEmpty)
            XCTAssertTrue(sidebar.workspaces.isEmpty, "The workspace group goes with its last session")
            XCTAssertNil(sidebar.selectedSession)
            XCTAssertTrue(detail.children.isEmpty)
            XCTAssertEqual(window.window?.title, "Latch")

            await window.flushPersistence()
            let persisted = try await fixture.store.load()
            XCTAssertTrue(persisted.sessions.isEmpty)
        }
    }

    @MainActor func testUndoRestoresTheSessionInPlaceWithItsContext() async throws {
        try await WindowFixture.run { fixture in
            let saved = fixture.session(2)
            let (window, sidebar) = try await fixture.restored(fixture.session(1), saved, fixture.session(3))
            let target = try XCTUnwrap(sidebar.allSessions.first { $0.id == saved.id })
            sidebar.select(target)
            let undo = try XCTUnwrap(window.window?.undoManager)

            window.closeSession(nil)
            XCTAssertEqual(sidebar.allSessions.count, 2)
            XCTAssertTrue(undo.canUndo)
            XCTAssertEqual(undo.undoActionName, "Close Session")

            undo.undo()

            // Back in the middle of the list, selected, with its transcript, draft, and
            // agent context intact — a new controller built from the same snapshot.
            XCTAssertEqual(sidebar.allSessions.map(\.id), [fixture.id(1), saved.id, fixture.id(3)])
            let restored = try XCTUnwrap(sidebar.selectedSession)
            XCTAssertEqual(restored.id, saved.id)
            XCTAssertFalse(restored === target)
            XCTAssertEqual(restored.savedSession, saved)
            XCTAssertEqual(restored.model.messages.map(\.text), saved.messages.map(\.text))
            XCTAssertEqual(restored.model.savedAgentSessionID, saved.agentSessionID)
            XCTAssertTrue(undo.canRedo)

            await window.flushPersistence()
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted.sessions.count, 3)
            XCTAssertEqual(persisted.sessions.first { $0.id == saved.id }, saved)
        }
    }

    @MainActor func testRedoClosesTheSessionAgain() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1), fixture.session(2))
            let undo = try XCTUnwrap(window.window?.undoManager)
            sidebar.select(sidebar.allSessions.first)

            window.closeSession(nil)
            undo.undo()
            XCTAssertEqual(sidebar.allSessions.count, 2)

            undo.redo()

            XCTAssertEqual(sidebar.allSessions.map(\.id), [fixture.id(2)])
            XCTAssertTrue(undo.canUndo, "Redoing a close must be undoable again")
        }
    }

    @MainActor func testDeleteKeyInTheSidebarClosesTheSelectedSession() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(fixture.session(1), fixture.session(2))
            sidebar.select(sidebar.allSessions.first)

            // NSOutlineView leaves ⌫ unhandled; it reaches the controller through the chain.
            sidebar.deleteBackward(nil)

            XCTAssertEqual(sidebar.allSessions.map(\.id), [fixture.id(2)])
        }
    }

    @MainActor func testCloseSessionIsDisabledWithoutASelection() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1))
            let item = NSMenuItem(title: "Close Session", action: #selector(SessionWindowController.closeSession(_:)), keyEquivalent: "")

            XCTAssertTrue(window.validateMenuItem(item))
            sidebar.select(nil)
            XCTAssertFalse(window.validateMenuItem(item))
        }
    }

    @MainActor func testWindowRemembersItsFrame() async throws {
        try await WindowFixture.run { fixture in
            let window = fixture.window()
            XCTAssertEqual(window.window?.frameAutosaveName, "LatchSessionWindow")
        }
    }

    @MainActor func testComposerUndoIsSeparateFromSessionUndo() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1))
            let session = try XCTUnwrap(sidebar.selectedSession)
            let prompt: NSTextView = try fixture.control(in: session.view, label: "Message to agent")

            XCTAssertTrue(prompt.allowsUndo, "⌘Z in the composer did nothing before this")
            XCTAssertTrue(prompt.isContinuousSpellCheckingEnabled)
            XCTAssertFalse(prompt.isAutomaticSpellingCorrectionEnabled, "Autocorrect mangles paths and flags")
            XCTAssertFalse(prompt.isAutomaticTextReplacementEnabled)
            XCTAssertFalse(prompt.isAutomaticQuoteSubstitutionEnabled)

            // Undoing a draft edit must never reach into the window's session-level stack.
            let composerUndo = try XCTUnwrap(session.undoManager(for: prompt))
            XCTAssertFalse(composerUndo === window.window?.undoManager)
        }
    }

    @MainActor func testMainMenuCarriesTheStandardCommands() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let delegate = LatchApplicationDelegate()

        delegate.installMenu()

        let menu = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertEqual(menu.items.compactMap { $0.submenu?.title },
                       ["Latch", "File", "Edit", "View", "Session", "Window", "Help"])
        XCTAssertTrue(NSApp.windowsMenu === menu.items.compactMap(\.submenu).first { $0.title == "Window" })
        XCTAssertNotNil(NSApp.servicesMenu)
        let file = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "File" })
        let close = try XCTUnwrap(file.items.first { $0.title == "Close Session" })
        XCTAssertEqual(close.keyEquivalent, String(UnicodeScalar(NSBackspaceCharacter)!))
        XCTAssertEqual(close.keyEquivalentModifierMask, [.command])
        let edit = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let redo = try XCTUnwrap(edit.items.first { $0.title == "Redo" })
        XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])
        let view = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "View" })
        XCTAssertNotNil(view.items.first { $0.title == "Enter Full Screen" })
        XCTAssertNotNil(view.items.first { $0.title == "Show in Menu Bar" })

        // Session commands and find are reachable by keyboard, not just by mouse.
        let session = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "Session" })
        let stop = try XCTUnwrap(session.items.first { $0.title == "Stop" })
        XCTAssertEqual(stop.keyEquivalent, ".")
        XCTAssertEqual(stop.keyEquivalentModifierMask, [.command])
        let next = try XCTUnwrap(session.items.first { $0.title == "Next Session" })
        XCTAssertEqual(next.keyEquivalent, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command, .option])
        XCTAssertNotNil(session.items.first { $0.title == "Reveal Workspace in Finder" })
        let find = try XCTUnwrap(edit.items.first { $0.title == "Find" }?.submenu)
        XCTAssertEqual(find.items.map(\.title), ["Find…", "Find Next", "Find Previous"])
        XCTAssertEqual(find.items.first?.keyEquivalent, "f")
        XCTAssertNotNil(file.items.first { $0.title == "Open Recent" }?.submenu)
    }

}
