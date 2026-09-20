import Foundation

/// Where an agent stands on this machine, as one ordered ladder. The composer picker,
/// the connection banner, and the Agents settings pane all render from this, so none of
/// them can disagree about whether an agent is able to start.
enum AgentReadiness: Equatable {
    /// The executable resolved on disk; the detail is the path it resolved to.
    case installed(path: String)
    /// Node is present and the pinned adapter is fetched on the first connection.
    case installsOnFirstUse
    /// Something has to happen before this agent can start, and the detail says what.
    case unavailable(problem: String)
    /// A custom agent with nothing entered yet. Distinct from `unavailable`: nothing is
    /// missing or broken, it has simply never been set up.
    case unconfigured(detail: String)

    /// Only a usable agent is suggested for a new session or connected without asking.
    var isUsable: Bool {
        switch self {
        case .installed, .installsOnFirstUse: true
        case .unavailable, .unconfigured: false
        }
    }

    /// Trailing text for a picker or settings row. Deliberately short: the detail belongs
    /// on the row's second line, not in the badge.
    var badge: String {
        switch self {
        case .installed: "Installed"
        case .installsOnFirstUse: "Installs on first use"
        case .unavailable: "Not found"
        case .unconfigured: "Not configured"
        }
    }

    /// What stands between this agent and a connection. Nil while usable.
    var problem: String? {
        switch self {
        case .installed, .installsOnFirstUse: nil
        case let .unavailable(problem): problem
        case let .unconfigured(detail): detail
        }
    }
}

/// One agent's launch recipe resolved against the current filesystem.
struct AgentStatus: Equatable {
    let preset: AgentPreset
    /// The command that would run. Empty only for a custom agent with nothing entered.
    let command: String
    let readiness: AgentReadiness
    /// What the user has to do when the agent cannot start, from the preset's recipe.
    let setup: String?

    var title: String { preset.title }
}

/// Resolves every agent against one filesystem scan. A rescan builds a new catalog rather
/// than mutating this one, so a view holding a catalog never renders half of an old scan.
struct AgentCatalog {
    let environment: AgentLaunchEnvironment
    /// The command a custom agent runs. Held here so the picker can say whether the custom
    /// entry is usable without reaching into the session's text field.
    let customCommand: String
    /// The scan itself, taken once. Resolving one agent stats every search directory, and
    /// the window's harness control reads all of them on every transcript chunk and every
    /// keystroke in the composer — resolving per read put milliseconds of filesystem work
    /// on the main thread between frames.
    private let scan: [AgentPreset: AgentStatus]

    init(environment: AgentLaunchEnvironment, customCommand: String = "") {
        self.environment = environment
        self.customCommand = customCommand
        scan = Dictionary(uniqueKeysWithValues: AgentPreset.allCases.map {
            ($0, Self.resolve($0, in: environment, customCommand: customCommand))
        })
    }

    /// A lookup into the scan this catalog was built from, never a fresh one.
    func status(for preset: AgentPreset) -> AgentStatus {
        // The scan covers `allCases`, so the fallback resolves nothing in practice.
        scan[preset] ?? Self.resolve(preset, in: environment, customCommand: customCommand)
    }

    private static func resolve(_ preset: AgentPreset, in environment: AgentLaunchEnvironment,
                                customCommand: String) -> AgentStatus {
        guard let recipe = preset.recipe(in: environment) else {
            return customStatus(command: customCommand, in: environment)
        }
        return AgentStatus(preset: preset, command: recipe.command,
                           readiness: readiness(of: recipe, in: environment), setup: recipe.setup)
    }

    private static func readiness(of recipe: AgentLaunchRecipe, in environment: AgentLaunchEnvironment) -> AgentReadiness {
        if let problem = recipe.problem(in: environment) { return .unavailable(problem: problem) }
        // A recipe with no problem either resolved on disk or is an npx adapter with Node
        // present, whose package is fetched on the first connection.
        guard let parsed = try? AgentCommand(recipe.command),
              let path = environment.executable(named: parsed.executable), !recipe.requiresNode
        else { return .installsOnFirstUse }
        return .installed(path: path)
    }

    private static func customStatus(command: String, in environment: AgentLaunchEnvironment) -> AgentStatus {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AgentStatus(preset: .custom, command: "",
                               readiness: .unconfigured(detail: "No command set yet."),
                               setup: nil)
        }
        do {
            let resolved = try environment.resolve(AgentCommand(trimmed))
            return AgentStatus(preset: .custom, command: trimmed,
                               readiness: .installed(path: resolved.executable), setup: nil)
        } catch {
            return AgentStatus(preset: .custom, command: trimmed,
                               readiness: .unavailable(problem: error.localizedDescription), setup: nil)
        }
    }

    var statuses: [AgentStatus] { AgentPreset.allCases.map(status(for:)) }
}

/// What the window's harness control shows for a session and what it offers. The session
/// owns the decision; the window only renders this and reports a choice back.
struct HarnessSelection {
    struct Row {
        let preset: AgentPreset
        let title: String
        /// What the agent needs, or what choosing it would do. Shown on hover, not as a
        /// second line: the control states the agent, and Settings states its install state.
        let detail: String
        let isCurrent: Bool
    }

    let rows: [Row]
    let current: AgentPreset
    let problem: String?
    let isEditable: Bool

    var title: String { current.title }
}
