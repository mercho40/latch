import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

@MainActor
final class NewSessionTests: XCTestCase {
    private let vps = Fake.server("vps")
    private let box = Fake.server("box", command: "mock-agent")

    private nonisolated static func info(_ home: String) -> LatchRemoteServerInfo {
        LatchRemoteServerInfo(version: "0.1.0", hostname: "vps", os: "Linux", arch: "x86_64", home: home)
    }

    func testTheFolderStartsAtTheServersHome() async {
        let sheet = NewSessionViewController(servers: [vps, box], check: { options in
            Self.info(options.host == "vps.example" ? "/home/simon" : "/Users/simon")
        })
        sheet.loadViewIfNeeded()
        XCTAssertTrue(sheet.isFetchingHome)
        XCTAssertFalse(sheet.createItem.isEnabled, "Nothing to create in until the folder is known")
        await sheet.homeFetched()
        XCTAssertEqual(sheet.pathField.text, "/home/simon")
        XCTAssertTrue(sheet.createItem.isEnabled)
        XCTAssertEqual(sheet.selectedAgent, .fx)

        sheet.selectServer(box.id)
        await sheet.homeFetched()
        XCTAssertEqual(sheet.pathField.text, "/Users/simon")
    }

    func testAnUnreachableServerLeavesTheHomeShorthand() async {
        let sheet = NewSessionViewController(servers: [vps], check: { _ in throw LatchRemoteClientError.timedOut })
        sheet.loadViewIfNeeded()
        await sheet.homeFetched()
        XCTAssertEqual(sheet.pathField.text, "~")
    }

    func testATypedFolderIsNotReplacedByALateHome() async {
        let sheet = NewSessionViewController(servers: [vps], check: { _ in
            try await Task.sleep(for: .milliseconds(50))
            return Self.info("/home/simon")
        })
        sheet.loadViewIfNeeded()
        sheet.pathField.text = "/srv/app"
        sheet.pathChanged()
        await sheet.homeFetched()
        XCTAssertEqual(sheet.pathField.text, "/srv/app")
        sheet.pathField.text = "  "
        sheet.pathChanged()
        XCTAssertFalse(sheet.canCreate, "A blank folder is no folder")
    }

    func testCustomIsOfferedOnlyWhereTheServerHasACommand() async throws {
        let sheet = NewSessionViewController(servers: [vps, box], check: { _ in Self.info("/h") })
        sheet.loadViewIfNeeded()
        let titles = { (sheet.agentButton.menu?.children ?? []).compactMap { ($0 as? UIAction)?.title } }
        XCTAssertEqual(titles(), ["fx", "Codex", "Claude Code", "OpenCode"])
        sheet.selectServer(box.id)
        XCTAssertEqual(titles(), ["fx", "Codex", "Claude Code", "OpenCode", "Custom"])
        sheet.selectAgent(.custom)
        sheet.selectServer(vps.id)
        XCTAssertEqual(sheet.selectedAgent, .fx, "Custom goes with the server that had it")
    }

    func testCreateHandsOverTheChoice() async {
        let sheet = NewSessionViewController(servers: [vps, box], serverID: box.id, check: { _ in Self.info("/home/me") })
        var choices: [NewSessionViewController.Choice] = []
        sheet.onCreate = { choices.append($0) }
        sheet.loadViewIfNeeded()
        await sheet.homeFetched()
        sheet.selectAgent(.claudeCode)
        sheet.pathField.text = " /home/me/app "
        sheet.pathChanged()
        sheet.create()
        XCTAssertEqual(choices, [.init(serverID: box.id, path: "/home/me/app", agent: .claudeCode)])
        sheet.create()
        XCTAssertEqual(choices.count, 1, "Once")
    }
}
