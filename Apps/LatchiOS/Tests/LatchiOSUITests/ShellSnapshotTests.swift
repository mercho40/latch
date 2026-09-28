import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// Renders the app shell's screens to /tmp/latch-ios-shell for design review, on whichever
/// device the tests run: light, dark, and an accessibility text size on iPhone. Skipped
/// unless `LATCH_SNAPSHOTS` is set.
@MainActor
final class ShellSnapshotTests: XCTestCase {
    private static let task = "shell"
    private let now = Date()
    private let vps = UIFixture.vps
    private let mini = UIFixture.mini
    private nonisolated static let info = LatchRemoteServerInfo(version: "0.1.0", hostname: "vps", os: "Ubuntu 24.04", arch: "x86_64",
                                                    home: "/home/simon")

    private var appearances: [Snapshot.Appearance] {
        Snapshot.deviceName == "ipad" ? [.light, .dark] : [.light, .dark, .accessibility]
    }

    override func setUp() async throws {
        try Snapshot.skipUnlessEnabled()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() async throws {
        UIView.setAnimationsEnabled(true)
    }

    // MARK: Scenes

    private func root(servers: [ServerProfile], sessions: Bool, listing: @escaping RuntimeListing = { _ in [] },
                      check: @escaping ServerCheck = { _ in ShellSnapshotTests.info })
        -> (RootViewController, SessionLibrary) {
        let store = InMemoryServerStore(servers)
        let library = SessionLibrary(servers: store, connector: FakeConnector(), store: nil, listRuntimes: listing)
        library.now = { [now] in now }
        let root = RootViewController(library: library, servers: store, check: check, badge: nil,
                                      defaults: UserDefaults(suiteName: UUID().uuidString)!)
        if sessions { populate(library) }
        return (root, library)
    }

    private func populate(_ library: SessionLibrary) {
        UIFixture.populate(library, now: now)
    }

    private static let runtimes: RuntimeListing = { options in
        guard options.host == "vps.tailnet.ts.net" else { throw LatchRemoteClientError.timedOut }
        return [Fake.summary("a", agent: "Claude Code", workspace: "/home/simon/api", working: true),
                Fake.summary("b", agent: "Codex", workspace: "/home/simon/dotfiles")]
    }

    private func expandRuntimes(_ root: RootViewController, serverID: UUID) {
        let item = SessionsViewController.Item.runtimes(serverID: serverID)
        guard let indexPath = root.sessions.dataSource.indexPath(for: item) else { return XCTFail("No runtimes group") }
        root.sessions.collectionView(root.sessions.collectionView, didSelectItemAt: indexPath)
    }

    // MARK: Screens

    func testOnboarding() async throws {
        for appearance in appearances {
            let (root, _) = root(servers: [], sessions: false)
            let window = Snapshot.host(root, appearance: appearance, navigation: false)
            await Snapshot.settle()
            try await Snapshot.write(window, task: Self.task, name: "onboarding", appearance: appearance)
            Snapshot.tearDown(window)
        }
    }

    func testNoSessionsYet() async throws {
        let (root, _) = root(servers: [vps], sessions: false)
        let window = Snapshot.host(root, appearance: .light, navigation: false)
        await Snapshot.settle()
        try await Snapshot.write(window, task: Self.task, name: "no-sessions", appearance: .light)
        Snapshot.tearDown(window)
    }

    func testSessionsList() async throws {
        for appearance in appearances {
            let (root, library) = root(servers: [vps, mini], sessions: true, listing: Self.runtimes)
            let window = Snapshot.host(root, appearance: appearance, navigation: false)
            await library.refreshRuntimes()
            // The list's own refresh on appearing may answer in its place.
            try await eventually("the runtimes") { !library.adoptableRuntimes(on: vps.id).isEmpty }
            expandRuntimes(root, serverID: vps.id)
            if Snapshot.deviceName == "ipad", let first = library.sessions(on: vps.id).first { root.show(first) }
            await Snapshot.settle()
            try await Snapshot.write(window, task: Self.task, name: "sessions", appearance: appearance)
            Snapshot.tearDown(window)
        }
    }

    func testRuntimesGroupCollapsed() async throws {
        let (root, library) = root(servers: [vps, mini], sessions: false, listing: Self.runtimes)
        let window = Snapshot.host(root, appearance: .light, navigation: false)
        await library.refreshRuntimes()
        try await eventually("the runtimes") { !library.adoptableRuntimes(on: vps.id).isEmpty }
        await Snapshot.settle()
        try await Snapshot.write(window, task: Self.task, name: "runtimes-collapsed", appearance: .light)
        Snapshot.tearDown(window)
    }

    private var sheetKind: Snapshot.Sheet { Snapshot.deviceName == "ipad" ? .form : .page(medium: false) }

    func testNewSessionSheet() async throws {
        for appearance in appearances {
            let (root, _) = root(servers: [vps, mini], sessions: true)
            let window = Snapshot.host(root, appearance: appearance, navigation: false)
            await Snapshot.settle()
            let sheet = try XCTUnwrap(root.newSessionSheet(serverID: vps.id))
            let kind: Snapshot.Sheet = Snapshot.deviceName == "ipad" ? .form : .page(medium: true)
            try await Snapshot.writeSheet(sheet, over: window, as: kind, task: Self.task, name: "new-session", appearance: appearance)
            Snapshot.tearDown(window)
        }
    }

    func testServersList() async throws {
        for appearance in appearances {
            let slow = ServerProfile(name: "Pi", host: "pi.home.arpa", token: .generate())
            let (root, _) = root(servers: [vps, mini, slow], sessions: true, check: { options in
                if options.host == "pi.home.arpa" { try await Task.sleep(for: .seconds(30)) }
                guard options.host == "vps.tailnet.ts.net" else { throw LatchRemoteClientError.timedOut }
                return ShellSnapshotTests.info
            })
            let window = Snapshot.host(root, appearance: appearance, navigation: false)
            await Snapshot.settle()
            try await Snapshot.writeSheet(root.serversSheet(), over: window, as: sheetKind, task: Self.task, name: "servers",
                                          appearance: appearance) { sheet in
                let list = (sheet as? UINavigationController)?.topViewController as? ServersViewController
                list?.beginAppearanceTransition(true, animated: false)
                list?.endAppearanceTransition()
            }
            Snapshot.tearDown(window)
        }
    }

    func testServerEditorAdding() async throws {
        for appearance in appearances {
            let (root, _) = root(servers: [vps], sessions: true)
            let window = Snapshot.host(root, appearance: appearance, navigation: false)
            await Snapshot.settle()
            try await Snapshot.writeSheet(root.serverEditorSheet(), over: window, as: sheetKind, task: Self.task, name: "server-add",
                                          appearance: appearance) { sheet in
                guard let editor = (sheet as? UINavigationController)?.topViewController as? ServerEditorViewController
                else { return XCTFail("No editor") }
                editor.applyPairing("latch://mini.tailnet.ts.net:7800?token=\(LatchRemoteToken.generate().rawValue)")
                editor.testConnection()
                await editor.testFinished()
            }
            Snapshot.tearDown(window)
        }
    }

    func testServerEditorEditing() async throws {
        for appearance in appearances {
            let (root, _) = root(servers: [vps], sessions: true, check: { _ in
                throw LatchRemoteClientError.destinationNotAllowed(address: "203.0.113.7")
            })
            let window = Snapshot.host(root, appearance: appearance, navigation: false)
            await Snapshot.settle()
            try await Snapshot.writeSheet(root.serverEditorSheet(serverID: vps.id), over: window, as: sheetKind,
                                          task: Self.task, name: "server-edit", appearance: appearance) { sheet in
                guard let editor = (sheet as? UINavigationController)?.topViewController as? ServerEditorViewController
                else { return XCTFail("No editor") }
                editor.testConnection()
                await editor.testFinished()
                let table = editor.tableView!
                table.layoutIfNeeded()
                table.setContentOffset(CGPoint(x: 0, y: max(0, table.contentSize.height - table.bounds.height
                    + table.adjustedContentInset.bottom)), animated: false)
            }
            Snapshot.tearDown(window)
        }
    }

    func testAttentionBanner() async throws {
        for appearance in [Snapshot.Appearance.light, .dark] {
            let (root, library) = root(servers: [vps, mini], sessions: true)
            let window = Snapshot.host(root, appearance: appearance, navigation: false)
            await Snapshot.settle()
            let session = try XCTUnwrap(library.sessions(on: vps.id).dropFirst().first)
            library.onAttention?(session, .needsApproval)
            await Snapshot.settle()
            XCTAssertNotNil(root.attentionBanner)
            try await Snapshot.write(window, task: Self.task, name: "banner", appearance: appearance)
            Snapshot.tearDown(window)
        }
    }
}
