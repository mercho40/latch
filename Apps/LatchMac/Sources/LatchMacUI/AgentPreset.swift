import Foundation

/// Launch recipes only: provider authentication and policy remain owned by each agent.
enum AgentPreset: String, CaseIterable {
    case fx, codex, claudeCode, openCode, custom

    var title: String {
        switch self {
        case .fx: "fx"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        case .custom: "Custom ACP Agent"
        }
    }

    func recipe(in environment: AgentLaunchEnvironment) -> AgentLaunchRecipe? {
        switch self {
        case .fx:
            AgentLaunchRecipe(command: "fx acp", setup: "Install fx and sign in with fx login.")
        case .openCode:
            AgentLaunchRecipe(command: "opencode acp", setup: "Install OpenCode and configure its provider login.")
        case .codex:
            adapter("codex-acp", package: "@agentclientprotocol/codex-acp@1.7.0",
                    setup: "Uses the Codex ACP adapter, not the interactive codex command. Sign in with codex login.", in: environment)
        case .claudeCode:
            adapter("claude-agent-acp", package: "@agentclientprotocol/claude-agent-acp@0.76.0",
                    setup: "Uses the Claude Code ACP adapter (Node.js 22+), not the interactive claude command. Set up your Claude login first.", in: environment)
        case .custom: nil
        }
    }

    private func adapter(_ executable: String, package: String, setup: String, in environment: AgentLaunchEnvironment) -> AgentLaunchRecipe {
        if environment.executable(named: executable) != nil {
            return AgentLaunchRecipe(command: executable, setup: setup)
        }
        return AgentLaunchRecipe(command: "npx --yes \(package)", setup: setup, downloadPackage: package)
    }
}

struct AgentLaunchRecipe {
    let command: String
    let setup: String
    var downloadPackage: String? = nil

    func problem(in environment: AgentLaunchEnvironment) -> String? {
        if downloadPackage != nil, environment.executable(named: "node") == nil {
            return "Node.js is required for this adapter. Install Node.js, then click Refresh."
        }
        guard let parsed = try? AgentCommand(command), environment.executable(named: parsed.executable) != nil else {
            return "Required executable not found. \(downloadPackage == nil ? setup : "Install Node.js with npm, then click Refresh.")"
        }
        return nil
    }
}
