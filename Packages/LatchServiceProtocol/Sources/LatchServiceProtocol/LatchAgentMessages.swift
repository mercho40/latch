import Foundation
import LatchACP

public struct AgentRuntimeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct AgentRuntimeSnapshot: Codable, Equatable, Sendable {
    public let id: AgentRuntimeID
    public let state: ACPAgentRuntimeState

    public init(id: AgentRuntimeID, state: ACPAgentRuntimeState) {
        self.id = id
        self.state = state
    }
}

public struct ACPCommandProfile: Codable, Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectoryPath: String
    public let environment: [String: String]?

    public init(
        executablePath: String,
        arguments: [String] = [],
        workingDirectoryPath: String,
        environment: [String: String]? = nil
    ) {
        precondition(!executablePath.isEmpty)
        precondition(!workingDirectoryPath.isEmpty)
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectoryPath = workingDirectoryPath
        self.environment = environment
    }

    public var processConfiguration: ACPProcessConfiguration {
        ACPProcessConfiguration(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            workingDirectoryURL: URL(fileURLWithPath: workingDirectoryPath),
            environment: environment
        )
    }
}

public enum LatchAgentCommand: Codable, Equatable, Sendable {
    case listRuntimes
    case startRuntime(id: AgentRuntimeID, profile: ACPCommandProfile)
    case stopRuntime(id: AgentRuntimeID)
    case newSession(runtimeID: AgentRuntimeID, cwd: String)
    case setSessionConfigOption(runtimeID: AgentRuntimeID, configID: String, value: String)
    case setSessionModel(runtimeID: AgentRuntimeID, modelID: String)
    case prompt(runtimeID: AgentRuntimeID, text: String)
    case cancelPrompt(runtimeID: AgentRuntimeID)
}

public enum LatchAgentResponse: Codable, Equatable, Sendable {
    case runtimeList([AgentRuntimeSnapshot])
    case runtimeStarted(runtimeID: AgentRuntimeID, initialization: ACPInitializeResponse)
    case runtimeStopped(runtimeID: AgentRuntimeID)
    case sessionCreated(runtimeID: AgentRuntimeID, session: ACPNewSessionResponse)
    case sessionConfigOptionSet(runtimeID: AgentRuntimeID, response: ACPSetSessionConfigOptionResponse)
    case sessionModelSet(runtimeID: AgentRuntimeID, sequence: UInt64)
    case promptCompleted(runtimeID: AgentRuntimeID, response: ACPPromptResponse)
    case promptCancellationRequested(runtimeID: AgentRuntimeID)
}

public enum LatchAgentEvent: Codable, Equatable, Sendable {
    case sessionUpdate(runtimeID: AgentRuntimeID, notification: ACPSessionNotification)
    case standardError(runtimeID: AgentRuntimeID, data: Data)
    case processTerminated(runtimeID: AgentRuntimeID, status: Int32)
}
