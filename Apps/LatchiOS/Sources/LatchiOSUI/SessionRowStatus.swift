import Foundation
import LatchSessionKit

/// The status slot at the end of a session's row. The Mac sidebar's rules, in the room a
/// phone row has: only a decision, work in motion, a failure and an unread reply get a mark,
/// and a session at rest says how long ago it was active.
struct SessionRowStatus: Equatable {
    enum Mark: Equatable {
        case none
        /// A spinner: a turn is running, or the session is connecting or reconnecting.
        case working
        /// A decision is waiting: orange, as on the Mac, so it stands apart from the tint.
        case waiting
        case failed
        /// A turn ended while the session was not on screen.
        case unread
    }

    var mark: Mark
    var text: String
    /// What VoiceOver reads for the slot.
    var spoken: String

    /// Words about what the session is doing, rather than a time.
    var isWords: Bool {
        switch mark {
        case .waiting, .failed: true
        case .working: text.hasSuffix("…")
        case .none: text == "Stopped"
        case .unread: false
        }
    }

    /// Everything the rules read, apart from the model so tests and snapshots can state it.
    struct Input: Equatable {
        var phase: SessionModel.Phase = .disconnected
        var status = ""
        var needsApproval = false
        var linkState = SessionLinkState.connected
        var hasError = false
        var stoppedOnServer = false
        /// Stop Agent was chosen here, and the session has not connected since.
        var stoppedHere = false
        var promptStartedAt: Date?
        var lastActiveAt: Date?
        var hasUnseenReply = false
    }

    static func make(_ input: Input, now: Date) -> SessionRowStatus {
        if input.needsApproval { return SessionRowStatus(mark: .waiting, text: "Needs approval", spoken: "Needs approval") }
        // Ahead of a failure: a live session's error belongs to an earlier prompt, and the lost
        // link is what matters now.
        if case .reconnecting = input.linkState, input.phase != .disconnected {
            let text = input.phase == .connecting ? "Connecting…" : "Reconnecting…"
            return SessionRowStatus(mark: .working, text: text, spoken: text)
        }
        // Stopped here is what the user did last, whatever the attempt before it said.
        if input.phase == .disconnected, input.stoppedHere {
            return SessionRowStatus(mark: .none, text: "Stopped", spoken: "Stopped")
        }
        if input.hasError {
            if input.stoppedOnServer || input.status == "Agent stopped" || input.status.hasPrefix("Agent exited") {
                return SessionRowStatus(mark: .none, text: "Stopped", spoken: "Stopped")
            }
            if input.status == "Not connected" || input.status == "Saved · Resume failed" {
                return SessionRowStatus(mark: .failed, text: "Can’t connect", spoken: "Can’t connect")
            }
            return SessionRowStatus(mark: .failed, text: input.status, spoken: input.status)
        }
        switch input.phase {
        case .prompting where input.status == "Working…":
            // How long the turn has run, so a long one looks long.
            guard let started = input.promptStartedAt else {
                return SessionRowStatus(mark: .working, text: "Working…", spoken: "Working")
            }
            let elapsed = RelativeTime.duration(now.timeIntervalSince(started))
            return SessionRowStatus(mark: .working, text: elapsed, spoken: "Working, \(elapsed)")
        case .connecting, .stopping, .prompting:
            return SessionRowStatus(mark: .working, text: input.status, spoken: input.status)
        case .ready, .disconnected:
            let time = input.lastActiveAt.map { RelativeTime.since($0, now: now) } ?? ""
            let spoken = input.lastActiveAt.map { "Active \(RelativeTime.spoken($0, now: now))" } ?? ""
            if input.phase == .ready, input.hasUnseenReply {
                return SessionRowStatus(mark: .unread, text: time, spoken: spoken.isEmpty ? "Unread reply" : "Unread reply, \(spoken)")
            }
            return SessionRowStatus(mark: .none, text: time, spoken: spoken)
        }
    }
}
