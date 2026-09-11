import Foundation
import XCTest
@testable import LatchMacUI

final class AgentPresetTests: XCTestCase {
    func testClaudeFallbackUsesMaintainedPinnedAdapter() throws {
        let environment = AgentLaunchEnvironment(environment: [:], includeCommonLocations: false)
        let recipe = try XCTUnwrap(AgentPreset.claudeCode.recipe(in: environment))
        XCTAssertEqual(recipe.command, "npx --yes @agentclientprotocol/claude-agent-acp@0.76.0")
        XCTAssertEqual(recipe.downloadPackage, "@agentclientprotocol/claude-agent-acp@0.76.0")
        XCTAssertTrue(recipe.setup.contains("Node.js 22+"))
    }

    func testClaudeStillPrefersExplicitlyInstalledAdapter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude-agent-acp")
        try Data("Discovery must not execute this file".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let environment = AgentLaunchEnvironment(
            environment: ["PATH": directory.path], includeCommonLocations: false
        )
        let recipe = try XCTUnwrap(AgentPreset.claudeCode.recipe(in: environment))
        XCTAssertEqual(recipe.command, "claude-agent-acp")
        XCTAssertNil(recipe.downloadPackage)
    }
}
