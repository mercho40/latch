import Foundation

public enum LatchServiceProtocolVersion {
    public static let current = 1
}

public struct LatchAgentRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let command: LatchAgentCommand

    public init(
        protocolVersion: Int = LatchServiceProtocolVersion.current,
        requestID: UUID = UUID(),
        command: LatchAgentCommand
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.command = command
    }
}

public enum LatchAgentFailureCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case unsupportedProtocolVersion
    case commandFailed
    case authenticationRequired
}

public struct LatchAgentFailure: Codable, Error, Equatable, Sendable {
    public let code: LatchAgentFailureCode
    public let message: String

    public init(code: LatchAgentFailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

extension LatchAgentFailure: LocalizedError {
    public var errorDescription: String? { message }
}

public enum LatchAgentReplyResult: Codable, Equatable, Sendable {
    case success(LatchAgentResponse)
    case failure(LatchAgentFailure)
}

public struct LatchAgentReply: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let result: LatchAgentReplyResult

    public init(
        protocolVersion: Int = LatchServiceProtocolVersion.current,
        requestID: UUID,
        result: LatchAgentReplyResult
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
    }
}

public struct LatchAgentEventEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let sequence: UInt64
    public let event: LatchAgentEvent

    public init(
        protocolVersion: Int = LatchServiceProtocolVersion.current,
        sequence: UInt64,
        event: LatchAgentEvent
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.event = event
    }
}
