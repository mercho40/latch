import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest
@testable import LatchAgentServer

final class RemoteAgentLaunchTests: XCTestCase {
    func testPresetsResolveAgainstTheServersEnvironment() async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("latch-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let environment: @Sendable () -> AgentLaunchEnvironment = {
            AgentLaunchEnvironment(environment: ["PATH": bin.path], home: bin, includeCommonLocations: false)
        }
        try await withTestbed(launchEnvironment: environment) { bed in
            let workspace = bed.workspace.path
            let unknown = try await bed.failure(.launchAgent(runtimeID: AgentRuntimeID("a"), agent: .preset("nope"), workspace: workspace))
            XCTAssertEqual(unknown.code, .unknownPreset)
            let custom = try await bed.failure(.launchAgent(runtimeID: AgentRuntimeID("a"), agent: .preset("custom"), workspace: workspace))
            XCTAssertEqual(custom.code, .unknownPreset)

            let missing = try await bed.failure(.launchAgent(runtimeID: AgentRuntimeID("a"), agent: .preset("fx"), workspace: workspace))
            XCTAssertEqual(missing, LatchRemoteError(code: .executableNotFound, message: try XCTUnwrap(AgentPreset.fx.recipe(in: environment())).setup))
            let node = try await bed.failure(.launchAgent(runtimeID: AgentRuntimeID("a"), agent: .preset("codex"), workspace: workspace))
            XCTAssertEqual(node.code, .nodeMissing)
            XCTAssertEqual(node.message, "Install Node.js 22+ with npm, then try again.")

            // Installing the agent on the server is all it takes; nothing is cached.
            let fx = bin.appendingPathComponent("fx")
            try "#!/bin/sh\nexec /bin/sh \(AgentCommand.quotedArgument(bed.workspace.appendingPathComponent("agent.sh").path))\n"
                .write(to: fx, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.path)
            let launched = try await bed.ok(.launchAgent(runtimeID: AgentRuntimeID("a"), agent: .preset("fx"), workspace: workspace))
            guard case let .launched(initialization) = launched else { return XCTFail("\(launched)") }
            XCTAssertEqual(initialization.agentInfo?.name, "mock-agent")
            let record = try await bed.record(AgentRuntimeID("a"))
            XCTAssertEqual(record.agentTitle, "fx")
            XCTAssertEqual(record.agent, .preset("fx"))
        }
    }

    func testCustomCommandsAndWorkspacesAreChecked() async throws {
        try await withTestbed { bed in
            let workspace = bed.workspace.path
            let id = AgentRuntimeID("custom")
            let missing = try await bed.failure(.launchAgent(runtimeID: id, agent: .custom("/nonexistent/private/agent --acp"), workspace: workspace))
            XCTAssertEqual(missing, LatchRemoteError(code: .executableNotFound, message: CommandError.executableNotFound.localizedDescription))
            try await bed.expect(.launchAgent(runtimeID: id, agent: .custom("  "), workspace: workspace), fails: .invalidRequest)
            try await bed.expect(.launchAgent(runtimeID: id, agent: .custom("bin/agent"), workspace: workspace), fails: .invalidRequest)
            try await bed.expect(.launchAgent(runtimeID: id, agent: .custom("\"open"), workspace: workspace), fails: .invalidRequest)
            try await bed.expect(.launchAgent(runtimeID: id, agent: .unknown, workspace: workspace), fails: .invalidRequest)
            try await bed.expect(.launchAgent(runtimeID: AgentRuntimeID("bad id"), agent: bed.mockAgent, workspace: workspace), fails: .invalidRequest)

            let gone = workspace + "/missing-folder"
            let noFolder = try await bed.failure(.launchAgent(runtimeID: id, agent: bed.mockAgent, workspace: gone))
            XCTAssertEqual(noFolder, LatchRemoteError(code: .workspaceNotFound, message: "There is no folder at \(gone) on the server."))
            let file = try await bed.failure(.launchAgent(runtimeID: id, agent: bed.mockAgent, workspace: workspace + "/agent.sh"))
            XCTAssertEqual(file.code, .workspaceNotFound)
            let relative = try await bed.failure(.launchAgent(runtimeID: id, agent: bed.mockAgent, workspace: "project"))
            XCTAssertEqual(relative.code, .workspaceNotFound)

            // Failed launches leave nothing behind.
            try await bed.expect(.listRuntimes, returns: .runtimes([]))
            try await bed.launch(id)
        }
    }

    func testTildeWorkspaceIsUnderTheServersHome() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("latch-home-\(UUID().uuidString)").resolvingSymlinksInPath()
        let project = home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try await withTestbed(homeDirectory: home.path) { bed in
            let id = AgentRuntimeID("home")
            try await bed.launch(id, workspace: "~/project")
            try await bed.ok(.newSession(runtimeID: id))
            // The agent ran in the expanded folder; the record keeps what the client sent.
            XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("sessions.log").path))
            let record = try await bed.record(id)
            XCTAssertEqual(record.workspace, "~/project")
            try await bed.expect(.launchAgent(runtimeID: AgentRuntimeID("elsewhere"), agent: bed.mockAgent, workspace: "~/nowhere"), fails: .workspaceNotFound)
        }
    }

    func testSignedOutAgentReportsAuthenticationRequired() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("signed-out")
            let failure = try await bed.failure(.launchAgent(runtimeID: id, agent: bed.script("signed-out.sh"), workspace: bed.workspace.path))
            XCTAssertEqual(failure.code, .authenticationRequired)
            XCTAssertEqual(failure.message, "Agent reported: Authentication required")
            try await bed.expect(.listRuntimes, returns: .runtimes([]))
        }
    }

    func testProcessFailuresAreMappedWithoutNativeDetail() {
        XCTAssertEqual(
            RemoteRuntimeHub.remoteError(for: CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/private/secret"])),
            LatchRemoteError(code: .commandFailed, message: "Agent command failed.")
        )
        XCTAssertEqual(RemoteRuntimeHub.remoteError(for: ACPClientError.noActiveSession).code, .noSession)
        XCTAssertEqual(RemoteRuntimeHub.remoteError(for: AgentRuntimeRegistryError.invalidPermissionOption(UUID())).code, .invalidPermissionOption)
        XCTAssertEqual(
            RemoteRuntimeHub.remoteError(for: ACPJSONRPCErrorObject(code: -32000, message: "Sign in")),
            LatchRemoteError(code: .authenticationRequired, message: "Agent reported: Sign in")
        )
    }
}
