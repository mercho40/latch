import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// Renders the app shell's screens to /tmp/latch-ios-b1 for design review, on whichever
/// device the tests run: light, dark, and the largest accessibility text on iPhone.
@MainActor
final class ShellSnapshotTests: XCTestCase {
    private let now = Date()
    private let vps = UIFixture.vps
    private let mini = UIFixture.mini
    private nonisolated static let info = LatchRemoteServerInfo(version: "0.1.0", hostname: "vps", os: "Ubuntu 24.04", arch: "x86_64",
                                                    home: "/home/simon")

    private var variants: [SnapshotB1.Variant] {
        SnapshotB1.device == "ipad" ? [.light, .dark] : [.light, .dark, .accessibility]
    }

    override func setUp() async throws {
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
        let library = SessionLibrary(servers: store, connector: B1Connector(), store: nil, listRuntimes: listing)
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
        return [B1.summary("a", agent: "Claude Code", workspace: "/home/simon/api", working: true),
                B1.summary("b", agent: "Codex", workspace: "/home/simon/dotfiles")]
    }

    private func expandRuntimes(_ root: RootViewController, serverID: UUID) {
        let item = SessionsViewController.Item.runtimes(serverID: serverID)
        guard let indexPath = root.sessions.dataSource.indexPath(for: item) else { return XCTFail("No runtimes group") }
        root.sessions.collectionView(root.sessions.collectionView, didSelectItemAt: indexPath)
    }

    // MARK: Screens

    func testOnboarding() async throws {
        for variant in variants {
            let (root, _) = root(servers: [], sessions: false)
            let window = SnapshotB1.window(root, variant: variant)
            await SnapshotB1.settle()
            try SnapshotB1.write(window, name: "onboarding", variant: variant)
            window.isHidden = true
        }
    }

    func testNoSessionsYet() async throws {
        let (root, _) = root(servers: [vps], sessions: false)
        let window = SnapshotB1.window(root, variant: .light)
        await SnapshotB1.settle()
        try SnapshotB1.write(window, name: "no-sessions", variant: .light)
        window.isHidden = true
    }

    func testSessionsList() async throws {
        for variant in variants {
            let (root, library) = root(servers: [vps, mini], sessions: true, listing: Self.runtimes)
            let window = SnapshotB1.window(root, variant: variant)
            await library.refreshRuntimes()
            // The list's own refresh on appearing may answer in its place.
            try await eventuallyB1("the runtimes") { !library.adoptableRuntimes(on: vps.id).isEmpty }
            expandRuntimes(root, serverID: vps.id)
            if SnapshotB1.device == "ipad", let first = library.sessions(on: vps.id).first { root.show(first) }
            await SnapshotB1.settle()
            try SnapshotB1.write(window, name: "sessions", variant: variant)
            window.isHidden = true
        }
    }

    func testRuntimesGroupCollapsed() async throws {
        let (root, library) = root(servers: [vps, mini], sessions: false, listing: Self.runtimes)
        let window = SnapshotB1.window(root, variant: .light)
        await library.refreshRuntimes()
        try await eventuallyB1("the runtimes") { !library.adoptableRuntimes(on: vps.id).isEmpty }
        await SnapshotB1.settle()
        try SnapshotB1.write(window, name: "runtimes-collapsed", variant: .light)
        window.isHidden = true
    }

    private var sheetKind: SnapshotB1.Sheet { SnapshotB1.device == "ipad" ? .form : .page(medium: false) }

    func testNewSessionSheet() async throws {
        for variant in variants {
            let (root, _) = root(servers: [vps, mini], sessions: true)
            let window = SnapshotB1.window(root, variant: variant)
            await SnapshotB1.settle()
            let sheet = try XCTUnwrap(root.newSessionSheet(serverID: vps.id))
            let kind: SnapshotB1.Sheet = SnapshotB1.device == "ipad" ? .form : .page(medium: true)
            try await SnapshotB1.writeSheet(sheet, over: window, as: kind, name: "new-session", variant: variant)
            window.isHidden = true
        }
    }

    func testServersList() async throws {
        for variant in variants {
            let slow = ServerProfile(name: "Pi", host: "pi.home.arpa", token: .generate())
            let (root, _) = root(servers: [vps, mini, slow], sessions: true, check: { options in
                if options.host == "pi.home.arpa" { try await Task.sleep(for: .seconds(30)) }
                guard options.host == "vps.tailnet.ts.net" else { throw LatchRemoteClientError.timedOut }
                return ShellSnapshotTests.info
            })
            let window = SnapshotB1.window(root, variant: variant)
            await SnapshotB1.settle()
            try await SnapshotB1.writeSheet(root.serversSheet(), over: window, as: sheetKind, name: "servers",
                                            variant: variant) { sheet in
                let list = (sheet as? UINavigationController)?.topViewController as? ServersViewController
                list?.beginAppearanceTransition(true, animated: false)
                list?.endAppearanceTransition()
            }
            window.isHidden = true
        }
    }

    func testServerEditorAdding() async throws {
        for variant in variants {
            let (root, _) = root(servers: [vps], sessions: true)
            let window = SnapshotB1.window(root, variant: variant)
            await SnapshotB1.settle()
            try await SnapshotB1.writeSheet(root.serverEditorSheet(), over: window, as: sheetKind, name: "server-add",
                                            variant: variant) { sheet in
                guard let editor = (sheet as? UINavigationController)?.topViewController as? ServerEditorViewController
                else { return XCTFail("No editor") }
                editor.applyPairing("latch://mini.tailnet.ts.net:7800?token=\(LatchRemoteToken.generate().rawValue)")
                editor.testConnection()
                await editor.testFinished()
            }
            window.isHidden = true
        }
    }

    func testServerEditorEditing() async throws {
        for variant in variants {
            let (root, _) = root(servers: [vps], sessions: true, check: { _ in
                throw LatchRemoteClientError.destinationNotAllowed(address: "203.0.113.7")
            })
            let window = SnapshotB1.window(root, variant: variant)
            await SnapshotB1.settle()
            try await SnapshotB1.writeSheet(root.serverEditorSheet(serverID: vps.id), over: window, as: sheetKind,
                                            name: "server-edit", variant: variant) { sheet in
                guard let editor = (sheet as? UINavigationController)?.topViewController as? ServerEditorViewController
                else { return XCTFail("No editor") }
                editor.testConnection()
                await editor.testFinished()
                let table = editor.tableView!
                table.layoutIfNeeded()
                table.setContentOffset(CGPoint(x: 0, y: max(0, table.contentSize.height - table.bounds.height
                    + table.adjustedContentInset.bottom)), animated: false)
            }
            window.isHidden = true
        }
    }

    func testAttentionBanner() async throws {
        for variant in [SnapshotB1.Variant.light, .dark] {
            let (root, library) = root(servers: [vps, mini], sessions: true)
            let window = SnapshotB1.window(root, variant: variant)
            await SnapshotB1.settle()
            let session = try XCTUnwrap(library.sessions(on: vps.id).dropFirst().first)
            library.onAttention?(session, .needsApproval)
            await SnapshotB1.settle()
            XCTAssertNotNil(root.attentionBanner)
            try SnapshotB1.write(window, name: "banner", variant: variant)
            window.isHidden = true
        }
    }
}
