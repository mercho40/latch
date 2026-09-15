import Foundation

/// Agent preferences that outlive a session: which agents the composer picker offers, and
/// the command a custom ACP agent runs. A session still owns the harness it connected on —
/// this is the default a new session starts from, and the list it can choose within.
@MainActor
final class AgentSettings {
    static let shared = AgentSettings(defaults: .standard)

    private let defaults: UserDefaults
    private static let disabledKey = "LatchDisabledAgents"
    private static let customCommandKey = "LatchCustomAgentCommand"

    /// Posted when a stored preference changes, so every open session refreshes its picker
    /// without polling. A notification rather than a callback because the settings object
    /// is shared and each session needs its own turn.
    static let didChangeNotification = Notification.Name("LatchAgentSettingsDidChange")

    private func broadcast() { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }

    private(set) var disabled: Set<AgentPreset>
    private(set) var customCommand: String

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Self.disabledKey) as? [String] ?? []
        disabled = Set(stored.compactMap(AgentPreset.init(rawValue:)))
        customCommand = defaults.string(forKey: Self.customCommandKey) ?? ""
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

    /// The agent a new session starts on: the first enabled agent that can actually start,
    /// falling back to the filesystem suggestion when nothing is ready.
    func suggested(in catalog: AgentCatalog) -> AgentPreset {
        let ready = AgentPreset.allCases.first { preset in
            preset != .custom && isEnabled(preset) && catalog.status(for: preset).readiness.isUsable
        }
        return ready ?? AgentPreset.suggested(in: catalog.environment)
    }
}
