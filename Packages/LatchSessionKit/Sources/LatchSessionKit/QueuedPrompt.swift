import Foundation

/// A message written while the agent was working, waiting to be sent when its turn ends.
public struct QueuedPrompt: Identifiable, Sendable {
    public let id = UUID()
    public let text: String
    public let attachments: [PromptAttachment]
}
