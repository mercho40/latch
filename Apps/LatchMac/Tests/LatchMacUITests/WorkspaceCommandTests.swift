import AppKit
import XCTest
@testable import LatchMacUI

/// Opening a workspace, moving between sessions, renaming one, and the session commands
/// in the menu bar — the parts of the window that are not the conversation itself.
@MainActor
final class WorkspaceCommandTests: XCTestCase {
    func testDroppingAFolderOnTheSidebarOpensASessionInIt() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1))
            let dropped = try fixture.makeFolder("dropped-workspace")
            let info = DragStub(urls: [dropped])

            XCTAssertEqual(sidebar.outlineView(sidebar.outline, validateDrop: info, proposedItem: nil, proposedChildIndex: -1), .copy)
            XCTAssertTrue(sidebar.outlineView(sidebar.outline, acceptDrop: info, item: nil, childIndex: -1))

            XCTAssertEqual(sidebar.workspaces.count, 2)
            XCTAssertEqual(sidebar.workspaces.last?.url.standardizedFileURL, dropped.standardizedFileURL)
            XCTAssertEqual(window.savedLibrary.sessions.count, 2)
        }
    }

    func testDroppingAFileIsRefused() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(fixture.session(1))
            let info = DragStub(urls: [try fixture.makeFile("notes.txt")])

            XCTAssertEqual(sidebar.outlineView(sidebar.outline, validateDrop: info, proposedItem: nil, proposedChildIndex: -1), [])
            XCTAssertFalse(sidebar.outlineView(sidebar.outline, acceptDrop: info, item: nil, childIndex: -1))
            XCTAssertEqual(sidebar.workspaces.count, 1, "A file has no workspace to run an agent in")
        }
    }

    func testOpeningAWorkspaceRemembersItAsRecent() async throws {
        try await WindowFixture.run { fixture in
            let (window, _) = try await fixture.restored(fixture.session(1))
            let folder = try fixture.makeFolder("recent-workspace")
            defer { NSDocumentController.shared.clearRecentDocuments(nil) }

            window.openWorkspace(folder)

            XCTAssertTrue(NSDocumentController.shared.recentDocumentURLs.contains {
                $0.standardizedFileURL == folder.standardizedFileURL
            })
        }
    }

    func testNextAndPreviousSessionWrapAround() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1), fixture.session(2), fixture.session(3))
            sidebar.select(sidebar.allSessions.first)

            window.nextSession(nil)
            XCTAssertEqual(sidebar.selectedSession?.id, fixture.id(2))

            window.previousSession(nil)
            window.previousSession(nil)
            XCTAssertEqual(sidebar.selectedSession?.id, fixture.id(3), "Previous wraps to the last session")

            window.nextSession(nil)
            XCTAssertEqual(sidebar.selectedSession?.id, fixture.id(1), "Next wraps to the first session")
        }
    }

    func testRenamingASessionSticksAndIsSaved() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1))
            let session = try XCTUnwrap(sidebar.selectedSession)
            let cell = try XCTUnwrap(sidebar.outline.view(atColumn: 0, row: sidebar.outline.row(forItem: session),
                                                          makeIfNecessary: true) as? SessionCellView)
            let field = try XCTUnwrap(cell.textField)

            cell.beginRename()
            XCTAssertTrue(field.isEditable)
            field.stringValue = "Parser rewrite"
            cell.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))

            XCTAssertEqual(session.savedSession.title, "Parser rewrite")
            XCTAssertEqual(window.window?.title, "Parser rewrite")
            XCTAssertFalse(field.isEditable, "A finished rename leaves the row alone again")

            await window.flushPersistence()
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted.sessions.first?.title, "Parser rewrite")
        }
    }

    func testEscapeDuringRenameKeepsTheOldTitle() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(fixture.session(1))
            let session = try XCTUnwrap(sidebar.selectedSession)
            let cell = try XCTUnwrap(sidebar.outline.view(atColumn: 0, row: sidebar.outline.row(forItem: session),
                                                          makeIfNecessary: true) as? SessionCellView)
            let field = try XCTUnwrap(cell.textField)

            cell.beginRename()
            field.stringValue = "Half-typed"
            _ = cell.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))

            XCTAssertEqual(session.savedSession.title, "Saved title 1")
            XCTAssertEqual(field.stringValue, "Saved title 1")
        }
    }

    func testSessionCommandsAreDisabledWhenTheyCannotRun() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1))
            let session = try XCTUnwrap(sidebar.selectedSession)
            // Selecting a restored session starts a connection attempt, which this command
            // can stop. Nothing here can launch, so it settles into a disconnected session.
            XCTAssertTrue(window.validateMenuItem(item(#selector(SessionWindowController.stopSession(_:)))))
            try await fixture.settle { !session.canStop }

            // Nothing is connected any more, so there is nothing to stop or hang up.
            XCTAssertFalse(session.canStop)
            XCTAssertFalse(session.canDisconnect)
            XCTAssertFalse(window.validateMenuItem(item(#selector(SessionWindowController.stopSession(_:)))))
            XCTAssertFalse(window.validateMenuItem(item(#selector(SessionWindowController.disconnectSession(_:)))))
            XCTAssertFalse(window.validateMenuItem(item(#selector(SessionWindowController.nextSession(_:)))),
                           "One session has nowhere to step to")
            XCTAssertTrue(window.validateMenuItem(item(#selector(SessionWindowController.revealWorkspace(_:)))))
            XCTAssertTrue(window.validateMenuItem(item(#selector(SessionWindowController.performFindPanelAction(_:)))))
            XCTAssertFalse(window.validateMenuItem(item(#selector(SessionWindowController.findNextMatch(_:)))),
                           "Nothing has been searched for yet")

            sidebar.select(nil)
            XCTAssertFalse(window.validateMenuItem(item(#selector(SessionWindowController.performFindPanelAction(_:)))))
            XCTAssertFalse(window.validateMenuItem(item(#selector(SessionWindowController.revealWorkspace(_:)))))
        }
    }

    func testFindCommandsDriveTheSelectedSession() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(fixture.session(1))
            let session = try XCTUnwrap(sidebar.selectedSession)

            window.performFindPanelAction(nil)
            XCTAssertTrue(session.conversation.isFindBarVisible)

            session.conversation.search("Question")
            XCTAssertEqual(session.conversation.matchCount, 1)
            XCTAssertTrue(window.validateMenuItem(item(#selector(SessionWindowController.findNextMatch(_:)))))
        }
    }

    func testAttentionAndMenuBarFollowEverySession() async throws {
        try await WindowFixture.run { fixture in
            let menuBar = MenuBarController(defaults: UserDefaults(suiteName: "WorkspaceCommandTests")!,
                                            installsStatusItem: false)
            let attention = AttentionCenter(presenter: nil)
            let (window, sidebar) = try await fixture.restored(fixture.session(1), fixture.session(2),
                                                               attention: attention, menuBar: menuBar)
            defer { UserDefaults.standard.removePersistentDomain(forName: "WorkspaceCommandTests") }

            // Both sessions are listed, not only the one the window is showing.
            XCTAssertEqual(menuBar.buildMenu().items.filter { $0.representedObject is UUID }.map(\.title),
                           ["Saved title 1", "Saved title 2"])
            XCTAssertEqual(attention.badgeCount, 0)

            let second = try XCTUnwrap(sidebar.allSessions.last)
            window.reveal(second.id)
            XCTAssertTrue(sidebar.selectedSession === second)
        }
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }
}

/// A dragging session carrying file URLs. `NSDraggingInfo` is a protocol, so the drop path
/// can be exercised without a real drag. `NSDraggingInfo` is not main-actor isolated, so
/// neither is this.
private final class DragStub: NSObject, NSDraggingInfo, @unchecked Sendable {
    private let urls: [URL]
    private let name: NSPasteboard.Name

    init(urls: [URL]) {
        self.urls = urls
        name = NSPasteboard.Name("LatchDragStub-\(UUID().uuidString)")
    }

    /// Refilled on each read; a drop is validated and then accepted.
    @MainActor var draggingPasteboard: NSPasteboard {
        let board = NSPasteboard(name: name)
        board.clearContents()
        board.writeObjects(urls.map { $0 as NSURL })
        return board
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
