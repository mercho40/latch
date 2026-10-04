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
        context.displayPath = root.memory.displayPath(session.path, on: root.servers.server(id: session.serverID))
        context.onRename = { [weak session] name in session?.rename(to: name) }
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
        context.onResumeConversation = { [weak session] conversation in session?.resume(conversation) }
        // The copy opens beside this session, through the library as a new one does.
        context.onForkConversation = { [weak session, weak root] forked in
            guard let session, let root, root.library.session(id: session.id) === session else { return }
            root.show(root.library.fork(session, agentSessionID: forked))
        }
        context.returnedAttachments = session.takeReturnedAttachments()
        let screen = SessionDetailViewController(model: session.model, context: context)
        session.takesBackQueue = { [weak screen] prompts in
            guard let screen else { return false }
            screen.takeBack(prompts)
            return true
        }
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
    /// gave it or the user's rename, the agent and folder an adopted runtime's record named, and
    /// the server's name and home folder as Servers and its handshakes have them now. The rest of the context stays as it was made.
    func follow(_ session: PhoneSession, in root: RootViewController) {
        let server = root.servers.server(id: session.serverID)
        let serverName = server?.name ?? context.serverName
        let displayPath = root.memory.displayPath(session.path, on: server)
        guard context.title != session.title || context.serverName != serverName || context.folderPath != session.path
            || context.displayPath != displayPath || context.agentTitle != session.agentTitle else { return }
        var updated = context
        updated.title = session.title
        updated.serverName = serverName
        updated.folderPath = session.path
        updated.displayPath = displayPath
        updated.agentTitle = session.agentTitle
        context = updated
    }
}
