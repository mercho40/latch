import Foundation
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
    /// Permission sheets the screen put up and took down, in order.
    private(set) var presentedSheets: [UIViewController] = []
    private(set) var dismissedSheets: [UIViewController] = []

    init(client: ScriptedSessionClient = ScriptedSessionClient(), draft: String = "",
         title: String = "Fix the flaky reconnect test") {
        self.client = client
        model = SessionModel(makeClient: { client })
        screen = SessionDetailViewController(model: model, context: SessionDetailContext(
            title: title, serverName: "vps", folderPath: "~/latch", agentTitle: "Claude Code", draft: draft))
        screen.context.onRetry = { [weak self] in self?.retries += 1 }
        screen.context.onStopAgent = { [weak self] in self?.stops += 1 }
        screen.context.onServerSettings = { [weak self] in self?.serverSettings += 1 }
        screen.context.onDraftChange = { [weak self] in self?.drafts.append($0) }
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

enum SampleConversation {
    static let prompt = ChatMessage(role: .user, text: "The reconnect test fails about one run in five on the Linux runner. Can you find out why?")
    static let read = ChatMessage(role: .tool, text: """
        Read Tests/RemoteSessionLiveTests.swift · completed

        Content:
        func testReconnect() async throws {
            let server = try await LoopbackServer.start()
            try await server.restart()
        }
        """)
    static let run = ChatMessage(role: .tool, text: """
        `swift test --filter RemoteSessionLiveTests/testReconnectAfterServerRestart` · failed

        rawOutput (text):
        error: testReconnect: timed out after 5.0 seconds
        """)
    static let answer = ChatMessage(role: .assistant, text: """
        ## What I found

        The test restarts the loopback server and reconnects **before the old port is released**. On Linux the port stays in `TIME_WAIT`, so:

        1. The restart binds a *new* port.
        2. The client still dials the old one:
           - it retries with backoff,
           - and gives up after 5 s.

        ```swift
        let port = try await server.restart(keepingPort: true)
        ```

        | Runner | Runs | Failures |
        | :-- | --: | --: |
        | macOS | 50 | 0 |
        | Linux | 50 | 9 |

        > The Mac never shows it: it sets `SO_REUSEADDR` by default.

        See [SO_REUSEADDR](https://man7.org/linux/man-pages/man7/socket.7.html) for the details.
        """)
    static let followUp = ChatMessage(role: .user, text: "Here is the CI log from the last failure.",
                                      attachments: [ChatAttachment(kind: .image, name: "ci-log.jpg", path: nil)])

    static let messages = [prompt, read, run, answer, followUp]
}
