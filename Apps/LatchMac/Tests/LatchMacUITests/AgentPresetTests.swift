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
        XCTAssertEqual(recipe.problem(in: environment), "Install Node.js 22+ with npm, then try again.")
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

extension AgentPresetTests {
    /// Advice under the command must be true of the state it is shown in: an installed agent is
    /// not told to install itself, and a missing one does not have its problem said twice.
    func testGuidanceMatchesReadiness() {
        let installed = AgentStatus(preset: .fx, command: "fx acp", readiness: .installed(path: "/usr/local/bin/fx"),
                                    setup: "Install fx and sign in with fx login.", signIn: "Sign in with fx login.")
        XCTAssertEqual(installed.guidance, "Sign in with fx login.")
        let missing = AgentStatus(preset: .fx, command: "fx acp",
                                  readiness: .unavailable(problem: "Install fx and sign in with fx login."),
                                  setup: "Install fx and sign in with fx login.", signIn: "Sign in with fx login.")
        XCTAssertNil(missing.guidance)
        for preset in AgentPreset.allCases {
            guard let recipe = preset.recipe(in: AgentLaunchEnvironment()) else { continue }
            XCTAssertFalse(recipe.signIn.localizedCaseInsensitiveContains("install"), "\(preset) sign-in advice mentions installing")
        }
    }
}
