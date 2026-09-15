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

    /// Suggestion is filesystem-only; the session controller connects the selected harness.
    static func suggested(in environment: AgentLaunchEnvironment) -> AgentPreset {
        let installed: [(AgentPreset, String)] = [
            (.fx, "fx"), (.codex, "codex-acp"), (.claudeCode, "claude-agent-acp"),
            (.openCode, "opencode"), (.codex, "codex"), (.claudeCode, "claude"),
        ]
        return installed.first { environment.executable(named: $0.1) != nil }?.0 ?? .fx
    }

    func recipe(in environment: AgentLaunchEnvironment) -> AgentLaunchRecipe? {
        switch self {
        case .fx:
            AgentLaunchRecipe(command: "fx acp", setup: "Install fx and sign in with fx login.")
        case .openCode:
            AgentLaunchRecipe(command: "opencode acp", setup: "Install OpenCode and configure its provider login.")
        case .codex:
            adapter("codex-acp", package: "@agentclientprotocol/codex-acp@1.7.0",
                    setup: "Sign in with codex login. First connection requires Node.js with npm and internet access.", in: environment)
        case .claudeCode:
            adapter("claude-agent-acp", package: "@agentclientprotocol/claude-agent-acp@0.76.0",
                    setup: "Set up your Claude login. Node.js 22+ is required; first connection needs internet access.", in: environment)
        case .custom: nil
        }
    }

    private func adapter(_ executable: String, package: String, setup: String, in environment: AgentLaunchEnvironment) -> AgentLaunchRecipe {
        if environment.executable(named: executable) != nil {
            return AgentLaunchRecipe(command: executable, setup: setup)
        }
        return AgentLaunchRecipe(command: "npx --yes \(package)", setup: setup, requiresNode: true)
    }
}

struct AgentLaunchRecipe {
    let command: String
    let setup: String
    var requiresNode = false

    func problem(in environment: AgentLaunchEnvironment) -> String? {
        if requiresNode, environment.executable(named: "node") == nil || environment.executable(named: "npx") == nil {
            return "Install Node.js 22+ with npm, then try again."
        }
        guard let parsed = try? AgentCommand(command), environment.executable(named: parsed.executable) != nil else {
            return setup
        }
        return nil
    }
}
