import AppKit
import LatchAgentCore
import XCTest
@testable import LatchMacUI
@testable import LatchSessionKit

/// Recent places, here and on servers: kept newest first, one per place, and offered only while
/// they can still be reached.
@MainActor
final class RecentWorkspacesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var root: URL!
    private let vps = UUID(uuidString: "5E4E4000-0000-0000-0000-000000000001")!
    private let mini = UUID(uuidString: "5E4E4000-0000-0000-0000-000000000002")!

    override func setUpWithError() throws {
        suite = "LatchRecents-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("latch-recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testANotedPlaceMovesToTheTopOncePerPlaceAndTheListIsCapped() throws {
        let recents = RecentWorkspaces(defaults: defaults)
        let a = try folder("a")
        recents.note(.local(a), agent: .codex)
        recents.note(.remote(serverID: vps, path: "/srv/app"), agent: .codex)
        recents.note(.remote(serverID: mini, path: "/srv/app"), agent: .claudeCode)
        recents.note(.local(a.appendingPathComponent(".")), agent: nil)
        XCTAssertEqual(recents.entries.map(\.location), [
            .local(a.standardizedFileURL), .remote(serverID: mini, path: "/srv/app"), .remote(serverID: vps, path: "/srv/app"),
        ], "The same folder written two ways is one place; the same path on two servers is two")
        XCTAssertEqual(recents.entries.map(\.agent), [nil, AgentPreset.claudeCode.rawValue, AgentPreset.codex.rawValue],
                       "Only a server's folder keeps its agent")

        for index in 0..<12 { recents.note(.remote(serverID: vps, path: "/srv/\(index)"), agent: .fx) }
        XCTAssertEqual(recents.entries.count, RecentWorkspaces.capacity)
        XCTAssertEqual(recents.entries.first?.path, "/srv/11")
    }

    func testTheListIsSavedOnlyWhereItIsGivenDefaults() {
        let saved = RecentWorkspaces(defaults: defaults)
        saved.note(.remote(serverID: vps, path: "/srv/app"), agent: .codex)
        XCTAssertEqual(RecentWorkspaces(defaults: defaults).entries, saved.entries)

        let memory = RecentWorkspaces(defaults: nil)
        memory.note(.remote(serverID: vps, path: "/srv/app"), agent: .codex)
        memory.seedIfNeeded(from: [root])
        XCTAssertEqual(memory.entries.map(\.location), [.remote(serverID: vps, path: "/srv/app")], "Never seeded")
        XCTAssertTrue(RecentWorkspaces(defaults: nil).entries.isEmpty, "A list kept in memory is not read back by the next")
    }

    func testTheSystemsRecentFoldersSeedTheListOnce() throws {
        let a = try folder("a"), b = try folder("b")
        let recents = RecentWorkspaces(defaults: defaults)
        recents.seedIfNeeded(from: [a, URL(string: "https://example.com")!, b, a])
        XCTAssertEqual(recents.entries.map(\.location), [.local(a.standardizedFileURL), .local(b.standardizedFileURL)])
        XCTAssertEqual(recents.entries.map(\.date), [.distantPast, Date.distantPast.addingTimeInterval(-1)],
                       "The system's order, below every real date")
        XCTAssertTrue(recents.adoptsOpenPlaces)
        XCTAssertTrue(RecentWorkspaces(defaults: defaults).adoptsOpenPlaces,
                      "Still to adopt if this launch never restores its sessions")
        recents.finishAdopting()

        let next = RecentWorkspaces(defaults: defaults)
        next.seedIfNeeded(from: [try folder("c")])
        XCTAssertEqual(next.entries.count, 2, "Seeded once, never again")
        XCTAssertFalse(next.adoptsOpenPlaces)

        next.clear()
        let cleared = RecentWorkspaces(defaults: defaults)
        cleared.seedIfNeeded(from: [a])
        XCTAssertTrue(cleared.entries.isEmpty, "A cleared list stays cleared")
    }

    func testAnOpenPlaceIsAdoptedByItsDate() {
        let recents = RecentWorkspaces(defaults: nil)
        let now = Date()
        recents.note(.remote(serverID: vps, path: "/old"), agent: .codex, at: now.addingTimeInterval(-100))
        recents.note(.remote(serverID: vps, path: "/new"), agent: .codex, at: now)
        recents.adopt(.remote(serverID: mini, path: "/middle"), agent: .fx, lastActive: now.addingTimeInterval(-50))
        recents.adopt(.remote(serverID: vps, path: "/new"), agent: .fx, lastActive: now.addingTimeInterval(-10))
        XCTAssertEqual(recents.entries.map(\.path), ["/new", "/middle", "/old"])
        XCTAssertEqual(recents.entries[0].agent, AgentPreset.codex.rawValue, "Listed as used later: left alone")
        XCTAssertEqual(recents.entries[0].date, now)
        recents.adopt(.remote(serverID: vps, path: "/old"), agent: .fx, lastActive: now.addingTimeInterval(10))
        XCTAssertEqual(recents.entries.map(\.path), ["/old", "/new", "/middle"], "Used since it was listed: moved up")
        XCTAssertEqual(recents.entries[0].agent, AgentPreset.fx.rawValue)
        recents.adopt(.remote(serverID: mini, path: "/never"), agent: nil, lastActive: nil)
        XCTAssertEqual(recents.entries.last?.path, "/never")
    }

    func testSeededFoldersMakeWayForThePlacesOpenInTheSidebar() throws {
        let folders = try (0..<RecentWorkspaces.capacity).map { try folder("f\($0)") }
        let recents = RecentWorkspaces(defaults: defaults)
        recents.seedIfNeeded(from: folders)
        let yesterday = Date().addingTimeInterval(-86_400)
        recents.adopt(.remote(serverID: vps, path: "/srv/app"), agent: .codex, lastActive: yesterday)
        recents.adopt(.local(folders[5]), agent: nil, lastActive: yesterday.addingTimeInterval(-60))
        XCTAssertEqual(recents.entries.count, RecentWorkspaces.capacity)
        XCTAssertEqual(recents.entries.prefix(3).map(\.location), [
            .remote(serverID: vps, path: "/srv/app"), .local(folders[5].standardizedFileURL), .local(folders[0].standardizedFileURL),
        ])
        XCTAssertEqual(recents.entries.last?.location, .local(folders[8].standardizedFileURL), "The last seeded folder goes")
    }

    func testOnlyPlacesThatCanStillBeReachedAreOffered() throws {
        let kept = try folder("kept")
        let file = root.appendingPathComponent("notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        let recents = RecentWorkspaces(defaults: nil)
        recents.note(.local(kept), agent: nil)
        recents.note(.local(root.appendingPathComponent("deleted")), agent: nil)
        recents.note(.local(file), agent: nil)
        recents.note(.remote(serverID: mini, path: "/srv/gone"), agent: .fx)
        recents.note(.remote(serverID: vps, path: "/srv/app"), agent: .codex)
        let names = [vps: "vps"]

        let places = RecentWorkspaces.places(recents.entries, serverName: { names[$0] }, limit: 5)
        XCTAssertEqual(places.map(\.location), [.remote(serverID: vps, path: "/srv/app"), .local(kept.standardizedFileURL)])
        XCTAssertEqual(RecentWorkspaces.places(recents.entries, serverName: { names[$0] }, limit: 1).count, 1)
        XCTAssertEqual(recents.entries.count, 5, "A removed server's place is skipped, not forgotten")

        let remote = places[0]
        XCTAssertEqual(remote.title, "vps · app")
        XCTAssertEqual(remote.detail, "/srv")
        XCTAssertEqual(remote.tooltip, "vps · /srv/app")
        XCTAssertEqual(remote.accessibilityLabel, "Start a session in app on vps")
        XCTAssertEqual(remote.agent, .codex)
        let local = places[1]
        XCTAssertEqual(local.title, "kept")
        XCTAssertEqual(local.detail, (kept.standardizedFileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        XCTAssertEqual(local.tooltip, kept.standardizedFileURL.path)
        XCTAssertNil(local.agent)
    }

    func testAPlaceBecomesAMenuItemWithoutAKeyEquivalent() {
        let place = RecentPlace(location: .remote(serverID: vps, path: "/srv/app"), agent: .codex, server: "vps")
        let item = place.menuItem(action: #selector(NSResponder.selectAll(_:)), target: nil)
        XCTAssertEqual(item.title, "vps · app")
        XCTAssertEqual(item.subtitle, "/srv")
        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertTrue(item.image?.isTemplate ?? false)
        XCTAssertEqual((item.representedObject as? RecentPlaceBox)?.place, place)
        let top = RecentPlace(location: .remote(serverID: vps, path: "~"), agent: nil, server: "vps")
        XCTAssertNil(top.menuItem(action: #selector(NSResponder.selectAll(_:)), target: nil).subtitle)
    }
}
