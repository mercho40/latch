import Foundation

/// Open so a client keeps working when a newer server adds a code.
public struct LatchRemoteFailureCode: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let unauthorized = LatchRemoteFailureCode(rawValue: "unauthorized")
    /// A frame of a `type` the server does not know, when it carried an `id`.
    public static let unsupported = LatchRemoteFailureCode(rawValue: "unsupported")
    /// A request whose command `kind` the server does not know.
    public static let unsupportedCommand = LatchRemoteFailureCode(rawValue: "unsupportedCommand")
    public static let invalidRequest = LatchRemoteFailureCode(rawValue: "invalidRequest")
    public static let runtimeNotFound = LatchRemoteFailureCode(rawValue: "runtimeNotFound")
    public static let duplicateRuntime = LatchRemoteFailureCode(rawValue: "duplicateRuntime")
    public static let sessionAlreadyBound = LatchRemoteFailureCode(rawValue: "sessionAlreadyBound")
    public static let noSession = LatchRemoteFailureCode(rawValue: "noSession")
    public static let busy = LatchRemoteFailureCode(rawValue: "busy")
    public static let executableNotFound = LatchRemoteFailureCode(rawValue: "executableNotFound")
    public static let workspaceNotFound = LatchRemoteFailureCode(rawValue: "workspaceNotFound")
    public static let nodeMissing = LatchRemoteFailureCode(rawValue: "nodeMissing")
    public static let unknownPreset = LatchRemoteFailureCode(rawValue: "unknownPreset")
    public static let permissionRequestNotFound = LatchRemoteFailureCode(rawValue: "permissionRequestNotFound")
    public static let invalidPermissionOption = LatchRemoteFailureCode(rawValue: "invalidPermissionOption")
    public static let elicitationRequestNotFound = LatchRemoteFailureCode(rawValue: "elicitationRequestNotFound")
    public static let authenticationRequired = LatchRemoteFailureCode(rawValue: "authenticationRequired")
    public static let payloadTooLarge = LatchRemoteFailureCode(rawValue: "payloadTooLarge")
    public static let commandFailed = LatchRemoteFailureCode(rawValue: "commandFailed")
    /// Ends a turn whose runtime exited or was stopped while it ran.
    public static let runtimeExited = LatchRemoteFailureCode(rawValue: "runtimeExited")
    /// A command the device's token does not allow: a watch-only device lists, attaches
    /// and detaches, and nothing more.
    public static let forbidden = LatchRemoteFailureCode(rawValue: "forbidden")
}

/// A failed request, or a turn that ended in error. `message` is for people and never echoes
/// server paths beyond what the client sent.
public struct LatchRemoteError: Codable, Error, Equatable, Sendable {
    public var code: LatchRemoteFailureCode
    public var message: String

    public init(code: LatchRemoteFailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

extension LatchRemoteError: LocalizedError {
    public var errorDescription: String? { message }
}
