import Foundation
import XCTest
@testable import LatchMacUI

final class AgentPresetTests: XCTestCase {
    func testClaudeFallbackUsesMaintainedPinnedAdapter() throws {
        let environment = AgentLaunchEnvironment(environment: [:], includeCommonLocations: false)
        let recipe = try XCTUnwrap(AgentPreset.claudeCode.recipe(in: environment))
        XCTAssertEqual(recipe.command, "npx --yes @agentclientprotocol/claude-agent-acp@0.76.0")
        XCTAssertTrue(recipe.requiresNode)
        XCTAssertTrue(recipe.setup.contains("Node.js 22+"))
    }

    func testCodexFallbackIsPinnedAndPrerequisitesAreActionable() throws {
        let environment = AgentLaunchEnvironment(environment: [:], includeCommonLocations: false)
        let recipe = try XCTUnwrap(AgentPreset.codex.recipe(in: environment))
        XCTAssertEqual(recipe.command, "npx --yes @agentclientprotocol/codex-acp@1.7.0")
        XCTAssertTrue(recipe.requiresNode)
        XCTAssertEqual(recipe.problem(in: environment), "Install Node.js 22+ with npm, then select this agent again.")
        for preset in AgentPreset.allCases {
            let setup = preset.recipe(in: environment)?.setup ?? ""
            XCTAssertFalse(setup.lowercased().contains("adapter"))
            XCTAssertFalse(setup.contains("@agentclientprotocol"))
        }
        XCTAssertNil(AgentPreset.custom.recipe(in: environment))
        XCTAssertEqual(AgentPreset.suggested(in: environment), .fx)
    }

    func testDiscoveryPrefersInstalledBuiltInWithoutExecutingIt() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("latch-presets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = AgentLaunchEnvironment(environment: ["PATH": directory.path], includeCommonLocations: false)
        for name in ["node", "npx", "codex", "opencode", "fx"] {
            let file = directory.appendingPathComponent(name)
            try Data("Not executable content: discovery must only inspect files".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            if name == "npx" {
                XCTAssertNil(AgentPreset.codex.recipe(in: environment)?.problem(in: environment))
            }
            if name == "codex" { XCTAssertEqual(AgentPreset.suggested(in: environment), .codex) }
            if name == "opencode" { XCTAssertEqual(AgentPreset.suggested(in: environment), .openCode) }
        }
        XCTAssertEqual(AgentPreset.suggested(in: environment), .fx)
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
        XCTAssertFalse(recipe.requiresNode)
    }
}
