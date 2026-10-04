import AppKit

/// An action offered on a notification.
struct AttentionAction: Equatable {
    let id: String
    let title: String
    let isDestructive: Bool
}

/// Where an attention alert is delivered. The real implementation is user notifications;
/// unbundled runs and tests supply their own, because `UNUserNotificationCenter` requires
/// a bundle identifier and would otherwise ask the user for authorization during a test.
@MainActor
protocol AttentionPresenting: AnyObject {
    var onAction: ((_ actionID: String, _ userInfo: [String: String]) -> Void)? { get set }
    func post(id: String, title: String, body: String, actions: [AttentionAction], userInfo: [String: String])
    func withdraw(id: String)
}

/// App-level attention. A session that needs a decision, or that has just finished, is only
/// visible in one window at a time; this reports the rest of them through the Dock badge,
/// a notification, and a bounce, and routes a decision made from a notification back.
///
/// Notification text never carries agent-provided details, tool arguments, or the session's
/// prompt-derived title — only the workspace folder the session belongs to.
@MainActor
final class AttentionCenter {
    /// One session's claim on the user's attention.
    struct State: Equatable {
        var workspaceName: String
        var permission: UUID?
        /// A question of the agent's waiting for an answer.
        var question: UUID?
        var allowOptionID: String?
        var rejectOptionID: String?
        var isPrompting: Bool
        /// Counts the session's turns that have ended. Only a new end is announced: a turn
        /// that stops being awaited because its link failed, or because Latch is quitting,
        /// runs on, and has not finished.
        var turnsEnded: Int
        /// The last turn ended because its agent was stopped on the server.
        var lastTurnStopped: Bool

        init(workspaceName: String, permission: UUID? = nil, question: UUID? = nil, allowOptionID: String? = nil,
             rejectOptionID: String? = nil, isPrompting: Bool = false, turnsEnded: Int = 0,
             lastTurnStopped: Bool = false) {
            self.workspaceName = workspaceName
            self.permission = permission
            self.question = question
            self.allowOptionID = allowOptionID
            self.rejectOptionID = rejectOptionID
            self.isPrompting = isPrompting
            self.turnsEnded = turnsEnded
            self.lastTurnStopped = lastTurnStopped
        }
    }

    /// Session, request, and the chosen option. A nil option cancels the request.
    var onResolvePermission: ((UUID, UUID, String?) -> Void)?
    /// Bring a session on screen, because a notification about it was clicked.
    var onReveal: ((UUID) -> Void)?
    /// Whether the user can already see that session; a visible one is never announced.
    var isSessionVisible: (UUID) -> Bool = { _ in false }

    private(set) var badgeCount = 0
    private var states: [UUID: State] = [:]
    private var attentionRequest: Int?
    private let presenter: (any AttentionPresenting)?
    private let dockTile: NSDockTile?

    init(presenter: (any AttentionPresenting)?, dockTile: NSDockTile? = nil) {
        self.presenter = presenter
        self.dockTile = dockTile
        presenter?.onAction = { [weak self] action, userInfo in self?.handle(action: action, userInfo: userInfo) }
    }

    /// Replaces the whole picture. Alerts are edges, so only what changed is announced.
    func update(_ next: [UUID: State]) {
        for (id, state) in next {
            let previous = states[id]
            if let request = state.permission, previous?.permission != request {
                announcePermission(session: id, request: request, state: state)
            }
            if let stale = previous?.permission, stale != state.permission {
                presenter?.withdraw(id: Self.permissionID(stale))
            }
            if let question = state.question, previous?.question != question {
                announceQuestion(session: id, question: question, state: state)
            }
            if let stale = previous?.question, stale != state.question {
                presenter?.withdraw(id: Self.questionID(stale))
            }
            if let previous, state.turnsEnded != previous.turnsEnded, !isSessionVisible(id) {
                presenter?.post(id: Self.finishedID(id), title: "Latch · \(state.workspaceName)",
                                body: state.lastTurnStopped ? "The agent was stopped on its server." : "The agent finished its turn.",
                                actions: [], userInfo: ["session": id.uuidString])
            }
            if state.isPrompting, previous?.isPrompting != true {
                presenter?.withdraw(id: Self.finishedID(id))
            }
        }
        // Sessions that went away take their alerts with them.
        for (id, state) in states where next[id] == nil {
            if let request = state.permission { presenter?.withdraw(id: Self.permissionID(request)) }
            if let question = state.question { presenter?.withdraw(id: Self.questionID(question)) }
            presenter?.withdraw(id: Self.finishedID(id))
        }
        states = next
        updateBadge()
    }

    /// Nothing is pending any more: the app is quitting or every session is gone.
    func clear() {
        update([:])
    }

    private func announcePermission(session: UUID, request: UUID, state: State) {
        guard !isSessionVisible(session) else { return }
        var actions: [AttentionAction] = []
        if let allow = state.allowOptionID { actions.append(AttentionAction(id: "allow:\(allow)", title: "Allow Once", isDestructive: false)) }
        if let reject = state.rejectOptionID { actions.append(AttentionAction(id: "reject:\(reject)", title: "Reject Once", isDestructive: true)) }
        presenter?.post(
            id: Self.permissionID(request), title: "Latch · \(state.workspaceName)",
            body: "The agent is waiting for a permission decision.", actions: actions,
            userInfo: ["session": session.uuidString, "request": request.uuidString]
        )
        guard !NSApplication.shared.isActive, attentionRequest == nil else { return }
        attentionRequest = NSApplication.shared.requestUserAttention(.informationalRequest)
    }

    /// Only the session's folder, as for a request: what the agent asks stays in Latch. Clicking
    /// it brings the session forward, since an answer needs the question in front of you.
    private func announceQuestion(session: UUID, question: UUID, state: State) {
        guard !isSessionVisible(session) else { return }
        presenter?.post(id: Self.questionID(question), title: "Latch · \(state.workspaceName)",
                        body: "The agent is asking you a question.", actions: [],
                        userInfo: ["session": session.uuidString])
        guard !NSApplication.shared.isActive, attentionRequest == nil else { return }
        attentionRequest = NSApplication.shared.requestUserAttention(.informationalRequest)
    }

    private func updateBadge() {
        let count = states.values.filter { $0.permission != nil || $0.question != nil }.count
        badgeCount = count
        dockTile?.badgeLabel = count > 0 ? "\(count)" : nil
        if count == 0, let request = attentionRequest {
            NSApplication.shared.cancelUserAttentionRequest(request)
            attentionRequest = nil
        }
    }

    /// A decision taken from the notification itself. Default activation only reveals the
    /// session: approving something you cannot see is not a decision.
    private func handle(action: String, userInfo: [String: String]) {
        guard let session = userInfo["session"].flatMap(UUID.init(uuidString:)) else { return }
        guard let request = userInfo["request"].flatMap(UUID.init(uuidString:)) else {
            onReveal?(session)
            return
        }
        if let option = action.split(separator: ":", maxSplits: 1).last.map(String.init),
           action.hasPrefix("allow:") || action.hasPrefix("reject:") {
            onResolvePermission?(session, request, option)
        } else {
            onReveal?(session)
        }
    }

    private static func permissionID(_ request: UUID) -> String { "permission.\(request.uuidString)" }
    private static func finishedID(_ session: UUID) -> String { "finished.\(session.uuidString)" }
    private static func questionID(_ question: UUID) -> String { "question.\(question.uuidString)" }
}
