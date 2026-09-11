import LatchACP

struct SessionPicker: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case model, effort }
    enum Route: Equatable, Sendable { case config(String), legacyModel }

    let route: Route
    var currentValue: String
    let choices: [Choice]
    let description: String?

    struct Choice: Equatable, Sendable {
        let value: String
        let name: String
        let description: String?
        /// The human-readable group header, not the protocol's group ID.
        let group: String?
    }
}

struct SessionConfiguration: Equatable, Sendable {
    var model: SessionPicker?
    var effort: SessionPicker?

    init(configOptions: [ACPJSONValue]? = nil, models: ACPJSONValue? = nil) {
        let options = configOptions ?? []
        apply(configOptions: options)
        // A malformed or ambiguous modern model must not silently become a legacy control.
        if !options.contains(where: { Self.kind(of: $0) == .model }) {
            model = Self.legacyPicker(models)
        }
    }

    mutating func apply(configOptions: [ACPJSONValue]) {
        let objects = configOptions.compactMap(Self.object)
        let idCounts = objects.reduce(into: [String: Int]()) { counts, option in
            if let id = Self.string(option["id"]) { counts[id, default: 0] += 1 }
        }
        func picker(_ kind: SessionPicker.Kind) -> SessionPicker? {
            let candidates = configOptions.filter { Self.kind(of: $0) == kind }
            guard candidates.count == 1,
                  let option = candidates.first.flatMap(Self.object),
                  let id = Self.string(option["id"]), idCounts[id] == 1,
                  Self.string(option["type"]) == "select",
                  Self.string(option["name"]) != nil,
                  let current = Self.string(option["currentValue"]),
                  case let .array(options) = option["options"],
                  let choices = Self.choices(options) else { return nil }
            return SessionPicker(route: .config(id), currentValue: current,
                                 choices: choices, description: Self.string(option["description"]))
        }
        // Modern snapshots do not describe an independently active legacy model.
        // Any modern model candidate supersedes it, even if parsing fails closed.
        let hasModernModel = configOptions.contains { Self.kind(of: $0) == .model }
        if hasModernModel || model?.route != .legacyModel {
            model = picker(.model)
        }
        effort = picker(.effort)
    }

    /// Returns true for a valid, handled update, including an unchanged full snapshot.
    @discardableResult
    mutating func apply(update: ACPJSONValue) -> Bool {
        guard let update = Self.object(update) else { return false }
        switch Self.string(update["sessionUpdate"]) {
        case "config_option_update":
            guard case let .array(options) = update["configOptions"] else { return false }
            apply(configOptions: options)
            return true
        case "current_model_update":
            guard model?.route == .legacyModel,
                  let current = Self.string(update["currentModelId"]) else { return false }
            model?.currentValue = current
            return true
        default:
            return false
        }
    }

    subscript(kind: SessionPicker.Kind) -> SessionPicker? {
        switch kind {
        case .model: model
        case .effort: effort
        }
    }

    private static func kind(of value: ACPJSONValue) -> SessionPicker.Kind? {
        guard let option = object(value) else { return nil }
        if let category = option["category"], category != .null {
            switch string(category) {
            case "model": return .model
            case "thought_level": return .effort
            default: return nil
            }
        }
        switch string(option["id"]) {
        case "model": return .model
        case "effort", "reasoning_effort", "thought_level": return .effort
        default: return nil
        }
    }

    private static func choices(_ options: [ACPJSONValue]) -> [SessionPicker.Choice]? {
        var result: [SessionPicker.Choice] = []
        var values: Set<String> = []
        func append(_ value: ACPJSONValue, group: String?) -> Bool {
            guard let option = object(value),
                  let value = string(option["value"]),
                  let name = string(option["name"]) else { return true }
            guard values.insert(value).inserted else { return false }
            result.append(.init(value: value, name: name,
                                description: string(option["description"]), group: group))
            return true
        }
        for value in options {
            guard let option = object(value) else { continue }
            if option["group"] != nil || option["options"] != nil {
                guard string(option["group"]) != nil,
                      let name = string(option["name"]),
                      case let .array(children) = option["options"] else { continue }
                for child in children {
                    guard append(child, group: name) else { return nil }
                }
            } else if !append(value, group: nil) {
                return nil
            }
        }
        return result
    }

    private static func legacyPicker(_ value: ACPJSONValue?) -> SessionPicker? {
        guard let models = value.flatMap(object),
              let current = string(models["currentModelId"]),
              case let .array(available) = models["availableModels"] else { return nil }
        let options: [ACPJSONValue] = available.compactMap { value in
            guard var option = object(value), let id = string(option["modelId"]) else { return nil }
            option["value"] = .string(id)
            // Legacy models do not have groups.
            option.removeValue(forKey: "group")
            option.removeValue(forKey: "options")
            return .object(option)
        }
        guard let choices = choices(options) else { return nil }
        return SessionPicker(route: .legacyModel, currentValue: current, choices: choices, description: nil)
    }

    private static func object(_ value: ACPJSONValue) -> [String: ACPJSONValue]? {
        guard case let .object(object) = value else { return nil }
        return object
    }

    private static func string(_ value: ACPJSONValue?) -> String? {
        guard case let .string(string) = value else { return nil }
        return string
    }
}
