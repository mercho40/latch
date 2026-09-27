import AppKit
import LatchRemoteClient
import LatchRemoteProtocol
import XCTest
@testable import LatchMacUI

@MainActor
final class ServersSettingsTests: XCTestCase {
    private let token = LatchRemoteToken.generate()

    private func edit(_ field: NSTextField, _ text: String, in sheet: AddServerController) {
        field.stringValue = text
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    // MARK: Adding

    func testPastingAPairingStringFillsTheWholeForm() throws {
        let sheet = AddServerController()
        edit(sheet.pairingField, "  latch://vps.tailnet.ts.net:9123?token=\(token.rawValue)\n", in: sheet)

        XCTAssertEqual(sheet.hostField.stringValue, "vps.tailnet.ts.net")
        XCTAssertEqual(sheet.portField.stringValue, "9123")
        XCTAssertEqual(sheet.tokenField.stringValue, token.rawValue)
        XCTAssertEqual(sheet.nameField.stringValue, "vps.tailnet.ts.net", "The name defaults to the host")
        // The token only ever sits in secure fields.
        XCTAssertTrue(sheet.pairingField.isKind(of: NSSecureTextField.self))
        XCTAssertTrue(sheet.tokenField.isKind(of: NSSecureTextField.self))

        var added: ServerProfile?
        sheet.onFinish = { added = $0 }
        sheet.add()
        let profile = try XCTUnwrap(added)
        XCTAssertEqual(profile.name, "vps.tailnet.ts.net")
        XCTAssertEqual(profile.address, "vps.tailnet.ts.net:9123")
        XCTAssertEqual(profile.token, token)
        XCTAssertFalse(profile.allowUnencryptedNetwork)
    }

    func testATypedNameSurvivesAPastedPairingString() throws {
        let sheet = AddServerController()
        edit(sheet.nameField, "Build box", in: sheet)
        edit(sheet.pairingField, "latch://[fd7a:115c:a1e0::1]?token=\(token.rawValue)", in: sheet)
        XCTAssertEqual(sheet.nameField.stringValue, "Build box")
        XCTAssertEqual(sheet.hostField.stringValue, "fd7a:115c:a1e0::1")
        XCTAssertEqual(sheet.portField.stringValue, String(LatchRemoteProtocol.defaultPort))
        guard case let .success(profile) = sheet.entry else { return XCTFail("Expected a complete entry") }
        XCTAssertEqual(profile.name, "Build box")
    }

    func testAManualEntryIsCheckedBeforeItCanBeAdded() {
        let sheet = AddServerController()
        edit(sheet.pairingField, "https://vps?token=nope", in: sheet)
        XCTAssertEqual(sheet.entry, .failure(.pairing))
        XCTAssertFalse(sheet.message.stringValue.isEmpty)
        edit(sheet.pairingField, "", in: sheet)

        edit(sheet.hostField, "vps", in: sheet)
        XCTAssertEqual(sheet.nameField.stringValue, "vps", "The name follows the host until one is typed")
        XCTAssertEqual(sheet.entry, .failure(.incomplete))
        edit(sheet.tokenField, "latch_short", in: sheet)
        XCTAssertEqual(sheet.entry, .failure(.token))
        edit(sheet.tokenField, token.rawValue, in: sheet)
        edit(sheet.portField, "70000", in: sheet)
        XCTAssertEqual(sheet.entry, .failure(.port))
        edit(sheet.portField, "7428", in: sheet)
        edit(sheet.hostField, "not a host", in: sheet)
        XCTAssertEqual(sheet.entry, .failure(.host))
        edit(sheet.hostField, "100.64.0.9", in: sheet)
        guard case let .success(profile) = sheet.entry else { return XCTFail("Expected a complete entry") }
        XCTAssertEqual(profile.address, "100.64.0.9:7428")
    }

    // MARK: Editing

    func testEditingKeepsTheServersIDAndTokenUnlessAPairingStringReplacesThem() throws {
        let server = ServerProfile(name: "Build box", host: "vps", port: 7000, token: token,
                                   allowUnencryptedNetwork: true, customCommand: "agent --acp")
        let sheet = AddServerController(editing: server)
        XCTAssertEqual(sheet.window?.title, "Edit Server")
        XCTAssertEqual(sheet.nameField.stringValue, "Build box")
        XCTAssertEqual(sheet.hostField.stringValue, "vps")
        XCTAssertEqual(sheet.portField.stringValue, "7000")
        XCTAssertEqual(sheet.tokenField.stringValue, "", "Empty means the current token")
        XCTAssertTrue(sheet.tokenField.isKind(of: NSSecureTextField.self))

        edit(sheet.hostField, "vps.tailnet.ts.net", in: sheet)
        XCTAssertEqual(sheet.nameField.stringValue, "Build box", "The server's name does not follow a new host")
        guard case let .success(moved) = sheet.entry else { return XCTFail("Expected a complete entry") }
        XCTAssertEqual(moved.id, server.id)
        XCTAssertEqual(moved.address, "vps.tailnet.ts.net:7000")
        XCTAssertEqual(moved.token, token, "The token is kept")
        XCTAssertTrue(moved.allowUnencryptedNetwork)
        XCTAssertEqual(moved.customCommand, "agent --acp")

        edit(sheet.tokenField, "latch_short", in: sheet)
        XCTAssertEqual(sheet.entry, .failure(.token), "A token typed in is checked like a new one")
        edit(sheet.tokenField, "", in: sheet)

        let rotated = LatchRemoteToken.generate()
        edit(sheet.pairingField, "latch://100.64.0.9:9123?token=\(rotated.rawValue)", in: sheet)
        var saved: ServerProfile?
        sheet.onFinish = { saved = $0 }
        sheet.add()
        let profile = try XCTUnwrap(saved)
        XCTAssertEqual(profile.id, server.id, "Sessions on the server stay on it")
        XCTAssertEqual(profile.name, "Build box")
        XCTAssertEqual(profile.address, "100.64.0.9:9123")
        XCTAssertEqual(profile.token, rotated)
        XCTAssertTrue(profile.allowUnencryptedNetwork)
        XCTAssertEqual(profile.customCommand, "agent --acp")
    }

    func testANameThatWasOnlyTheHostFollowsANewOne() {
        let sheet = AddServerController(editing: ServerProfile(name: "10.0.0.3", host: "10.0.0.3", token: token))
        edit(sheet.pairingField, "latch://vps.tailnet.ts.net:9123?token=\(LatchRemoteToken.generate().rawValue)", in: sheet)
        guard case let .success(moved) = sheet.entry else { return XCTFail("Expected a complete entry") }
        XCTAssertEqual(moved.name, "vps.tailnet.ts.net")
        XCTAssertEqual(moved.address, "vps.tailnet.ts.net:9123")
    }

    func testEditingKeepsACommandStillBeingTyped() throws {
        let server = ServerProfile(name: "vps", host: "vps", token: token)
        let (pane, store) = pane([server])
        let window = NSWindow(contentViewController: pane)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(pane.commandField))
        let editor = try XCTUnwrap(pane.commandField.currentEditor() as? NSTextView)
        editor.insertText("my-agent --acp", replacementRange: NSRange(location: 0, length: 0))

        // Edit… takes no focus, so the command field is still being edited when it opens.
        pane.editButton.performClick(nil)
        let sheet = try XCTUnwrap(pane.serverSheet)
        XCTAssertEqual(store.servers[0].customCommand, "my-agent --acp")
        edit(sheet.nameField, "renamed", in: sheet)
        sheet.add()
        XCTAssertEqual(store.servers[0].name, "renamed")
        XCTAssertEqual(store.servers[0].customCommand, "my-agent --acp")
    }

    func testServerSettingsOpensOnTheSessionsServer() {
        let first = ServerProfile(name: "vps", host: "vps", token: token)
        let second = ServerProfile(name: "mini", host: "127.0.0.1", port: 9000, token: token)
        let controller = SettingsWindowController(
            settings: AgentSettings(defaults: UserDefaults(suiteName: "LatchServers-\(UUID().uuidString)")!),
            servers: InMemoryServerStore([first, second]))
        controller.select(server: second.id)
        XCTAssertEqual(controller.selectedPane, "Servers")
        let pane = controller.contentViewController?.children.compactMap { $0 as? ServersSettingsViewController }.first
        XCTAssertEqual(pane?.selectedServer?.id, second.id)
    }

    func testEditSavesOverTheSelectedServer() throws {
        let first = ServerProfile(name: "vps", host: "vps", token: token)
        let second = ServerProfile(name: "mini", host: "127.0.0.1", port: 9000, token: token)
        let (pane, store) = pane([first, second])
        let window = NSWindow(contentViewController: pane)
        defer { window.close() }
        XCTAssertTrue(pane.editButton.isEnabled)
        pane.table.selectRowIndexes([1], byExtendingSelection: false)

        pane.editServer()
        let sheet = try XCTUnwrap(pane.serverSheet)
        XCTAssertEqual(sheet.original, second)
        edit(sheet.nameField, "Mac mini", in: sheet)
        edit(sheet.portField, "9001", in: sheet)
        sheet.add()
        XCTAssertNil(pane.serverSheet)
        XCTAssertEqual(store.servers.map(\.id), [first.id, second.id], "Changed in place, not added")
        XCTAssertEqual(store.servers[1].name, "Mac mini")
        XCTAssertEqual(store.servers[1].address, "127.0.0.1:9001")
        XCTAssertEqual(store.servers[1].token, token)
        XCTAssertEqual(store.servers[0], first)
        XCTAssertEqual(pane.selectedServer?.id, second.id)

        pane.editServer()
        try XCTUnwrap(pane.serverSheet).cancel()
        XCTAssertEqual(store.servers[1].name, "Mac mini", "Cancel changes nothing")

        store.servers.forEach { try? store.remove(id: $0.id) }
        XCTAssertFalse(pane.editButton.isEnabled)
    }

    // MARK: The pane

    private func pane(_ servers: [ServerProfile],
                      check: @escaping ServerCheck = { _ in throw LatchRemoteClientError.connectionLost })
        -> (ServersSettingsViewController, InMemoryServerStore) {
        let store = InMemoryServerStore(servers)
        let pane = ServersSettingsViewController(store: store, check: check)
        _ = pane.view
        return (pane, store)
    }

    func testTheListShowsEachServerAndEditsTheSelectedOne() throws {
        let first = ServerProfile(name: "vps", host: "vps", token: token)
        let second = ServerProfile(name: "mini", host: "127.0.0.1", port: 9000, token: token)
        let (pane, store) = pane([first, second])
        XCTAssertEqual(pane.table.numberOfRows, 2)
        XCTAssertEqual(pane.selectedServer, first)
        let row = try XCTUnwrap(pane.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertEqual(row.accessibilityLabel(), "mini, 127.0.0.1:9000")

        pane.unencryptedCheckbox.performClick(nil)
        XCTAssertEqual(store.servers[0].allowUnencryptedNetwork, true)
        pane.commandField.stringValue = "  agent --acp "
        pane.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: pane.commandField))
        XCTAssertEqual(store.servers[0].customCommand, "agent --acp")
        XCTAssertEqual(store.servers[1], second, "Only the selected server changes")

        pane.removeServer()
        XCTAssertEqual(store.servers, [second])
        XCTAssertEqual(pane.table.numberOfRows, 1)
        XCTAssertEqual(pane.selectedServer, second, "The next server takes the selection")
        XCTAssertEqual(pane.commandField.stringValue, "")
        pane.removeServer()
        XCTAssertEqual(store.servers, [])
        XCTAssertNil(pane.selectedServer)
        XCTAssertFalse(pane.removeButton.isEnabled)
        XCTAssertFalse(pane.testButton.isEnabled)
    }

    func testACommandEditStaysWithTheServerItBeganOn() throws {
        let first = ServerProfile(name: "vps", host: "vps", token: token)
        let second = ServerProfile(name: "mini", host: "127.0.0.1", port: 9000, token: token)
        let third = ServerProfile(name: "box", host: "10.0.0.3", token: token)
        let (pane, store) = pane([first, second, third])
        pane.confirmRemoval = { _, _, remove in remove() }
        let window = NSWindow(contentViewController: pane)
        defer { window.close() }
        func type(_ text: String) throws {
            XCTAssertTrue(window.makeFirstResponder(pane.commandField))
            let editor = try XCTUnwrap(pane.commandField.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }

        // Add Server… and Remove take no focus, so the selection can move under an open edit.
        try type("vps-agent --acp")
        pane.table.selectRowIndexes([1], byExtendingSelection: false)
        window.makeFirstResponder(nil)
        XCTAssertEqual(store.servers.map(\.customCommand), ["vps-agent --acp", "", ""])
        XCTAssertEqual(pane.commandField.stringValue, "", "The field shows the selected server's command again")

        // Remove saves an open edit to its own server before that server goes.
        try type("mini-agent")
        pane.removeServer()
        XCTAssertEqual(pane.selectedServer, third)
        XCTAssertEqual(store.servers.map(\.customCommand), ["vps-agent --acp", ""])
        XCTAssertEqual(pane.commandField.stringValue, "")
    }

    func testRemovingAServerIsConfirmedFirst() {
        let server = ServerProfile(name: "vps", host: "vps", token: token)
        let (pane, store) = pane([server])
        var asked: ServerProfile?
        pane.confirmRemoval = { server, _, _ in asked = server }
        pane.removeServer()
        XCTAssertEqual(asked, server)
        XCTAssertEqual(store.servers, [server], "Nothing is removed until the user agrees")
        pane.confirmRemoval = { _, _, remove in remove() }
        pane.removeServer()
        XCTAssertEqual(store.servers, [])
    }

    func testChangingAServerClearsItsLastTestResult() async {
        let server = ServerProfile(name: "vps", host: "203.0.113.4", token: token)
        let (pane, store) = pane([server]) { _ in throw LatchRemoteClientError.destinationNotAllowed(address: "203.0.113.4") }
        pane.testConnection()
        await pane.testFinished()
        XCTAssertTrue(pane.testResult.stringValue.contains("Allow unencrypted network"))
        pane.unencryptedCheckbox.performClick(nil)
        XCTAssertEqual(store.servers.first?.allowUnencryptedNetwork, true)
        XCTAssertEqual(pane.testResult.stringValue, "", "The advice no longer applies")
    }

    func testTheAddSheetGrowsForAMessageThatWraps() throws {
        let sheet = AddServerController()
        let window = try XCTUnwrap(sheet.window)
        let empty = window.frame.height
        edit(sheet.pairingField, "latch://vps", in: sheet)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, content.fittingSize.height)
        XCTAssertGreaterThan(window.frame.height, empty)
    }

    func testTestConnectionShowsTheServerOrTheFailureInPlainWords() async {
        let server = ServerProfile(name: "vps", host: "203.0.113.4", token: token)
        let (ok, _) = pane([server]) { options in
            XCTAssertEqual(options.host, "203.0.113.4")
            return LatchRemoteServerInfo(version: "0.2.0", hostname: "vps-1", os: "Ubuntu 24.04", arch: "x86_64", home: "/home/me")
        }
        ok.testConnection()
        await ok.testFinished()
        XCTAssertEqual(ok.testResult.stringValue, "vps-1 · Ubuntu 24.04 · Latch 0.2.0")

        let (refused, _) = pane([server]) { _ in throw LatchRemoteClientError.destinationNotAllowed(address: "203.0.113.4") }
        refused.testConnection()
        await refused.testFinished()
        XCTAssertTrue(refused.testResult.stringValue.contains("203.0.113.4"))
        XCTAssertTrue(refused.testResult.stringValue.contains("Tailscale"))
        XCTAssertTrue(refused.testResult.stringValue.contains("Allow unencrypted network"))

        let (unauthorized, _) = pane([server]) { _ in throw LatchRemoteClientError.unauthorized(message: "The token was not accepted.") }
        unauthorized.testConnection()
        await unauthorized.testFinished()
        XCTAssertEqual(unauthorized.testResult.stringValue, "The token was not accepted.")
    }

    func testSettingsOffersAServersPaneBesideAgents() {
        let controller = SettingsWindowController(
            settings: AgentSettings(defaults: UserDefaults(suiteName: "LatchServers-\(UUID().uuidString)")!),
            servers: InMemoryServerStore())
        XCTAssertEqual(controller.window?.title, "Agents")
        controller.select(pane: "Servers")
        XCTAssertEqual(controller.selectedPane, "Servers")
        XCTAssertEqual(controller.window?.title, "Servers", "The title follows the pane")
        let servers = controller.window?.frame.height ?? 0
        controller.select(pane: "Agents")
        XCTAssertEqual(controller.window?.title, "Agents")
        let agents = controller.window?.frame.height ?? 0
        XCTAssertNotEqual(servers, agents, "Each pane gets its own height")
    }
}
