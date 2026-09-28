import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class ServerMemoryTests: XCTestCase {
    private func memory() -> ServerMemory { ServerMemory(defaults: UserDefaults(suiteName: UUID().uuidString)!) }

    func testAPathInTheHomeReadsWithATilde() {
        let home = "/home/simon"
        XCTAssertEqual(ServerMemory.displayPath("/home/simon", home: home), "~")
        XCTAssertEqual(ServerMemory.displayPath("/home/simon/latch", home: home), "~/latch")
        XCTAssertEqual(ServerMemory.displayPath("/home/simon/latch", home: "/home/simon/"), "~/latch")
        XCTAssertEqual(ServerMemory.displayPath("/home/simonx/latch", home: home), "/home/simonx/latch", "Only a whole folder")
        XCTAssertEqual(ServerMemory.displayPath("/srv/app", home: home), "/srv/app")
        XCTAssertEqual(ServerMemory.displayPath("/home/simon/latch", home: nil), "/home/simon/latch", "Unknown: in full")
        XCTAssertEqual(ServerMemory.displayPath("/", home: "/"), "/", "A root home would make every path ~")
    }

    func testATildeIsWrittenOutWithAKnownHome() {
        XCTAssertEqual(ServerMemory.expandedPath("~", home: "/home/simon"), "/home/simon")
        XCTAssertEqual(ServerMemory.expandedPath("~/latch", home: "/home/simon"), "/home/simon/latch")
        XCTAssertEqual(ServerMemory.expandedPath("~/latch", home: nil), "~/latch", "The server resolves it")
        XCTAssertEqual(ServerMemory.expandedPath("~other/x", home: "/home/simon"), "~other/x")
        XCTAssertEqual(ServerMemory.expandedPath("/srv", home: "/home/simon"), "/srv")
    }

    /// Every check any screen makes leaves the server's home, by address.
    func testACheckLeavesTheServersHome() async throws {
        let memory = memory()
        let vps = Fake.server("vps")
        let check = memory.recording { _ in
            LatchRemoteServerInfo(version: "0.1.0", hostname: "vps", os: "Linux", arch: "x86_64", home: "/home/simon")
        }
        XCTAssertNil(memory.home(for: vps))
        _ = try await check(vps.connectionOptions)
        XCTAssertEqual(memory.home(for: vps), "/home/simon")
        XCTAssertEqual(memory.displayPath("/home/simon/api", on: vps), "~/api")
        var renamed = vps
        renamed.name = "Build box"
        XCTAssertEqual(memory.home(for: renamed), "/home/simon", "The home is the machine's, whatever it is called")
    }

    func testARemovedServerIsRememberedUntilItsSessionsMove() {
        let memory = memory()
        let vps = Fake.server("vps")
        memory.recordRemoval(of: vps)
        XCTAssertEqual(memory.removedServer(id: vps.id), .init(name: "vps", address: vps.address))
        memory.forgetRemoval(of: vps.id)
        XCTAssertNil(memory.removedServer(id: vps.id))
    }

    /// Sessions a removed server left behind move to the server added in its place and
    /// reconnect to their runtimes there.
    func testSessionsMoveToAServerAddedBack() async throws {
        let old = Fake.server("vps")
        let store = InMemoryServerStore([old])
        let connector = FakeConnector()
        connector.servers = store
        let library = SessionLibrary(servers: store, connector: connector, store: nil, listRuntimes: { _ in [] })
        var removed: [ServerProfile] = []
        library.onServerRemoved = { removed.append($0) }
        let saved = SavedSession(id: UUID(), workspacePath: "/srv", title: "Left", agentID: "codex", customCommand: "",
                                 draft: "Draft", messages: [], serverID: old.id,
                                 remote: SavedSession.RemoteBinding(runtimeID: "r1", cursor: 0))
        library.add(PhoneSession(saved: saved, connector: connector))
        try store.remove(id: old.id)
        XCTAssertEqual(removed.map(\.id), [old.id])
        XCTAssertEqual(library.orphanedSessions.map(\.title), ["Left"])

        var added = Fake.server("vps")
        added.host = old.host
        try store.save(added)
        library.move(library.orphanedSessions, to: added.id)
        XCTAssertTrue(library.orphanedSessions.isEmpty)
        let moved = try XCTUnwrap(library.sessions(on: added.id).first)
        XCTAssertEqual(moved.id, saved.id)
        XCTAssertEqual(moved.draft, "Draft")
        try await eventually("the runtime to be attached again") {
            connector.clients.last?.snapshot.attaches.map(\.0) == ["r1"]
        }
    }

    func testRecentFoldersComeFromSessionsThenTheServersRuntimes() async {
        let vps = Fake.server("vps")
        let store = InMemoryServerStore([vps])
        let library = SessionLibrary(servers: store, connector: FakeConnector(), store: nil,
                                     listRuntimes: { _ in [Fake.summary(workspace: "/srv/api"), Fake.summary(workspace: "/srv/one")] })
        library.create(serverID: vps.id, path: "/srv/one", agent: .codex)
        await library.refreshRuntimes()
        XCTAssertEqual(library.recentFolders(on: vps.id), ["/srv/one", "/srv/api"])
    }
}
