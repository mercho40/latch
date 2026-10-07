import Foundation
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest
@testable import LatchAgentServer

final class RuntimeTableTests: XCTestCase {
    private func summary(_ id: String, _ lifecycle: LatchRemoteLifecycle, turn: Bool = false, pending: Int = 0,
                         workspace: String = "/home/me/app", title: String? = nil) -> LatchRemoteRuntimeSummary {
        LatchRemoteRuntimeSummary(runtimeID: AgentRuntimeID(id), agentTitle: "Claude Code", workspace: workspace, lifecycle: lifecycle,
                                  activeTurnID: turn ? UUID() : nil, pendingPermissionCount: pending, lastSequence: 0, title: title)
    }

    func testTheTableSaysWhatEachAgentIsDoing() {
        let table = RuntimeTable.render([
            summary("a1", .ready, title: "Fix the login bug"),
            summary("b22", .ready, turn: true, workspace: "/srv/site"),
            summary("c3", .ready, turn: true, pending: 1),
            summary("d4", .starting),
            summary("e5", .exited),
        ], homeDirectory: "/home/me/")
        XCTAssertEqual(table, """
        ID   STATE            AGENT        WORKSPACE  TITLE
        a1   idle             Claude Code  ~/app      Fix the login bug
        b22  working          Claude Code  /srv/site
        c3   waiting for you  Claude Code  ~/app
        d4   starting         Claude Code  ~/app
        e5   exited           Claude Code  ~/app
        """)
    }

    func testFailuresSayWhatToDo() {
        let address = ServerSocketAddress(bytes: [127, 0, 0, 1], port: 7428)
        XCTAssertTrue(RuntimeTable.describe(.nothingListening, at: address, configDirectory: "/c").contains("start latch-server"))
        XCTAssertTrue(RuntimeTable.describe(.rejected(.unauthorized), at: address, configDirectory: "/c")
            .contains("refuses the token in /c: it reads another config directory"))
    }
}
