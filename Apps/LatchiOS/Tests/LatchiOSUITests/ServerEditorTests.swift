import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class ServerEditorTests: XCTestCase {
    private let token = LatchRemoteToken.generate()
    private let info = LatchRemoteServerInfo(version: "0.1.0", hostname: "vps", os: "Ubuntu 24.04", arch: "arm64",
                                             home: "/home/simon")

    private func editor(_ store: InMemoryServerStore = InMemoryServerStore(), editing: ServerProfile? = nil,
                        pairing: LatchRemotePairing? = nil,
                        check: @escaping ServerCheck = { _ in throw LatchRemoteClientError.timedOut }) -> ServerEditorViewController {
        let editor = if let editing {
            ServerEditorViewController(store: store, editing: editing, pairing: pairing, check: check)
        } else {
            ServerEditorViewController(store: store, pairing: pairing, check: check)
        }
        editor.loadViewIfNeeded()
        return editor
    }

    private func type(_ text: String, into field: UITextField) {
        field.text = text
        field.sendActions(for: .editingChanged)
    }

    func testAPastedPairingStringFillsTheForm() throws {
        let editor = editor()
        XCTAssertFalse(editor.saveItem.isEnabled)
        editor.applyPairing("  latch://vps.example:7801?token=\(token.rawValue)\n")
        XCTAssertEqual(editor.hostField.text, "vps.example")
        XCTAssertEqual(editor.portField.text, "7801")
        XCTAssertEqual(editor.tokenField.text, token.rawValue)
        XCTAssertEqual(editor.nameField.text, "vps.example")
        XCTAssertEqual(editor.pasteMessage, "Filled in from the pairing string.")
        XCTAssertTrue(editor.saveItem.isEnabled)
        XCTAssertTrue(editor.tokenField.isSecureTextEntry)

        editor.applyPairing("https://example.com")
        XCTAssertEqual(editor.pasteMessage, "That is not a pairing string. It starts with latch:// and ends with the token.")
        XCTAssertEqual(editor.hostField.text, "vps.example", "A bad paste changes nothing")
    }

    /// A link has filled the form already: the sheet asks for a check and offers no Paste.
    func testAPairingLinkAsksForACheckRatherThanAPaste() throws {
        let manual = editor()
        XCTAssertFalse(manual.fromLink)
        let sections = manual.tableView.numberOfSections
        let linked = editor(pairing: try LatchRemotePairing(host: "vps.example", token: token))
        XCTAssertTrue(linked.fromLink)
        XCTAssertEqual(linked.tableView.numberOfSections, sections - 1)
        XCTAssertEqual(linked.tableView(linked.tableView, titleForHeaderInSection: 0), "Server",
                       "The note goes in the footer, in the footnote style Edit Server uses")
        let footer = linked.tableView(linked.tableView, viewForFooterInSection: 0) as? UITableViewHeaderFooterView
        XCTAssertEqual((footer?.contentConfiguration as? UIListContentConfiguration)?.text,
                       "From a pairing link. Check the host, then tap Add.")
        XCTAssertEqual(linked.hostField.text, "vps.example")
    }

    /// Opening a link connects nowhere: anyone can make one, so the host it names is reached
    /// only when the user taps Test Connection or Add. A server that answers goes by the name
    /// it gives itself.
    func testALinkIsCheckedOnlyWhenAskedAndNamedAfterTheServer() async throws {
        let checks = CheckCount()
        let linked = editor(pairing: try LatchRemotePairing(host: "vps.tailnet.ts.net", token: token), check: { [info] _ in
            await checks.add()
            return info
        })
        XCTAssertEqual(linked.nameField.text, "vps.tailnet.ts.net")
        linked.viewDidAppear(false)
        XCTAssertFalse(linked.isTesting)
        XCTAssertEqual(checks.value, 0)
        linked.testConnection()
        await linked.testFinished()
        XCTAssertEqual(checks.value, 1)
        XCTAssertEqual(linked.nameField.text, "vps")
        let footer = linked.tableView(linked.tableView, viewForFooterInSection: 0) as? UITableViewHeaderFooterView
        XCTAssertEqual((footer?.contentConfiguration as? UIListContentConfiguration)?.text,
                       "Tap Add to use this server.")
    }

    /// A reported host name is taken only when it is printable, short and not another
    /// server's name here, so a stranger's server cannot pass for one the user has.
    func testAReportedNameIsTakenOnlyWhenItIsSafe() throws {
        let store = InMemoryServerStore([ServerProfile(name: "vps", host: "vps.example", token: token)])
        let linked = editor(store, pairing: try LatchRemotePairing(host: "203.0.113.9", token: .generate()))
        XCTAssertEqual(linked.adoptableName("mini"), "mini")
        XCTAssertNil(linked.adoptableName("vps"), "Already a server's name")
        XCTAssertNil(linked.adoptableName("VPS"))
        XCTAssertNil(linked.adoptableName("v\u{202E}ps"), "Bidirectional controls are dropped, leaving another server's name")
        XCTAssertEqual(linked.adoptableName("mi\u{200B}ni\n"), "mini")
        XCTAssertEqual(linked.adoptableName("  build\u{0007}box "), "buildbox")
        XCTAssertNil(linked.adoptableName(String(repeating: "a", count: 65)))
        XCTAssertNil(linked.adoptableName("\u{202E}\u{0000}"))

        let original = try XCTUnwrap(store.servers.first)
        let editing = editor(store, editing: original)
        XCTAssertEqual(editing.adoptableName("vps"), "vps", "A server's own name")
    }

    /// From a link, a refused destination is not a reason to lift the check.
    func testALinksRefusalDoesNotOfferTheUnencryptedNetwork() async throws {
        let linked = editor(pairing: try LatchRemotePairing(host: "203.0.113.5", token: token), check: { _ in
            throw LatchRemoteClientError.destinationNotAllowed(address: "203.0.113.5")
        })
        linked.testConnection()
        await linked.testFinished()
        XCTAssertEqual(linked.testResult?.succeeded, false)
        XCTAssertEqual(linked.testResult?.text, "Latch did not send the token: 203.0.113.5 is neither this device nor on a "
            + "Tailscale network. Check the host, and that Tailscale is connected.")
    }

    func testTheNameFollowsTheHostUntilTyped() {
        let editor = editor()
        type("vps", into: editor.hostField)
        XCTAssertEqual(editor.nameField.text, "vps")
        type("Build box", into: editor.nameField)
        type("other", into: editor.hostField)
        XCTAssertEqual(editor.nameField.text, "Build box")
    }

    func testEntryProblemsAreNamed() {
        let editor = editor()
        XCTAssertEqual(editor.entry.failure, .incomplete)
        type("vps.example", into: editor.hostField)
        type(token.rawValue, into: editor.tokenField)
        XCTAssertNotNil(try? editor.entry.get())
        type("0", into: editor.portField)
        XCTAssertEqual(editor.entry.failure, .port)
        type("7800", into: editor.portField)
        type("latch_nope", into: editor.tokenField)
        XCTAssertEqual(editor.entry.failure, .token)
        type(token.rawValue, into: editor.tokenField)
        type("not a host!", into: editor.hostField)
        XCTAssertEqual(editor.entry.failure, .host)
        XCTAssertEqual(ServerEditorViewController.EntryProblem.host.text, "The host must be a DNS name or an IP address.")
    }

    func testAddingSavesANewServerWithEverySetting() throws {
        let store = InMemoryServerStore()
        let editor = editor(store)
        var saved: ServerProfile?
        editor.onSave = { saved = $0 }
        editor.applyPairing("latch://vps.example?token=\(token.rawValue)")
        editor.unencryptedSwitch.isOn = true
        type("agent acp", into: editor.commandField)
        editor.save()
        let server = try XCTUnwrap(store.servers.first)
        XCTAssertEqual(saved, server)
        XCTAssertEqual(server.host, "vps.example")
        XCTAssertEqual(server.port, LatchRemoteProtocol.defaultPort)
        XCTAssertEqual(server.token, token)
        XCTAssertTrue(server.allowUnencryptedNetwork)
        XCTAssertEqual(server.customCommand, "agent acp")
    }

    /// Editing keeps the server's ID, so its sessions stay on it, and an empty token field
    /// keeps its token.
    func testEditingKeepsTheIDAndAnEmptyTokenKeepsTheToken() throws {
        let original = ServerProfile(name: "vps", host: "vps.example", token: token, customCommand: "old")
        let store = InMemoryServerStore([original])
        let editor = editor(store, editing: original)
        XCTAssertEqual(editor.title, "Edit Server")
        XCTAssertEqual(editor.saveItem.title, "Save")
        XCTAssertEqual(editor.tokenField.text, "", "The token never shows")
        XCTAssertEqual(editor.tokenField.placeholder, "Unchanged")
        XCTAssertTrue(editor.saveItem.isEnabled)
        type("vps2.example", into: editor.hostField)
        XCTAssertEqual(editor.nameField.text, "vps", "A name of the user's own stays")
        editor.save()
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(store.servers[0].id, original.id)
        XCTAssertEqual(store.servers[0].token, token)
        XCTAssertEqual(store.servers[0].host, "vps2.example")
        XCTAssertEqual(store.servers[0].customCommand, "old")
    }

    func testALinkToAKnownServerPrefillsItsNewToken() throws {
        let original = ServerProfile(name: "Build box", host: "vps.example", token: token)
        let store = InMemoryServerStore([original])
        let fresh = LatchRemoteToken.generate()
        let editor = editor(store, editing: original, pairing: try LatchRemotePairing(host: "vps.example", token: fresh))
        XCTAssertEqual(editor.tokenField.text, fresh.rawValue)
        XCTAssertEqual(editor.nameField.text, "Build box")
        XCTAssertEqual(store.servers, [original], "Nothing is saved until Save")
        editor.save()
        XCTAssertEqual(store.servers.map(\.id), [original.id])
        XCTAssertEqual(store.servers[0].token, fresh)
    }

    func testTestConnectionSaysWhatAnswered() async throws {
        let answered = editor(check: { [info] _ in info })
        answered.applyPairing("latch://vps.example?token=\(token.rawValue)")
        answered.testConnection()
        XCTAssertTrue(answered.isTesting)
        await answered.testFinished()
        XCTAssertEqual(answered.testResult?.text, "vps · Ubuntu 24.04 · Latch 0.1.0")
        XCTAssertEqual(answered.testResult?.succeeded, true)
        // The result is a row of its own under the button, right after the server's fields.
        let table = answered.tableView!
        XCTAssertEqual(table.numberOfRows(inSection: 2), 2)
        let button = table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 0, section: 2))
        XCTAssertEqual((button?.contentConfiguration as? UIListContentConfiguration)?.text, "Test Connection")
        XCTAssertNil((button?.contentConfiguration as? UIListContentConfiguration)?.image)
        let result = table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 1, section: 2))
        XCTAssertEqual((result?.contentConfiguration as? UIListContentConfiguration)?.text, "vps · Ubuntu 24.04 · Latch 0.1.0")
        // A change to the connection makes the result stale.
        type("7801", into: answered.portField)
        XCTAssertNil(answered.testResult)
        XCTAssertEqual(table.numberOfRows(inSection: 2), 1)

        let refused = editor(check: { _ in throw LatchRemoteClientError.destinationNotAllowed(address: "203.0.113.5") })
        refused.applyPairing("latch://vps.example?token=\(token.rawValue)")
        refused.testConnection()
        await refused.testFinished()
        XCTAssertEqual(refused.testResult?.succeeded, false)
        XCTAssertTrue(refused.testResult?.text.contains("Allow unencrypted network") == true)
    }

    // MARK: Pairing links

    private func hostedRoot(_ store: any PhoneServerStore) -> (RootViewController, UIWindow) {
        let library = SessionLibrary(servers: store, connector: FakeConnector(), store: nil, listRuntimes: { _ in [] })
        let root = RootViewController(library: library, servers: store, check: { _ in throw LatchRemoteClientError.timedOut },
                                      badge: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        return (root, window)
    }

    func testALinkOpensTheEditorFilledInAndSavesNothing() throws {
        let store = InMemoryServerStore()
        let (root, window) = hostedRoot(store)
        let sheets = ServerSheets()
        sheets.rootViewController(root, didOpenPairingLink: .success(try LatchRemotePairing(host: "vps.example", token: token)))
        let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
        let editor = try XCTUnwrap(navigation.topViewController as? ServerEditorViewController)
        XCTAssertEqual(editor.hostField.text, "vps.example")
        XCTAssertEqual(editor.title, "Add Server")
        XCTAssertTrue(editor.isModalInPresentation, "A swipe does not throw it away")
        XCTAssertTrue(store.servers.isEmpty)
        window.isHidden = true
    }

    func testALinkToAKnownServerOffersToUpdateItsToken() throws {
        let existing = ServerProfile(name: "Build box", host: "VPS.example", token: token)
        let store = InMemoryServerStore([existing])
        let (root, window) = hostedRoot(store)
        ServerSheets().rootViewController(root, didOpenPairingLink: .success(
            try LatchRemotePairing(host: "vps.example", token: .generate())))
        let alert = try XCTUnwrap(root.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "“Build box” is already added")
        XCTAssertEqual(alert.actions.map(\.title), ["Update Token", "Add as New Server", "Cancel"])
        XCTAssertEqual(alert.preferredAction?.title, "Update Token")
        XCTAssertEqual(store.servers, [existing])
        window.isHidden = true
    }

    /// A server saved without its token, as after a backup restored onto a new phone, takes
    /// the link's token under its own ID rather than being added twice.
    func testALinkForAServerMissingItsTokenRestoresThatServer() throws {
        let directory = try Fake.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = InMemoryTokenVault()
        let store = KeychainServerStore(directory: directory, vault: vault)
        let original = ServerProfile(name: "Build box", host: "vps.example", port: 7801, token: token)
        try store.save(original)
        vault.removeToken(for: original.id)
        store.reload()
        let (root, window) = hostedRoot(store)
        defer { window.isHidden = true }
        let fresh = LatchRemoteToken.generate()
        ServerSheets().rootViewController(root, didOpenPairingLink: .success(
            try LatchRemotePairing(host: "VPS.example", port: 7801, token: fresh)))
        let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
        let editor = try XCTUnwrap(navigation.topViewController as? ServerEditorViewController)
        XCTAssertEqual(editor.originalID, original.id)
        XCTAssertEqual(editor.nameField.text, "Build box")
        XCTAssertEqual(editor.tokenField.text, fresh.rawValue)
        XCTAssertEqual(store.missingTokens.map(\.id), [original.id], "Nothing is saved until Save")
        editor.save()
        XCTAssertEqual(store.servers.map(\.id), [original.id])
        XCTAssertEqual(store.servers.first?.token, fresh)
        XCTAssertTrue(store.missingTokens.isEmpty)
    }

    func testABrokenLinkSaysWhy() throws {
        let (root, window) = hostedRoot(InMemoryServerStore())
        ServerSheets().rootViewController(root, didOpenPairingLink: .failure(.missingToken))
        let alert = try XCTUnwrap(root.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "This link can’t add a server")
        XCTAssertEqual(alert.message, "It has no token. Run “latch-server pair” on the server for a complete link.")
        window.isHidden = true
    }

    // MARK: The list

    func testTheServersListChecksEachServer() async throws {
        let store = InMemoryServerStore([Fake.server("vps"), Fake.server("mini")])
        let list = ServersViewController(store: store, check: { [info] options in
            guard options.host == "vps.example" else { throw LatchRemoteClientError.timedOut }
            return info
        })
        list.loadViewIfNeeded()
        list.beginAppearanceTransition(true, animated: false)
        list.endAppearanceTransition()
        await list.checksFinished()
        XCTAssertEqual(list.checks[store.servers[0].id], .reachable("vps · Ubuntu 24.04 · Latch 0.1.0"))
        guard case let .failed(_, brief)? = list.checks[store.servers[1].id] else { return XCTFail("mini should have failed") }
        XCTAssertEqual(brief, "Didn’t answer")
    }

    /// The row says why in a few words, and names the setting when one would fix it.
    func testAFailedCheckIsBriefInTheList() {
        XCTAssertEqual(ServerCheckView.brief(LatchRemoteClientError.destinationNotAllowed(address: "192.168.1.20")),
                       "Needs “Allow unencrypted network”")
        let detail = ServerCheckView.detail(address: "vps:7800", .failed("The whole sentence.", brief: "Didn’t answer"), large: false)
        XCTAssertEqual(detail.string, "vps:7800\nCan’t connect · Didn’t answer")
        XCTAssertEqual(ServerCheckView.detail(address: "vps:7800", .checking, large: false).string, "vps:7800 · Checking…")
        XCTAssertEqual(ServerCheckView.spoken(.failed("The whole sentence.", brief: "Didn’t answer")),
                       "Can’t connect. The whole sentence.")
    }

    func testRemovingAServerSaysItsSessionsWillNotReconnect() {
        let alert = ServersViewController.removalAlert(name: "vps") {}
        XCTAssertEqual(alert.title, "Remove “vps”?")
        XCTAssertTrue(alert.message?.contains("Add the server again to reconnect them") == true)
        XCTAssertTrue(alert.message?.contains("keep running") == true)
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .destructive])
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

@MainActor
private final class CheckCount {
    private(set) var value = 0
    func add() { value += 1 }
}
