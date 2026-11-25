import Foundation
import LatchAgentCore
import LatchSessionKit

/// Agent preferences that outlive a session: which agents the composer picker offers, and
/// the command a custom ACP agent runs. A session still owns the harness it connected on —
/// this is the default a new session starts from, and the list it can choose within.
@MainActor
final class AgentSettings {
    static let shared = AgentSettings(defaults: .standard)

    private let defaults: UserDefaults
    private static let disabledKey = "LatchDisabledAgents"
    private static let customCommandKey = "LatchCustomAgentCommand"
    private static let choicesKey = "LatchAgentChoices"

    /// Posted when a stored preference changes, so every open session refreshes its picker
    /// without polling. A notification rather than a callback because the settings object
    /// is shared and each session needs its own turn.
    static let didChangeNotification = Notification.Name("LatchAgentSettingsDidChange")

    private func broadcast() { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }

    private(set) var disabled: Set<AgentPreset>
    private(set) var customCommand: String
    /// The last pick made in each of an agent's pickers, by agent and then `SessionPicker.key`:
    /// what a new session on that agent starts on, when the agent still offers it.
    private var choices: [String: [String: String]]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Self.disabledKey) as? [String] ?? []
        disabled = Set(stored.compactMap(AgentPreset.init(rawValue:)))
        customCommand = defaults.string(forKey: Self.customCommandKey) ?? ""
        choices = defaults.dictionary(forKey: Self.choicesKey) as? [String: [String: String]] ?? [:]
    }

    func choices(for preset: AgentPreset) -> [String: String] { choices[preset.rawValue] ?? [:] }

    /// Not the permission mode: one picked to let a single task run unattended must not
    /// become every later session's way of working without the user choosing it again.
    func remember(_ kind: SessionPicker.Kind?, key: String, value: String, for preset: AgentPreset) {
        guard kind != .permissionMode, choices[preset.rawValue]?[key] != value else { return }
        choices[preset.rawValue, default: [:]][key] = value
        defaults.set(choices, forKey: Self.choicesKey)
    }

    /// Agents the picker offers. The session's own harness is always included by the
    /// picker itself, so disabling an agent never strands a session that is using it.
    var enabled: [AgentPreset] { AgentPreset.allCases.filter { !disabled.contains($0) } }

    func isEnabled(_ preset: AgentPreset) -> Bool { !disabled.contains(preset) }

    func setEnabled(_ enabled: Bool, for preset: AgentPreset) {
        let updated = enabled ? disabled.subtracting([preset]) : disabled.union([preset])
        guard updated != disabled else { return }
        disabled = updated
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: Self.disabledKey)
        broadcast()
    }

    func setCustomCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != customCommand else { return }
        customCommand = trimmed
        defaults.set(trimmed, forKey: Self.customCommandKey)
        broadcast()
    }

    /// The agent a new session starts on: the first offered agent that can actually start.
    ///
    /// When nothing offered can start, still prefer an agent the user has left on — opening
    /// a session on one they turned off, just because it happens to be installed, ignores
    /// the only instruction they gave. The banner then says what that agent needs. The
    /// filesystem suggestion is the last resort, for when nothing is offered at all.
    ///
    /// `.custom` sorts last within each of those steps, ready or not: it is whichever
    /// command the user typed, so Latch can say nothing useful about it when it fails.
    /// Being able to start still outranks that — a working custom agent beats an offered
    /// preset that cannot run.
    func suggested(in catalog: AgentCatalog) -> AgentPreset {
        let offered = AgentPreset.allCases.filter(isEnabled)
        let preferred = offered.filter { $0 != .custom } + offered.filter { $0 == .custom }
        if let ready = preferred.first(where: { catalog.status(for: $0).readiness.isUsable }) { return ready }
        if let first = preferred.first { return first }
        return AgentPreset.suggested(in: catalog.environment)
    }
}
