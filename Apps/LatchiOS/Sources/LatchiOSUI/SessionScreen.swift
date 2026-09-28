import LatchSessionKit
import UIKit

extension SessionDetailViewController {
    /// The screen for one of the library's sessions, as the root shows it: it hears of the
    /// session's changes through the session, and every lifecycle decision goes back through
    /// the session, the library and the root. A session made anew under the same ID, as when its
    /// server's token is entered again, gets a new screen from the root.
    static func make(for session: PhoneSession, in root: RootViewController) -> SessionDetailViewController {
        var context = SessionDetailContext(title: session.title, serverName: "", folderPath: session.path,
                                           agentTitle: session.agentTitle, draft: session.draft)
        context.serverName = root.servers.server(id: session.serverID)?.name ?? ""
        // A session still adopting its runtime connects by adopting it again.
        context.onRetry = { [weak session] in session?.connect() }
        context.onStopAgent = { [weak session, weak root] in
            guard let session, let root else { return }
            Task { await root.library.stop(session) }
        }
        // Only for a server Servers still has, or one waiting for its token: any other editor
        // would add a new server, which this session would never use.
        context.onServerSettings = { [weak session, weak root] in
            guard let session, let root, root.hasServer(session.serverID) else { return }
            root.presentServerEditor(serverID: session.serverID)
        }
        context.hasServer = { [weak session, weak root] in
            guard let session, let root else { return false }
            return root.hasServer(session.serverID)
        }
        context.isStopped = { [weak session] in session?.stoppedHere ?? false }
        // Setting the draft schedules the library's save.
        context.onDraftChange = { [weak session] draft in session?.draft = draft }
        context.canStopAgent = { [weak session] in session?.canStop ?? false }
        let screen = SessionDetailViewController(model: session.model, context: context)
        session.observe(screen, change: { [weak screen, weak session, weak root] in
            guard let screen, let session, let root else { return }
            screen.follow(session, in: root)
            screen.modelDidChange()
        }, transcript: { [weak screen] in
            screen?.transcriptDidChange()
        })
        return screen
    }

    /// Takes up what changed about the session outside its model: the title its first prompt
    /// gave it, the agent and folder an adopted runtime's record named, and the server's name
    /// as Servers has it now. The rest of the context stays as it was made.
    func follow(_ session: PhoneSession, in root: RootViewController) {
        let serverName = root.servers.server(id: session.serverID)?.name ?? context.serverName
        guard context.title != session.title || context.serverName != serverName
            || context.folderPath != session.path || context.agentTitle != session.agentTitle else { return }
        var updated = context
        updated.title = session.title
        updated.serverName = serverName
        updated.folderPath = session.path
        updated.agentTitle = session.agentTitle
        context = updated
    }
}
