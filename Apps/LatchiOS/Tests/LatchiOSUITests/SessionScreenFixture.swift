import Foundation
import LatchACP
import LatchSessionKit
import UIKit
@testable import LatchiOSUI

/// A session screen over a scripted client, wired the way a host wires one, recording what
/// the screen asks of its host.
@MainActor
final class SessionScreenFixture {
    let client: ScriptedSessionClient
    let model: SessionModel
    let screen: SessionDetailViewController
    private(set) var retries = 0
    private(set) var stops = 0
    private(set) var serverSettings = 0
    private(set) var drafts: [String] = []
    /// Conversations the screen asked to take up, and forks it asked to open.
    private(set) var resumed: [ACPSessionSummary] = []
    private(set) var forks: [String] = []
    /// Sheets and alerts the screen put up and took down, in order.
    private(set) var presentedSheets: [UIViewController] = []
    private(set) var dismissedSheets: [UIViewController] = []

    init(client: ScriptedSessionClient = ScriptedSessionClient(), draft: String = "",
         title: String = "Fix the flaky reconnect test") {
        self.client = client
        model = SessionModel(makeClient: { client })
        screen = SessionDetailViewController(model: model, context: SessionDetailContext(
            title: title, serverName: "vps", folderPath: "/home/simon/latch", displayPath: "~/latch",
            agentTitle: "Claude Code", draft: draft))
        // Pictures of sent photos go to a folder of this fixture's own.
        screen.sentImages = SentImageCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        screen.context.onRetry = { [weak self] in self?.retries += 1 }
        screen.context.onStopAgent = { [weak self] in self?.stops += 1 }
        screen.context.onServerSettings = { [weak self] in self?.serverSettings += 1 }
        screen.context.onDraftChange = { [weak self] in self?.drafts.append($0) }
        // As the session does: the same agent starts again on the conversation chosen.
        screen.context.onResumeConversation = { [weak self] conversation in
            guard let self else { return }
            resumed.append(conversation)
            Task { await self.model.switchToAgentSession(conversation.sessionId) }
        }
        screen.context.onForkConversation = { [weak self] in self?.forks.append($0) }
        // The test host never finishes a sheet's transition, so these finish at once.
        screen.presentSheet = { [weak self] sheet, done in
            self?.presentedSheets.append(sheet)
            done()
        }
        screen.dismissSheet = { [weak self] sheet, done in
            self?.dismissedSheets.append(sheet)
            done()
        }
        model.onChange = { [weak screen] in screen?.modelDidChange() }
        model.onTranscriptChange = { [weak screen] in screen?.transcriptDidChange() }
        model.onQueueReturned = { [weak screen] in screen?.takeBack($0) }
    }

    func connect() async {
        await model.connect(remote: .preset("claudeCode"), path: "/home/simon/latch")
    }

    /// A saved conversation, resumed: the model loads the agent's context and is ready.
    func resume(_ messages: [ChatMessage]) async {
        model.restore(messages: messages, agentSessionID: ScriptedSessionClient.sessionID)
        await connect()
    }

    func type(_ text: String) {
        screen.composer.textView.text = text
        screen.composer.textViewDidChange(screen.composer.textView)
    }

    var transcript: TranscriptController { screen.transcript }

    func cell<T: UICollectionViewCell>(for id: UUID, as type: T.Type = T.self) -> T? {
        let collection = transcript.collectionView
        collection.layoutIfNeeded()
        guard let row = transcript.order.firstIndex(of: id) else { return nil }
        let path = IndexPath(item: row, section: 0)
        collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        return collection.cellForItem(at: path) as? T
    }
}
