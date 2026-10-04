#if canImport(Network)
import Foundation
import LatchRemoteProtocol

/// Why a connection or channel failed on this side of the wire. A server's answer to a request
/// is a `LatchRemoteError` instead.
public enum LatchRemoteClientError: Error, Equatable, Sendable {
    /// The peer is neither this machine nor on a tailnet, and the server profile does not allow
    /// an unencrypted network. Nothing was sent, not even the token.
    case destinationNotAllowed(address: String)
    case unauthorized(message: String)
    case protocolMismatch(message: String, supported: LatchRemoteVersionRange?)
    /// Refused for a reason other than the token or the version, such as `busy`.
    case rejected(reason: LatchRemoteRejectReason, message: String)
    /// The port is 0.
    case invalidEndpoint
    case connectionFailed(String)
    /// The server closed the connection, or it was dropped deliberately.
    case connectionLost
    case handshakeTimedOut
    /// Nothing arrived for three heartbeats.
    case silence
    /// A request or ping with a deadline got no answer in time.
    case timedOut
    /// The server sent something this client cannot read.
    case protocolViolation(String)
    /// The connection has not finished its handshake.
    case notConnected
    /// The server answered this request with a reply whose result did not decode. It may have run.
    case invalidReply
    /// Turns can only be followed once the channel is attached to its runtime.
    case notAttached
    /// The runtime was gone when the channel re-attached after a reconnect.
    case runtimeNotFound(message: String)
    /// Closed by its owner.
    case closed

    /// Failures that end a channel: retrying cannot help.
    public var isPermanent: Bool {
        switch self {
        case .destinationNotAllowed, .unauthorized, .protocolMismatch, .invalidEndpoint, .runtimeNotFound, .closed:
            true
        case .rejected, .connectionFailed, .connectionLost, .handshakeTimedOut, .silence, .timedOut,
             .protocolViolation, .notConnected, .invalidReply, .notAttached:
            false
        }
    }

    /// Failures of the link rather than of a request: a request that failed with one is sent
    /// again on the next connection.
    public var isLinkFailure: Bool {
        switch self {
        case .rejected, .connectionFailed, .connectionLost, .handshakeTimedOut, .silence, .timedOut,
             .protocolViolation, .notConnected:
            true
        case .destinationNotAllowed, .unauthorized, .protocolMismatch, .invalidEndpoint, .invalidReply,
             .notAttached, .runtimeNotFound, .closed:
            false
        }
    }
}

extension LatchRemoteClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .destinationNotAllowed(address):
            "Latch did not send the token to \(address) because it is neither this Mac nor on a tailnet. Allow an unencrypted network for this server to connect anyway."
        case let .unauthorized(message), let .protocolMismatch(message, _), let .rejected(_, message):
            message
        case .invalidEndpoint:
            "The server's port is not valid."
        case let .connectionFailed(detail):
            "Could not connect to the server: \(detail)"
        case .connectionLost:
            "The connection to the server was lost."
        case .handshakeTimedOut:
            "The server did not answer in time."
        case .silence:
            "The server stopped responding."
        case .timedOut:
            "The server did not answer in time."
        case let .protocolViolation(detail):
            "The server sent something Latch cannot read: \(detail)"
        case .notConnected:
            "Not connected to the server."
        case .invalidReply:
            "The server's reply could not be read."
        case .notAttached:
            "The session is not attached to its agent."
        case let .runtimeNotFound(message):
            message
        case .closed:
            "The connection was closed."
        }
    }
}

/// A turn's end, as the server journaled it.
public struct LatchRemoteTurnOutcome: Equatable, Sendable {
    public var turnID: UUID
    public var stopReason: String?
    /// Set when the turn failed, including `runtimeExited` when its runtime ended first.
    public var error: LatchRemoteError?
    /// The last sequence the channel had delivered on `events` when it learned of this end:
    /// the `turnEnded` event itself, the event that completed an attach's backlog when the
    /// record said so, or the attach's cursor when there was none. The outcome travels apart
    /// from the events, so whoever shows the turn takes in this much before ending it.
    public var deliveredThrough: UInt64

    public init(turnID: UUID, stopReason: String?, error: LatchRemoteError?, deliveredThrough: UInt64 = 0) {
        self.turnID = turnID
        self.stopReason = stopReason
        self.error = error
        self.deliveredThrough = deliveredThrough
    }
}

extension Duration {
    /// Saturates at about a century rather than overflowing, and never goes below zero.
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let limit: Int64 = 3_000_000_000
        guard seconds >= 0 else { return .nanoseconds(0) }
        guard seconds < limit else { return .seconds(Int(limit)) }
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
#endif
