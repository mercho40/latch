import AppKit
import LatchAgentCore
import LatchRemoteProtocol
import XCTest
@testable import LatchMacUI
@testable import LatchSessionKit

/// Every way to start a session from the window itself, without the menu bar: the toolbar's
/// New Session menu, a workspace group's context menu, and the recent places they list.
@MainActor
final class NewSessionMenuTests: XCTestCase {
    private let vps = ServerProfile(id: UUID(uuidString: "5E4E4000-0000-0000-0000-000000000001")!,
                                    name: "vps", host: "vps.tailnet.ts.net", token: LatchRemoteToken.generate())
    private let mini = ServerProfile(id: UUID(uuidString: "5E4E4000-0000-0000-0000-000000000002")!,
                                     name: "mini", host: "100.64.0.2", token: LatchRemoteToken.generate())

    private func home(_ path: String) -> ServerCheck {
        { _ in LatchRemoteServerInfo(version: "0.2.0", hostname: "vps-1", os: "Ubuntu 24.04", arch: "x86_64", home: path) }
    }

    private func remote(_ fixture: WindowFixture, _ number: Int, server: ServerProfile, path: String) -> SavedSession {
        var saved = fixture.session(number)
        saved.workspacePath = path
        saved.serverID = server.id
        saved.agentID = AgentPreset.claudeCode.rawValue
        saved.customCommand = ""
        return saved
    }

    /// The menu as it opens: every item after the pull-down's face.
    private func titles(_ window: SessionWindowController) -> [String] {
        window.menuNeedsUpdate(window.composeMenu)
        return window.composeMenu.items.dropFirst().map { $0.isSeparatorItem ? "—" : $0.title }
    }

    func testWithNoServerTheMenuOffersAFolderHereAndAddingAServer() async throws {
        try await WindowFixture.run { fixture in
            let window = fixture.window(servers: InMemoryServerStore(), serverCheck: home("/home/me"))
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let control = window.composeControl
            XCTAssertTrue(control.pullsDown)
            let cell = try XCTUnwrap(control.cell)
            XCTAssertTrue(cell.isAccessibilityElement())
            XCTAssertEqual(cell.accessibilityRole(), .menuButton, "What VoiceOver reaches")
            XCTAssertEqual(cell.accessibilityLabel(), "New Session")
            XCTAssertEqual(titles(window), ["New Session…", "Add Server…"])
            let add = try XCTUnwrap(window.composeMenu.items.first { $0.title == "Add Server…" })
            XCTAssertEqual(add.action, #selector(LatchApplicationDelegate.addServer(_:)))
            XCTAssertNil(add.target, "Through the responder chain to the application")
            XCTAssertEqual(titles(window), ["New Session…", "Add Server…"], "Refilled, not appended to")
            XCTAssertEqual(window.composeControl.itemTitle(at: 0), "")
            XCTAssertNotNil(window.composeMenu.items.first?.image, "The face survives a refill")
        }
    }

    func testWithServersTheMenuOffersARemoteSessionAndListsRecentPlaces() async throws {
        try await WindowFixture.run { fixture in
            let window = fixture.window(servers: InMemoryServerStore([mini, vps]), serverCheck: home("/home/me"))
            await window.restoreSessions(launchEnvironment: fixture.environment)
            XCTAssertEqual(titles(window), ["New Session…", "New Remote Session…"],
                           "No row per server: the sheet already asks which")

            window.addSession(workspace: fixture.workspace, launchEnvironment: fixture.environment)
            window.addRemoteSession(serverID: vps.id, path: "/srv/app", agent: .codex)
            XCTAssertEqual(titles(window), ["New Session…", "New Remote Session…", "—", "Recent", "vps · app", "workspace"])
            let menu = window.composeMenu
            let row = try XCTUnwrap(menu.items.first { $0.title == "vps · app" })
            XCTAssertEqual(row.subtitle, "/srv")
            XCTAssertTrue(menu.items.allSatisfy { $0.keyEquivalent.isEmpty },
                          "A control's menu would perform them ahead of the main menu")

            // The place outlives its last session, and one click starts another there.
            window.closeSession(nil)
            let sidebar = try fixture.sidebar(in: window)
            XCTAssertFalse(sidebar.allSessions.contains { $0.location.isRemote })
            window.menuNeedsUpdate(menu)
            let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "vps · app" })
            menu.performActionForItem(at: index)
            let session = try XCTUnwrap(sidebar.selectedSession)
            XCTAssertEqual(session.location, .remote(serverID: vps.id, path: "/srv/app"))
            XCTAssertEqual(session.savedSession.agentID, AgentPreset.codex.rawValue)

            let remote = try XCTUnwrap(menu.items.firstIndex { $0.title == "New Remote Session…" })
            menu.performActionForItem(at: remote)
            let sheet = try XCTUnwrap(window.remoteSessionSheet)
            XCTAssertEqual(sheet.selectedServer, vps)
            sheet.cancel()
        }
    }

    func testTheOverflowFormOffersTheSameCommands() async throws {
        try await WindowFixture.run { fixture in
            let window = fixture.window(servers: InMemoryServerStore([vps]), serverCheck: home("/home/me"))
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let form = try XCTUnwrap(window.composeMenuForm?.submenu)
            window.menuNeedsUpdate(form)
            XCTAssertEqual(form.items.map(\.title), ["New Session…", "New Remote Session…"])
            XCTAssertTrue(form.items.allSatisfy { $0.keyEquivalent.isEmpty })
        }
    }

    func testAddingAServerTurnsAddServerIntoNewRemoteSession() async throws {
        try await WindowFixture.run { fixture in
            let servers = InMemoryServerStore()
            let window = fixture.window(servers: servers, serverCheck: home("/home/me"))
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let detail = try XCTUnwrap(fixture.detail(in: window) as? DetailHostViewController)
            let remoteButton = { detail.start.subviews.flatMap(\.subviews).flatMap(\.subviews)
                .compactMap { $0 as? NSButton }.first { $0.title == "New Remote Session…" } }
            XCTAssertEqual(remoteButton()?.isHidden, true)
            try servers.save(vps)
            XCTAssertEqual(titles(window), ["New Session…", "New Remote Session…"])
            XCTAssertEqual(remoteButton()?.isHidden, false, "The empty window offers it once there is a server")
        }
    }

    func testAWorkspaceGroupStartsAnotherSessionThereWithoutAsking() async throws {
        try await WindowFixture.run { fixture in
            let (window, sidebar) = try await fixture.restored(
                remote(fixture, 1, server: vps, path: "/srv/app"), fixture.session(2),
                servers: InMemoryServerStore([vps]))
            let group = try XCTUnwrap(sidebar.workspaces.first { $0.location.isRemote })
            let items = sidebar.contextMenuItems(for: group)
            let new = try XCTUnwrap(items.first)
            XCTAssertEqual(new.title, "New Session in “vps · app”")
            XCTAssertTrue(new.isEnabled)
            XCTAssertTrue(items[1].isSeparatorItem)
            _ = new.target?.perform(new.action, with: new)

            XCTAssertEqual(group.sessions.count, 2)
            let session = try XCTUnwrap(sidebar.selectedSession)
            XCTAssertTrue(group.sessions.last === session)
            XCTAssertEqual(session.location, .remote(serverID: vps.id, path: "/srv/app"))
            XCTAssertEqual(session.savedSession.agentID, AgentPreset.claudeCode.rawValue)
            XCTAssertTrue(session.model.messages.isEmpty)
            XCTAssertEqual(window.recents.entries.first?.location, .remote(serverID: vps.id, path: "/srv/app"))

            let local = try XCTUnwrap(sidebar.workspaces.first { !$0.location.isRemote })
            let template = try XCTUnwrap(local.sessions.first)
            let here = try XCTUnwrap(sidebar.contextMenuItems(for: local).first)
            XCTAssertEqual(here.title, "New Session in “workspace”")
            _ = here.target?.perform(here.action, with: here)
            let made = try XCTUnwrap(sidebar.selectedSession)
            XCTAssertEqual(local.sessions.count, 2)
            XCTAssertEqual(made.location.groupKey, template.location.groupKey)
            XCTAssertEqual(made.savedSession.agentID, template.savedSession.agentID)
            XCTAssertNotNil(made.injectedEnvironment, "Started where its group's sessions start")
        }
    }

    func testARemovedServersGroupCannotStartAnother() async throws {
        try await WindowFixture.run { fixture in
            let (_, sidebar) = try await fixture.restored(remote(fixture, 1, server: vps, path: "/srv/app"),
                                                          servers: InMemoryServerStore())
            let group = try XCTUnwrap(sidebar.workspaces.first)
            let new = try XCTUnwrap(sidebar.contextMenuItems(for: group).first)
            XCTAssertEqual(new.title, "New Session in “Removed server · app”")
            XCTAssertFalse(new.isEnabled)
        }
    }

    func testARecentServerFolderStartsOnTheAgentLastStartedThere() async throws {
        try await WindowFixture.run { fixture in
            let window = fixture.window(servers: InMemoryServerStore([vps]), serverCheck: home("/home/me"))
            await window.restoreSessions(launchEnvironment: fixture.environment)
            let sidebar = try fixture.sidebar(in: window)
            let detail = try XCTUnwrap(fixture.detail(in: window) as? DetailHostViewController)
            window.addRemoteSession(serverID: vps.id, path: "/srv/app", agent: .fx)
            window.chooseHarnessFromToolbar(.claudeCode)
            XCTAssertEqual(window.recents.entries.first?.agent, AgentPreset.claudeCode.rawValue,
                           "Switched in place before any conversation")

            window.closeSession(nil)
            XCTAssertEqual(detail.start.shownRecents.map(\.location), [.remote(serverID: vps.id, path: "/srv/app")])
            window.startSession(at: try XCTUnwrap(window.recentPlaces(limit: 1).first))
            XCTAssertEqual(sidebar.selectedSession?.savedSession.agentID, AgentPreset.claudeCode.rawValue)

            window.closeSession(nil)
            window.clearRecentPlaces()
            XCTAssertTrue(detail.start.shownRecents.isEmpty, "The empty window forgets them with the menu")
        }
    }

    func testTheSheetSkipsARemovedServerForTheOneUsedLast() async throws {
        try await WindowFixture.run { fixture in
            let old = ServerProfile(id: UUID(uuidString: "5E4E4000-0000-0000-0000-000000000003")!,
                                    name: "old", host: "100.64.0.3", token: LatchRemoteToken.generate())
            let (window, sidebar) = try await fixture.restored(remote(fixture, 1, server: old, path: "/srv/gone"),
                                                               servers: InMemoryServerStore([mini, vps]))
            sidebar.select(sidebar.allSessions.first)
            window.recents.note(.remote(serverID: vps.id, path: "/srv/app"), agent: .codex,
                                at: Date().addingTimeInterval(-3600))
            window.newRemoteSession(nil)
            let sheet = try XCTUnwrap(window.remoteSessionSheet)
            XCTAssertEqual(sheet.selectedServer, vps, "Not mini, the first listed")
            XCTAssertEqual(sheet.selectedAgent, .codex)
            sheet.cancel()
        }
    }

    func testNothingNewStartsBehindAnOpenSheet() async throws {
        try await WindowFixture.run { fixture in
            let window = fixture.window(servers: InMemoryServerStore([vps]), serverCheck: home("/home/me"))
            await window.restoreSessions(launchEnvironment: fixture.environment)
            window.window?.orderFront(nil)
            defer { window.window?.orderOut(nil) }
            let newSession = NSMenuItem(title: "", action: #selector(SessionWindowController.newSession(_:)), keyEquivalent: "")
            let recent = NSMenuItem(title: "", action: #selector(SessionWindowController.openRecentPlace(_:)), keyEquivalent: "")
            XCTAssertTrue(window.validateMenuItem(newSession))
            window.newRemoteSession(nil)
            let sheet = try XCTUnwrap(window.remoteSessionSheet)
            XCTAssertNotNil(window.window?.attachedSheet)
            XCTAssertFalse(window.validateMenuItem(newSession))
            XCTAssertFalse(window.validateMenuItem(recent))
            sheet.cancel()
            try await fixture.settle { window.window?.attachedSheet == nil }
            XCTAssertTrue(window.validateMenuItem(newSession))
        }
    }

    func testPlacesOpenInTheSidebarJoinTheListTheFirstTimeItIsKept() async throws {
        try await WindowFixture.run { fixture in
            let suite = "LatchRecents-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let recents = RecentWorkspaces(defaults: defaults)
            recents.seedIfNeeded(from: [])
            try await fixture.store.save(SavedSessionLibrary(sessions: [remote(fixture, 1, server: vps, path: "/srv/app")],
                                                             selectedSessionID: nil))
            let window = SessionWindowController(store: SessionStore(directory: fixture.storeDirectory),
                                                 settings: AgentSettings(defaults: defaults),
                                                 servers: InMemoryServerStore([vps]), recents: recents)
            await window.restoreSessions(launchEnvironment: fixture.environment)
            XCTAssertEqual(recents.entries.map(\.location), [.remote(serverID: vps.id, path: "/srv/app")])
            XCTAssertEqual(recents.entries.first?.agent, AgentPreset.claudeCode.rawValue)
            XCTAssertFalse(recents.adoptsOpenPlaces)
            XCTAssertFalse(RecentWorkspaces(defaults: defaults).adoptsOpenPlaces)
            window.clearRecentPlaces()
            await window.shutdown()

            // As the app delegate starts every launch.
            let reopened = RecentWorkspaces(defaults: defaults)
            reopened.seedIfNeeded(from: [])
            let again = SessionWindowController(store: SessionStore(directory: fixture.storeDirectory),
                                                settings: AgentSettings(defaults: defaults),
                                                servers: InMemoryServerStore([vps]), recents: reopened)
            await again.restoreSessions(launchEnvironment: fixture.environment)
            XCTAssertTrue(again.recents.entries.isEmpty, "A later launch leaves a cleared list cleared")
            await again.shutdown()
        }
    }
}
