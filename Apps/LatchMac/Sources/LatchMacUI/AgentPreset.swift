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
            AgentLaunchRecipe(command: "fx acp", setup: "Install fx and sign in with fx login.", signIn: "Sign in with fx login.")
        case .openCode:
            AgentLaunchRecipe(command: "opencode acp", setup: "Install OpenCode and configure its provider login.",
                              signIn: "Uses the provider login configured in OpenCode.")
        case .codex:
            adapter("codex-acp", package: "@agentclientprotocol/codex-acp@1.7.0",
                    setup: "Sign in with codex login. First connection requires Node.js with npm and internet access.",
                    signIn: "Sign in with codex login.", in: environment)
        case .claudeCode:
            adapter("claude-agent-acp", package: "@agentclientprotocol/claude-agent-acp@0.76.0",
                    setup: "Set up your Claude login. Node.js 22+ is required; first connection needs internet access.",
                    signIn: "Uses your Claude login.", in: environment)
        case .custom: nil
        }
    }

    private func adapter(_ executable: String, package: String, setup: String, signIn: String,
                         in environment: AgentLaunchEnvironment) -> AgentLaunchRecipe {
        if environment.executable(named: executable) != nil {
            return AgentLaunchRecipe(command: executable, setup: setup, signIn: signIn)
        }
        return AgentLaunchRecipe(command: "npx --yes \(package)", setup: setup, signIn: signIn, requiresNode: true)
    }
}

struct AgentLaunchRecipe {
    let command: String
    /// Everything needed from nothing: shown when the agent cannot start.
    let setup: String
    /// What remains once it can: shown beside an agent that is already installed.
    let signIn: String
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
