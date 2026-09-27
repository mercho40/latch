import AppKit
import LatchACP
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
import XCTest
@testable import LatchMacUI

@MainActor
final class RemoteSessionTests: XCTestCase {
    private let vps = ServerProfile(id: UUID(uuidString: "5E4E4000-0000-0000-0000-000000000001")!,
                                    name: "vps", host: "vps.tailnet.ts.net", token: LatchRemoteToken.generate(),
                                    customCommand: "my-agent --acp")
    private let mini = ServerProfile(id: UUID(uuidString: "5E4E4000-0000-0000-0000-000000000002")!,
                                     name: "mini", host: "100.64.0.2", token: LatchRemoteToken.generate())

    private func home(_ path: String) -> ServerCheck {
        { _ in LatchRemoteServerInfo(version: "0.2.0", hostname: "vps-1", os: "Ubuntu 24.04", arch: "x86_64", home: path) }
    }

    private func remote(_ fixture: WindowFixture, _ number: Int, server: ServerProfile, path: String,
                        messages: Bool = true) -> SavedSession {
        var saved = fixture.session(number, messages: messages)
        saved.workspacePath = path
        saved.serverID = server.id
        saved.agentID = AgentPreset.claudeCode.rawValue
        saved.customCommand = ""
        return saved
    }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    // MARK: Persistence

    func testARemoteLocationSurvivesSavingAndRestoring() async throws {
        try await WindowFixture.run { fixture in
            let saved = remote(fixture, 1, server: vps, path: "/home/me/project")
            let (window, sidebar) = try await fixture.restored(saved, fixture.session(2),
                                                               servers: InMemoryServerStore([vps]))
            let restored = try XCTUnwrap(sidebar.allSessions.first)
            XCTAssertEqual(restored.location, .remote(serverID: vps.id, path: "/home/me/project"))
            XCTAssertNil(restored.localURL)
            XCTAssertEqual(sidebar.allSessions.last?.location.groupKey, WorkspaceLocation.local(fixture.workspace).groupKey)

            XCTAssertEqual(window.savedLibrary.sessions.first?.serverID, vps.id)
            XCTAssertEqual(window.savedLibrary.sessions.first?.workspacePath, "/home/me/project")
            XCTAssertNil(window.savedLibrary.sessions.last?.serverID)
            XCTAssertEqual(window.savedLibrary.version, 2)
        }
    }

    func testAFileFromBeforeRemoteSessionsStillDecodesAsLocal() throws {
        let old = Data("""
        {"version":1,"selectedSessionID":"00000000-0000-0000-0000-000000000001","sessions":[{
          "id":"00000000-0000-0000-0000-000000000001","workspacePath":"/Users/me/app","title":"Old",
          "agentID":"codex","customCommand":"","draft":"","messages":[],"agentSessionID":"ctx"}]}
        """.utf8)
        let library = try JSONDecoder().decode(SavedSessionLibrary.self, from: old)
        XCTAssertEqual(library.version, 1)
        XCTAssertNil(library.sessions[0].serverID)
        XCTAssertEqual(WorkspaceLocation(library.sessions[0]), .local(URL(fileURLWithPath: "/Users/me/app")))
    }

    func testTheLibraryVersionRisesOnlyWhileARemoteSessionExists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteVersion-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let file = directory.appendingPathComponent(SessionStore.fileName)
        func version() throws -> Int? {
            try (JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["version"] as? Int
        }
        var local = SavedSession(id: UUID(), workspacePath: "/tmp/app", title: "Local", agentID: "codex",
                                 customCommand: "", draft: "", messages: [])
        try await store.save(SavedSessionLibrary(sessions: [local], selectedSessionID: nil))
        XCTAssertEqual(try version(), 1)
        let keys = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["sessions"] as? [[String: Any]])
        XCTAssertNil(keys[0]["serverID"], "A local session writes no server key")

        var remote = local
        remote.id = UUID()
        remote.serverID = UUID()
        try await store.save(SavedSessionLibrary(sessions: [local, remote], selectedSessionID: nil))
        XCTAssertEqual(try version(), 2)
        let restored = try await SessionStore(directory: directory).load()
        XCTAssertEqual(restored.sessions.map(\.serverID), [nil, remote.serverID])

        // Closing the last remote session hands the file back to older builds.
        try await store.save(SavedSessionLibrary(sessions: [local], selectedSessionID: nil))
        XCTAssertEqual(try version(), 1)

        // A version-1 file never carries a remote session: an older build would misread it.
        local.serverID = UUID()
        let mislabeled = try JSONEncoder().encode(SavedSessionLibrary(version: 1, sessions: [local], selectedSessionID: nil))
        try mislabeled.write(to: file)
        do {
            _ = try await SessionStore(directory: directory).load()
            XCTFail("Expected a version-1 file with a remote session to be refused")
        } catch {
            XCTAssertEqual(error as? SessionStore.StoreError, .invalidLibrary)
        }
    }

    // MARK: Sidebar and window

    func testGroupsKeepTheSamePathOnDifferentMachinesApart() async throws {
        try await WindowFixture.run { fixture in
            let path = fixture.workspace.path
            let (window, sidebar) = try await fixture.restored(
                fixture.session(1), remote(fixture, 2, server: vps, path: path), remote(fixture, 3, server: mini, path: path),
                remote(fixture, 4, server: vps, path: path), servers: InMemoryServerStore([vps, mini]))
            XCTAssertEqual(sidebar.workspaces.map(\.location.groupKey), [
                WorkspaceLocation.local(fixture.workspace).groupKey,
                .remote(serverID: vps.id, path: path), .remote(serverID: mini.id, path: path),
            ])
            XCTAssertEqual(sidebar.workspaces.map { $0.sessions.map(\.id) },
                           [[fixture.id(1)], [fixture.id(2), fixture.id(4)], [fixture.id(3)]])
            let folder = fixture.workspace.lastPathComponent
            XCTAssertEqual(sidebar.workspaces.map { sidebar.groupTitle($0.location).name },
                           [folder, "vps · \(folder)", "mini · \(folder)"])

            sidebar.select(sidebar.allSessions[1])
            XCTAssertEqual(window.window?.subtitle, "vps · \(path)")
            sidebar.select(sidebar.allSessions[0])
            XCTAssertEqual(window.window?.subtitle, path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
    }

    func testFinderAndTerminalAreOffForARemoteSessionAndCopyPathCopiesTheServerPath() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(
                remote(fixture, 1, server: vps, path: "/srv/app"), fixture.session(2), servers: InMemoryServerStore([vps]))
            let remoteSession = sidebar.allSessions[0]
            sidebar.select(remoteSession)
            XCTAssertFalse(window.validateMenuItem(item(#selector(SessionWindowController.revealWorkspace(_:)))))
            XCTAssertFalse(window.validateMenuItem(item(#selector(SessionWindowController.openWorkspaceInTerminal(_:)))))
            sidebar.select(sidebar.allSessions[1])
            XCTAssertTrue(window.validateMenuItem(item(#selector(SessionWindowController.revealWorkspace(_:)))))

            let board = NSPasteboard(name: NSPasteboard.Name("latch-test-\(UUID().uuidString)"))
            sidebar.pasteboard = board
            for target in [remoteSession as Any, sidebar.workspaces[0] as Any] {
                let items = sidebar.contextMenuItems(for: target)
                let reveal = try XCTUnwrap(items.first { $0.title.hasPrefix("Reveal") })
                let terminal = try XCTUnwrap(items.first { $0.title.hasPrefix("Open") })
                XCTAssertFalse(reveal.isEnabled)
                XCTAssertFalse(terminal.isEnabled)
                let copy = try XCTUnwrap(items.first { $0.title.hasPrefix("Copy") })
                XCTAssertTrue(copy.isEnabled)
                board.clearContents()
                _ = copy.target?.perform(copy.action, with: copy)
                XCTAssertEqual(board.string(forType: .string), "/srv/app")
            }
            let local = sidebar.contextMenuItems(for: sidebar.allSessions[1])
            XCTAssertTrue(try XCTUnwrap(local.first { $0.title.hasPrefix("Reveal") }).isEnabled)
            let copyLocal = try XCTUnwrap(local.first { $0.title.hasPrefix("Copy") })
            _ = copyLocal.target?.perform(copyLocal.action, with: copyLocal)
            XCTAssertEqual(board.string(forType: .string), fixture.workspace.path)
        }
    }

    func testForkAndUndoCloseKeepTheSessionOnItsServer() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(remote(fixture, 1, server: vps, path: "/srv/app"),
                                                               servers: InMemoryServerStore([vps]))
            let original = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle { !original.canStop }
            window.forkSelectedSession(nil)
            let fork = try XCTUnwrap(sidebar.selectedSession)
            XCTAssertFalse(fork === original)
            XCTAssertEqual(fork.location, original.location)
            XCTAssertEqual(sidebar.workspaces.count, 1)

            window.closeSession(nil)
            XCTAssertEqual(sidebar.allSessions.count, 1)
            try XCTUnwrap(window.window?.undoManager).undo()
            XCTAssertEqual(sidebar.selectedSession?.id, fork.id)
            XCTAssertEqual(sidebar.selectedSession?.location, .remote(serverID: vps.id, path: "/srv/app"))
        }
    }

    // MARK: Launching

    func testWithoutATransportARemoteSessionFailsFastAndLaunchesNothingHere() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(remote(fixture, 1, server: vps, path: "/srv/app"),
                                                          servers: InMemoryServerStore([vps]))
            let session = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle { session.model.errorMessage != nil && !session.canStop }
            XCTAssertEqual(session.model.phase, .disconnected)
            XCTAssertEqual(session.model.status, "Saved · Resume failed")
            XCTAssertEqual(session.model.errorMessage, "Not connected.")
            XCTAssertTrue(session.model.errorIsConnectionFailure)
            XCTAssertEqual(session.model.serviceTransportDescription, "remote (not connected)")
            XCTAssertEqual(session.banner.displayedTitle, "Can’t connect to vps", "The server is named, not the agent")
            XCTAssertEqual(session.banner.displayedActions, ["Retry", "Server Settings…"])
        }
    }

    func testTheConnectorGetsTheServerPathAndAgent() async throws {
        try await WindowFixture.run { fixture in
            let connector = RecordingConnector(acceptsImages: false)
            var saved = remote(fixture, 1, server: vps, path: "/srv/app")
            saved.agentID = AgentPreset.custom.rawValue
            let (_, sidebar) = try await fixture.restored(saved, servers: InMemoryServerStore([vps]),
                                                          remoteConnector: connector)
            let session = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle { session.model.phase == .ready }
            XCTAssertEqual(connector.serverIDs, [vps.id])
            XCTAssertEqual(connector.client.launches, [.remote(agent: .custom("my-agent --acp"), path: "/srv/app")])
            // The session is resumed in the server's folder, with nothing resolved on this Mac.
            XCTAssertEqual(connector.client.sessionFolders, ["/srv/app"])
            XCTAssertEqual(session.model.serviceTransportDescription, "remote test double")
        }
    }

    func testTheAgentMenuOffersPresetsWithoutLocalBadgesAndCustomOnlyWithACommand() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(
                remote(fixture, 1, server: vps, path: "/srv/app", messages: false),
                remote(fixture, 2, server: mini, path: "/srv/app", messages: false),
                servers: InMemoryServerStore([vps, mini]))
            let onVPS = sidebar.allSessions[0].harnessSelection
            XCTAssertEqual(onVPS.rows.map(\.preset), AgentPreset.allCases)
            XCTAssertEqual(Set(onVPS.rows.map(\.detail)), ["Runs on vps"])
            XCTAssertNil(onVPS.problem)
            let onMini = sidebar.allSessions[1].harnessSelection
            XCTAssertEqual(onMini.rows.map(\.preset), AgentPreset.allCases.filter { $0 != .custom })
        }
    }

    func testAPresetSwitchedOffOnThisMacIsStillOfferedOnAServer() async throws {
        try await WindowFixture.run { fixture in
            let settings = AgentSettings(defaults: UserDefaults(suiteName: "LatchRemote-\(UUID().uuidString)")!)
            settings.setEnabled(false, for: .openCode)
            settings.setEnabled(false, for: .fx)
            let (window, sidebar) = try await fixture.restored(
                remote(fixture, 1, server: vps, path: "/srv/app", messages: false), fixture.session(2, messages: false),
                settings: settings, servers: InMemoryServerStore([vps]))
            XCTAssertEqual(sidebar.allSessions[0].harnessSelection.rows.map(\.preset), AgentPreset.allCases)
            XCTAssertFalse(sidebar.allSessions[1].harnessSelection.rows.contains { $0.preset == .openCode },
                           "This Mac's switches still apply to its own sessions")
            sidebar.select(sidebar.allSessions[0])
            XCTAssertTrue(window.harnessMenu.items.contains { $0.title == "Server Settings…" })
            sidebar.select(sidebar.allSessions[1])
            XCTAssertTrue(window.harnessMenu.items.contains { $0.title == "Agent Settings…" })
        }
    }

    // MARK: Attachments

    private func prompt(of session: SessionViewController, _ fixture: WindowFixture) throws -> ChatInputView {
        try fixture.control(in: session.view, label: "Message to agent")
    }

    private func pngPasteboard() throws -> NSPasteboard {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let board = NSPasteboard(name: NSPasteboard.Name("latch-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        return board
    }

    func testARemoteSessionRefusesFilesAndFoldersWhetherPastedOrDropped() async throws {
        try await WindowFixture.run { fixture in
            let connector = RecordingConnector(acceptsImages: true)
            let (_, sidebar) = try await fixture.restored(remote(fixture, 1, server: vps, path: "/srv/app"),
                                                          servers: InMemoryServerStore([vps]), remoteConnector: connector)
            let session = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle { session.model.phase == .ready }
            XCTAssertTrue(session.model.acceptsImages)
            let field = try prompt(of: session, fixture)
            let file = try fixture.makeFile("notes.txt")
            let folder = try fixture.makeFolder("docs")

            let files = NSPasteboard(name: NSPasteboard.Name("latch-test-\(UUID().uuidString)"))
            files.clearContents()
            files.writeObjects([file as NSURL, folder as NSURL])
            let draft = field.string
            field.pasteSource = files
            field.paste(nil)
            XCTAssertTrue(session.attachments.isEmpty)
            XCTAssertEqual(field.string, draft, "A refused file is not pasted as its path either")
            XCTAssertEqual(session.banner.displayedTitle, "Only images can be sent to a remote agent.")
            XCTAssertFalse(session.banner.isHidden)

            XCTAssertTrue(field.performDragOperation(DragStub(urls: [file, folder])))
            XCTAssertTrue(session.attachments.isEmpty)

            // An image goes, to an agent that takes images.
            field.pasteSource = try pngPasteboard()
            field.paste(nil)
            XCTAssertEqual(session.attachments.count, 1)
            XCTAssertTrue(session.banner.isHidden || session.banner.displayedTitle != ComposerAttachment.remoteRefusal)
        }
    }

    func testARemoteAgentWithoutImageSupportGetsNoImagesEither() async throws {
        try await WindowFixture.run { fixture in
            let connector = RecordingConnector(acceptsImages: false)
            let (_, sidebar) = try await fixture.restored(remote(fixture, 1, server: vps, path: "/srv/app"),
                                                          servers: InMemoryServerStore([vps]), remoteConnector: connector)
            let session = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle { session.model.phase == .ready }
            let field = try prompt(of: session, fixture)
            field.pasteSource = try pngPasteboard()
            field.paste(nil)
            XCTAssertTrue(session.attachments.isEmpty)
            XCTAssertEqual(session.banner.displayedTitle, "Claude Code on vps can’t receive images.")

            // The model holds the same line if an image reaches it anyway, and says nothing
            // that would offer a Retry.
            let image = try XCTUnwrap(ComposerAttachment.attachments(from: try pngPasteboard()).first)
            await session.model.send("", attachments: [image])
            XCTAssertNil(session.model.errorMessage)
            XCTAssertEqual(session.model.phase, .ready)
            XCTAssertTrue(connector.prompts.isEmpty)
        }
    }

    func testAnImageAddedBeforeTheAgentAnswersIsCheckedWhenTheDraftIsSent() async throws {
        try await WindowFixture.run { fixture in
            let connector = RecordingConnector(acceptsImages: false)
            connector.client.holdLaunch = true
            let (_, sidebar) = try await fixture.restored(remote(fixture, 1, server: vps, path: "/srv/app"),
                                                          servers: InMemoryServerStore([vps]), remoteConnector: connector)
            let session = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle { session.model.phase == .connecting }
            let field = try prompt(of: session, fixture)
            field.pasteSource = try pngPasteboard()
            field.paste(nil)
            XCTAssertEqual(session.attachments.count, 1, "Whether the agent takes images is not known yet")

            connector.client.releaseLaunch()
            try await fixture.settle { session.model.phase == .ready }
            field.string = "What is in this picture?"
            field.onSubmit?()
            try await fixture.settle { session.attachments.isEmpty }
            XCTAssertEqual(field.string, "What is in this picture?", "The draft stays for sending without the image")
            XCTAssertEqual(session.banner.displayedTitle, "Claude Code on vps can’t receive images.")
            XCTAssertTrue(connector.prompts.isEmpty)
        }
    }

    func testARefusedAttachmentNeverHidesAConnectionFailure() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(remote(fixture, 1, server: vps, path: "/srv/app"),
                                                          servers: InMemoryServerStore([vps]))
            let session = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle { session.model.errorMessage != nil && !session.canStop }
            let field = try prompt(of: session, fixture)
            let files = NSPasteboard(name: NSPasteboard.Name("latch-test-\(UUID().uuidString)"))
            files.clearContents()
            files.writeObjects([try fixture.makeFile("notes.txt") as NSURL])
            field.pasteSource = files
            field.paste(nil)
            XCTAssertTrue(session.attachments.isEmpty)
            XCTAssertEqual(session.banner.displayedTitle, "Can’t connect to vps")
            XCTAssertEqual(session.banner.displayedActions, ["Retry", "Server Settings…"])
        }
    }

    func testADismissedRefusalLeavesRoomForTheNextFailure() async throws {
        try await WindowFixture.run { fixture in
            let connector = RecordingConnector(acceptsImages: true)
            let (_, sidebar) = try await fixture.restored(remote(fixture, 1, server: vps, path: "/srv/app"),
                                                          servers: InMemoryServerStore([vps]), remoteConnector: connector)
            let session = try XCTUnwrap(sidebar.selectedSession)
            try await fixture.settle { session.model.phase == .ready }
            let field = try prompt(of: session, fixture)
            XCTAssertTrue(field.performDragOperation(DragStub(urls: [try fixture.makeFile("notes.txt")])))
            XCTAssertEqual(session.banner.displayedTitle, ComposerAttachment.remoteRefusal)
            session.banner.performDismissForSmokeTest()
            XCTAssertTrue(session.banner.isHidden)

            connector.client.endRuntime()
            try await fixture.settle { session.model.phase == .disconnected }
            XCTAssertFalse(session.banner.isHidden)
            XCTAssertEqual(session.banner.displayedTitle, "Claude Code can’t start on vps")
            XCTAssertEqual(session.banner.displayedActions, ["Retry", "Server Settings…"])
        }
    }

    func testALocalSessionStillAttachesFiles() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(fixture.session(1))
            let session = try XCTUnwrap(sidebar.selectedSession)
            let field = try prompt(of: session, fixture)
            let files = NSPasteboard(name: NSPasteboard.Name("latch-test-\(UUID().uuidString)"))
            files.clearContents()
            files.writeObjects([try fixture.makeFile("notes.txt") as NSURL])
            field.pasteSource = files
            field.paste(nil)
            XCTAssertEqual(session.attachments.map(\.name), ["notes.txt"])
        }
    }

    // MARK: New Remote Session

    func testNewRemoteSessionNeedsAServer() async throws {
        try await WindowFixture.run { fixture in
            let servers = InMemoryServerStore()
            let window = fixture.window(servers: servers, serverCheck: home("/home/me"))
            let command = item(#selector(SessionWindowController.newRemoteSession(_:)))
            XCTAssertFalse(window.validateMenuItem(command))
            try servers.save(vps)
            XCTAssertFalse(window.validateMenuItem(command), "Not before saved sessions are restored")
            await window.restoreSessions(launchEnvironment: fixture.environment)
            XCTAssertTrue(window.validateMenuItem(command))
        }
    }

    func testNewRemoteSessionCreatesASessionOnTheChosenServerFolderAndAgent() async throws {
        try await WindowFixture.run { fixture in
            let window = fixture.window(servers: InMemoryServerStore([mini, vps]), serverCheck: { options in
                LatchRemoteServerInfo(version: "0.2.0", hostname: options.host, os: "Linux", arch: "arm64",
                                      home: options.host == "100.64.0.2" ? "/home/mini" : "/home/vps")
            })
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let sidebar = try fixture.sidebar(in: window)

            window.newRemoteSession(nil)
            let sheet = try XCTUnwrap(window.remoteSessionSheet)
            await sheet.homeFetched()
            XCTAssertEqual(sheet.pathField.stringValue, "/home/mini")
            XCTAssertFalse(sheet.agentPopUp.itemTitles.contains(AgentPreset.custom.title),
                           "mini has no custom command")

            sheet.selectServer(at: 1)
            await sheet.homeFetched()
            XCTAssertEqual(sheet.pathField.stringValue, "/home/vps")
            XCTAssertEqual(sheet.agentPopUp.itemTitles, AgentPreset.allCases.map(\.title))
            sheet.pathField.stringValue = "/home/vps/app"
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.pathField))
            sheet.agentPopUp.selectItem(withTitle: AgentPreset.codex.title)
            sheet.create()

            XCTAssertNil(window.remoteSessionSheet)
            let session = try XCTUnwrap(sidebar.selectedSession)
            XCTAssertEqual(session.location, .remote(serverID: vps.id, path: "/home/vps/app"))
            XCTAssertEqual(session.savedSession.agentID, AgentPreset.codex.rawValue)
            XCTAssertEqual(session.savedSession.serverID, vps.id)
            XCTAssertEqual(window.harnessTitle, AgentPreset.codex.title)
            XCTAssertEqual(window.window?.subtitle, "vps · /home/vps/app")
            XCTAssertEqual(sidebar.workspaces.map { sidebar.groupTitle($0.location).name }, ["vps · app"])
            XCTAssertTrue(NSDocumentController.shared.recentDocumentURLs.allSatisfy { $0.path != "/home/vps/app" })
        }
    }

    func testALongServerNameDoesNotWidenTheSheet() throws {
        let long = ServerProfile(name: "a-very-long-server-name-for-truncation-checks",
                                 host: "fd7a:115c:a1e0:ab12:4843:cd96:6258:b240", port: 9000, token: LatchRemoteToken.generate())
        let short = NewRemoteSessionController(servers: [vps], check: home("/home/me"))
        let sheet = NewRemoteSessionController(servers: [long], check: home("/home/me"))
        let width = try XCTUnwrap(sheet.window?.frame.width)
        XCTAssertEqual(width, try XCTUnwrap(short.window?.frame.width), accuracy: 1)
        XCTAssertLessThan(width, 500)
    }

    func testAnUnreachableServerLeavesTheHomeShorthand() async throws {
        try await WindowFixture.run { fixture in
            let window = fixture.window(servers: InMemoryServerStore([vps]),
                                        serverCheck: { _ in throw LatchRemoteClientError.connectionLost })
            await window.restoreSessions(launchEnvironment: fixture.environment)
            window.newRemoteSession(nil)
            let sheet = try XCTUnwrap(window.remoteSessionSheet)
            await sheet.homeFetched()
            XCTAssertEqual(sheet.pathField.stringValue, "~")
            XCTAssertTrue(sheet.canCreate)
            sheet.cancel()
            XCTAssertNil(window.remoteSessionSheet)
            XCTAssertTrue(try fixture.sidebar(in: window).allSessions.isEmpty)
        }
    }
}

/// Stands in for stage 6b's transport: hands out a scripted channel that records what it was
/// asked to launch, so nothing runs on this Mac or on a network.
@MainActor
private final class RecordingConnector: RemoteSessionConnector {
    let client: ScriptedRemoteClient
    private(set) var serverIDs: [UUID] = []
    var prompts: [[ACPPromptBlock]] { client.prompts }

    init(acceptsImages: Bool) { client = ScriptedRemoteClient(acceptsImages: acceptsImages) }

    func makeClient(serverID: UUID) -> AgentServiceClient {
        serverIDs.append(serverID)
        return client
    }
}

private final class ScriptedRemoteClient: AgentServiceClient {
    let events: AsyncStream<LatchAgentEvent>
    private let continuation: AsyncStream<LatchAgentEvent>.Continuation
    private let acceptsImages: Bool
    private let recorded = Mutex<[[ACPPromptBlock]]>([])
    private let launched = Mutex<[AgentLaunch]>([])
    private let folders = Mutex<[String]>([])
    private let runtimeIDs = Mutex<[AgentRuntimeID]>([])
    private let held = Mutex<(hold: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    init(acceptsImages: Bool) {
        self.acceptsImages = acceptsImages
        (events, continuation) = AsyncStream.makeStream()
    }

    var prompts: [[ACPPromptBlock]] { recorded.withLock { $0 } }
    var launches: [AgentLaunch] { launched.withLock { $0 } }
    var sessionFolders: [String] { folders.withLock { $0 } }

    /// Keeps the next launch waiting until `releaseLaunch`, so a test can act while connecting.
    var holdLaunch: Bool {
        get { held.withLock { $0.hold } }
        set { held.withLock { $0.hold = newValue } }
    }

    func releaseLaunch() {
        let waiter = held.withLock { state in
            state.hold = false
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Ends the last launched runtime, as an agent that exits does.
    func endRuntime() {
        guard let id = runtimeIDs.withLock({ $0.last }) else { return }
        continuation.yield(.processTerminated(runtimeID: id, status: 1))
    }

    func launch(_ launch: AgentLaunch, id: AgentRuntimeID) async throws -> LatchAgentResponse {
        launched.withLock { $0.append(launch) }
        runtimeIDs.withLock { $0.append(id) }
        await withCheckedContinuation { continuation in
            let waiting = held.withLock { state in
                guard state.hold else { return false }
                state.waiter = continuation
                return true
            }
            if !waiting { continuation.resume() }
        }
        return .runtimeStarted(runtimeID: id, initialization: ACPInitializeResponse(protocolVersion: 1, agentCapabilities: .init(
            loadSession: true, promptCapabilities: .object(["image": .bool(acceptsImages)]))))
    }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        switch command {
        case let .newSession(id, cwd):
            folders.withLock { $0.append(cwd) }
            return .sessionCreated(runtimeID: id, session: ACPNewSessionResponse(sessionId: "remote-session"))
        case let .loadSession(id, _, cwd):
            folders.withLock { $0.append(cwd) }
            return .sessionLoaded(runtimeID: id, response: ACPLoadSessionResponse())
        case let .prompt(id, blocks):
            recorded.withLock { $0.append(blocks) }
            return .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn"))
        case let .stopRuntime(id):
            return .runtimeStopped(runtimeID: id)
        default:
            throw LatchAgentFailure(code: .commandFailed, message: "Unexpected command")
        }
    }

    func close() { continuation.finish() }

    var transportDescription: String { "remote test double" }
}
