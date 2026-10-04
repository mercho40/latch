import Foundation
import LatchACP

/// A question the agent asks, as a form the apps can show: Claude Code's AskUserQuestion, or
/// an MCP server's form. Read from the request's JSON Schema; a field of a kind no app can show
/// is left out, and a form with nothing left to ask is not shown at all.
public struct QuestionForm: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        /// What is sent back when chosen.
        public let value: String
        public let title: String
        public let detail: String?
        /// A mockup or snippet the agent shows with the option, as Claude Code's do.
        public let preview: String?
    }

    public enum Kind: Equatable, Sendable {
        /// One of the options, or with `multiple` any number of them.
        case choice(options: [Option], multiple: Bool)
        case text
        case number(integer: Bool)
        case toggle
    }

    public struct Field: Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let title: String?
        public let prompt: String?
        public let kind: Kind
        public let required: Bool
        /// For a choice, the field where the user may write an answer of their own instead.
        public let otherKey: String?
    }

    public let message: String
    public let fields: [Field]

    /// The marker Claude Code, and other AskUserQuestion bridges, put on a question's
    /// free-text companion.
    static let customAnswerMetaKey = "_askUserQuestionCustomAnswer"
    static let optionMetaKey = "_claude/askUserQuestionOption"

    public init?(_ request: ACPElicitationRequest) {
        guard request.mode == "form", case let .object(schema)? = request.requestedSchema,
              case let .object(properties)? = schema["properties"] else { return nil }
        var required: Set<String> = []
        if case let .array(names)? = schema["required"] {
            required = Set(names.compactMap { if case let .string(name) = $0 { name } else { nil } })
        }
        // A question's "Other" box belongs with the question, not after it.
        var others: [String: String] = [:]
        for (key, property) in properties {
            if let question = Self.customAnswerQuestion(of: property) { others[question] = key }
        }
        let companions = Set(others.values)
        // JSON objects have no order; question_2 before question_10, and the rest by name.
        let keys = properties.keys.filter { !companions.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let fields = keys.compactMap { key in
            Self.field(key: key, property: properties[key]!, required: required.contains(key),
                       otherKey: others[key].flatMap { properties[$0] == nil ? nil : $0 })
        }
        guard !fields.isEmpty else { return nil }
        message = request.message
        self.fields = fields
    }

    private static func customAnswerQuestion(of property: ACPJSONValue) -> String? {
        guard case let .object(fields) = property, case let .object(meta)? = fields["_meta"],
              case let .object(marker)? = meta[customAnswerMetaKey], case let .string(question)? = marker["questionId"] else { return nil }
        return question
    }

    private static func field(key: String, property: ACPJSONValue, required: Bool, otherKey: String?) -> Field? {
        guard case let .object(schema) = property else { return nil }
        let title = schema.string("title")
        let prompt = schema.string("description")
        func make(_ kind: Kind) -> Field {
            Field(key: key, title: title, prompt: prompt, kind: kind, required: required, otherKey: otherKey)
        }
        switch schema.string("type") {
        case "string":
            let options = Self.options(in: schema)
            return options.isEmpty ? make(.text) : make(.choice(options: options, multiple: false))
        case "array":
            guard case let .object(items)? = schema["items"] else { return nil }
            let options = Self.options(in: items)
            return options.isEmpty ? nil : make(.choice(options: options, multiple: true))
        case "number": return make(.number(integer: false))
        case "integer": return make(.number(integer: true))
        case "boolean": return make(.toggle)
        default: return nil
        }
    }

    /// Titled options from `oneOf` or `anyOf`, or plain ones from `enum`.
    private static func options(in schema: [String: ACPJSONValue]) -> [Option] {
        for key in ["oneOf", "anyOf"] {
            guard case let .array(entries)? = schema[key] else { continue }
            return entries.compactMap { entry in
                guard case let .object(option) = entry, case let .string(value)? = option["const"] else { return nil }
                var preview: String?
                if case let .object(meta)? = option["_meta"], case let .object(extra)? = meta[optionMetaKey] {
                    preview = extra.string("preview")
                }
                return Option(value: value, title: option.string("title") ?? value, detail: option.string("description"), preview: preview)
            }
        }
        guard case let .array(values)? = schema["enum"] else { return [] }
        var names: [String] = []
        if case let .array(titles)? = schema["enumNames"] {
            names = titles.map { if case let .string(name) = $0 { name } else { "" } }
        }
        return values.enumerated().compactMap { index, value in
            guard case let .string(value) = value else { return nil }
            let name = names.indices.contains(index) && !names[index].isEmpty ? names[index] : value
            return Option(value: value, title: name, detail: nil, preview: nil)
        }
    }

    /// What the user gave, by field: an answer of their own in a choice's `otherKey` stands
    /// for the choice. Fields left empty are left out.
    public func content(for answers: [String: QuestionAnswer]) -> [String: ACPJSONValue] {
        var content: [String: ACPJSONValue] = [:]
        for field in fields {
            if let otherKey = field.otherKey, case let .text(other)? = answers[otherKey],
               !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content[otherKey] = .string(other.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            switch (field.kind, answers[field.key]) {
            case let (.choice(_, multiple), .choices(values)?) where !values.isEmpty:
                content[field.key] = multiple ? .array(values.map(ACPJSONValue.string)) : .string(values[0])
            case let (.text, .text(text)?) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                content[field.key] = .string(text)
            case let (.number(integer), .text(text)?):
                if let value = Self.number(text, integer: integer) { content[field.key] = value }
            case let (.toggle, .toggle(value)?):
                content[field.key] = .bool(value)
            default:
                break
            }
        }
        return content
    }

    /// Whether every required field has an answer, and every number field holds a number or
    /// nothing, so the form may be sent.
    public func isComplete(_ answers: [String: QuestionAnswer]) -> Bool {
        let content = content(for: answers)
        return fields.allSatisfy { field in
            if case let .number(integer) = field.kind, case let .text(text)? = answers[field.key],
               !text.trimmingCharacters(in: .whitespaces).isEmpty, Self.number(text, integer: integer) == nil { return false }
            return !field.required || content[field.key] != nil || field.otherKey.map { content[$0] != nil } == true
        }
    }

    /// A typed number, if it is one JSON can carry: not NaN or infinity, which no encoder sends.
    static func number(_ text: String, integer: Bool) -> ACPJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if integer { return Int64(trimmed).map(ACPJSONValue.integer) }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return .double(value)
    }
}

public enum QuestionAnswer: Equatable, Sendable {
    /// The options chosen, by value.
    case choices([String])
    /// Typed text, also for a number.
    case text(String)
    case toggle(Bool)
}

/// The agent's questions waiting for an answer, one shown at a time, as `PermissionQueue` keeps
/// requests. Answering sends `accept` with what was given, Skip `decline`, and Cancel or a turn's
/// end `cancel`.
@MainActor
public final class QuestionQueue {
    public struct Question: Identifiable {
        public let id: UUID
        public let request: ACPElicitationRequest
        public let form: QuestionForm
    }

    private struct Entry {
        let question: Question
        let continuation: CheckedContinuation<ACPElicitationResponse, Never>
    }

    private var entries: [Entry] = []
    public var current: Question? { entries.first?.question }
    /// Owned by the session's model, which passes each change on through its own `onChange`.
    var onChange: (() -> Void)?

    func ask(_ request: ACPElicitationRequest) async -> ACPElicitationResponse {
        // A form none of its fields can be shown for cannot be answered; refusing it lets the agent go on.
        guard let form = QuestionForm(request) else { return .cancelled }
        let id = UUID()
        let response: ACPElicitationResponse = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, entries.count < 16 else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                entries.append(Entry(question: Question(id: id, request: request, form: form), continuation: continuation))
                onChange?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
        return Task.isCancelled ? .cancelled : response
    }

    /// Sends what was given. Only the question showing can be answered, so a late callback
    /// from a closed form answers nothing.
    public func answer(id: UUID, with answers: [String: QuestionAnswer]) {
        guard let first = entries.first, first.question.id == id else { return }
        finish(.init(action: .accept, content: first.question.form.content(for: answers)))
    }

    /// Answers nothing: Claude Code goes on as though the user skipped the question.
    public func skip(id: UUID) {
        guard entries.first?.question.id == id else { return }
        finish(.init(action: .decline))
    }

    /// Refuses the question, which ends the call that asked it.
    public func cancel(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.question.id == id }) else { return }
        entries.remove(at: index).continuation.resume(returning: .cancelled)
        onChange?()
    }

    public func cancelAll() {
        let pending = entries
        entries.removeAll()
        for entry in pending { entry.continuation.resume(returning: .cancelled) }
        onChange?()
    }

    private func finish(_ response: ACPElicitationResponse) {
        entries.removeFirst().continuation.resume(returning: response)
        onChange?()
    }
}

private extension Dictionary where Key == String, Value == ACPJSONValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key], !value.isEmpty else { return nil }
        return value
    }
}
