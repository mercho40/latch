/// Recalling sent prompts into the composer, as a shell recalls commands: Up in an empty
/// composer brings back the last prompt, Up again the one before, and Down walks forward and
/// past the newest back to an empty composer. Editing a recalled prompt ends the walk; the
/// edited text is then a draft like any other.
///
/// The prompts come from the conversation itself on every key, so there is nothing to keep.
public enum PromptHistory {
    /// Where a walk through the prompts stands: which one is in the composer, and its text,
    /// which the composer must still hold for the next key to go on walking.
    public struct Recall: Equatable, Sendable {
        public let index: Int
        public let text: String
    }

    /// What a key puts in the composer, and where the walk stands after it; nil when it ended.
    public struct Step: Equatable, Sendable {
        public let text: String
        public let recall: Recall?
    }

    /// The prompts sent in a conversation, oldest first, without a repeat of the one before.
    public static func prompts(in messages: [ChatMessage]) -> [String] {
        var prompts: [String] = []
        for message in messages where message.role == .user && message.parentID == nil {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != prompts.last { prompts.append(text) }
        }
        return prompts
    }

    /// Up: the prompt before the one recalled, or the newest from an empty composer. Nil
    /// leaves the key to the text, as when there is a draft or nothing older.
    public static func older(_ prompts: [String], composer: String, recall: Recall?) -> Step? {
        if let recall = walking(prompts, composer: composer, recall: recall) {
            guard recall.index > 0 else { return nil }
            return step(prompts, to: recall.index - 1)
        }
        guard composer.isEmpty, !prompts.isEmpty else { return nil }
        return step(prompts, to: prompts.count - 1)
    }

    /// Down: the prompt after the one recalled, or an empty composer past the newest. Nil when
    /// no walk is under way.
    public static func newer(_ prompts: [String], composer: String, recall: Recall?) -> Step? {
        guard let recall = walking(prompts, composer: composer, recall: recall) else { return nil }
        guard recall.index + 1 < prompts.count else { return Step(text: "", recall: nil) }
        return step(prompts, to: recall.index + 1)
    }

    /// The walk goes on only while the composer holds what it recalled, and that prompt is
    /// still where it was.
    private static func walking(_ prompts: [String], composer: String, recall: Recall?) -> Recall? {
        guard let recall, composer == recall.text, prompts.indices.contains(recall.index),
              prompts[recall.index] == recall.text else { return nil }
        return recall
    }

    private static func step(_ prompts: [String], to index: Int) -> Step {
        Step(text: prompts[index], recall: Recall(index: index, text: prompts[index]))
    }
}
