#if DEBUG
import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import UIKit

/// `--smoke-test-remote latch://127.0.0.1:<port>?token=… <folder>`: the real app, driven
/// through its own screens against a real `latch-server` the caller started. The Simulator
/// shares this Mac's network and files, so the server is on loopback and runs the mock agent
/// the smoke writes into the folder. It prints one `IOS SMOKE REMOTE:` line per stage and
/// exits 0; on a failure it says what was on screen and exits 1. Debug builds only.
///
/// The app starts with nothing saved: the script installs it afresh. The server is added to
/// the real store, so its token goes through the Keychain, and removed at the end.
@MainActor
enum RemoteSmoke {
    static let argument = "--smoke-test-remote"

    struct Request {
        let pairing: LatchRemotePairing
        /// The session's folder, on the server and on this Mac alike.
        let workspace: URL
    }

    /// The request the app was launched with, if any; a malformed one is a failure.
    static var request: Result<Request, Failure>? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        guard index + 2 < arguments.count, let pairing = try? LatchRemotePairing(parsing: arguments[index + 1]) else {
            return .failure(Failure("expected \(argument) latch://host:port?token=… FOLDER"))
        }
        return .success(Request(pairing: pairing, workspace: URL(fileURLWithPath: arguments[index + 2], isDirectory: true)))
    }

    /// A link comes back only when the smoke asks, so a dropped one stays down while the
    /// agent finishes its turn on the server.
    static let backoff = LatchRemoteBackoff(initial: .seconds(30), maximum: .seconds(30))

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func run(_ request: Request, window: UIWindow, scene: UIWindowScene, delegate: LatchSceneDelegate,
                    root: RootViewController, servers: KeychainServerStore, connector: ChannelRemoteSessionConnector) {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(150))
            fail("timed out", window: window, root: root)
        }
        Task {
            do {
                let smoke = Run(request: request, window: window, scene: scene, delegate: delegate, root: root,
                                servers: servers, connector: connector)
                try await smoke.run()
                watchdog.cancel()
                exit(0)
            } catch {
                fail("\(error)", window: window, root: root)
            }
        }
    }

    private static func fail(_ problem: String, window: UIWindow, root: RootViewController) -> Never {
        var state = ""
        if let session = root.shown?.session {
            let model = session.model
            state = "\n  session “\(session.title)”: \(model.phase), \(model.status), link \(model.linkState), "
                + "messages \(model.messages.map { "\($0.role): \($0.text)" })"
        }
        FileHandle.standardError.write(Data(
            "IOS SMOKE REMOTE: FAIL — \(problem)\n  on screen: \(onScreen(window))\(state)\n".utf8))
        exit(1)
    }

    /// The words on screen, top to bottom as the views are nested: labels, text views and
    /// button titles in every window of the scene, sheets included.
    static func onScreen(_ window: UIWindow) -> String {
        var words: [String] = []
        func walk(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            let text: String? = switch view {
            case let label as UILabel: label.text
            case let textView as UITextView: textView.text
            case let button as UIButton: button.configuration?.title ?? button.currentTitle
            default: nil
            }
            if let text, !text.isEmpty { words.append(text.replacingOccurrences(of: "\n", with: " ")) }
            view.subviews.forEach(walk)
        }
        (window.windowScene?.windows ?? [window]).forEach(walk)
        return words.joined(separator: " | ")
    }

    private static func pass(_ line: String) {
        FileHandle.standardOutput.write(Data("IOS SMOKE REMOTE: \(line) — PASS\n".utf8))
    }

    /// One run, in the order a person would go.
    @MainActor
    private struct Run {
        let request: Request
        let window: UIWindow
        let scene: UIWindowScene
        let delegate: LatchSceneDelegate
        let root: RootViewController
        let servers: KeychainServerStore
        let connector: ChannelRemoteSessionConnector

        var library: SessionLibrary { root.library }
        var device: String { root.traitCollection.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

        func run() async throws {
            try await until("the empty sessions list, with nothing saved", timeout: .seconds(20)) { LaunchSmoke.check(window) == nil }
            let server = try await addServer()
            let session = try await newSession(on: server)
            let screen = try await screenShowing(session)
            try await converse(in: screen, session: session)
            let adopted = try await adoptRuntimeStartedElsewhere(on: server)
            try await backgroundAndForeground([session, adopted])
            try servers.remove(id: server.id)
            try await until("the server gone from the Keychain") { (try? KeychainTokenVault().token(for: server.id)) == nil }
            pass("\(device): removed the server and its Keychain token")
        }

        // MARK: Server

        func addServer() async throws -> ServerProfile {
            let script = request.workspace.appendingPathComponent("agent.sh")
            do {
                try RemoteMockAgent.script.write(to: script, atomically: true, encoding: .utf8)
            } catch {
                throw Failure("could not write the mock agent to \(script.path): \(error.localizedDescription)")
            }
            let server = ServerProfile(name: "smoke", host: request.pairing.host, port: request.pairing.port,
                                       token: request.pairing.token,
                                       customCommand: "/bin/sh " + AgentCommand.quotedArgument(script.path))
            try servers.save(server)
            // Read back as the next launch would: the profile from its file, the token from the Keychain.
            let reread = KeychainServerStore(directory: AppFiles.directory, vault: KeychainTokenVault())
            guard reread.server(id: server.id)?.token == server.token else {
                throw Failure("the server's token did not come back from the Keychain")
            }
            try await until("the server's section in the list") {
                root.sessions.dataSource.snapshot().sectionIdentifiers.contains(.server(server.id))
            }
            pass("\(device): server added through the store, its token in the Keychain, listed")
            return server
        }

        // MARK: New Session

        func newSession(on server: ServerProfile) async throws -> PhoneSession {
            root.presentNewSession(serverID: server.id)
            var form: NewSessionViewController?
            try await until("the New Session sheet") {
                let navigation = root.presentedViewController as? UINavigationController
                form = navigation?.topViewController as? NewSessionViewController
                return form?.viewIfLoaded?.window != nil && navigation?.isBeingPresented == false
            }
            guard let form else { throw Failure("no New Session sheet") }
            form.selectAgent(.custom)
            form.pathField.text = request.workspace.path
            form.pathChanged()
            guard form.canCreate else { throw Failure("New Session cannot create a Custom session in \(request.workspace.path)") }
            form.create()
            try await until("the new session on screen") {
                root.presentedViewController == nil && root.shown.map { root.isShowing($0.session.id) } == true
            }
            guard let session = root.shown?.session, session.serverID == server.id, session.path == request.workspace.path
            else { throw Failure("the new session is not the one asked for") }
            try await until("the agent to start", timeout: .seconds(20)) { session.model.phase == .ready }
            guard session.model.linkState == .connected, session.model.errorMessage == nil else {
                throw Failure("the session did not connect cleanly: \(session.model.status)")
            }
            FileHandle.standardOutput.write(Data(
                "IOS SMOKE REMOTE: agent service transport = \(session.model.serviceTransportDescription)\n".utf8))
            pass("\(device): New Session started a custom agent on smoke in \(request.workspace.lastPathComponent)")
            return session
        }

        func screenShowing(_ session: PhoneSession) async throws -> SessionDetailViewController {
            guard let screen = root.shown?.controller as? SessionDetailViewController, screen.model === session.model else {
                throw Failure("the session is not shown in its screen")
            }
            try await until("the session screen's title") { screen.context.serverName == "smoke" }
            return screen
        }

        // MARK: Conversation

        func converse(in screen: SessionDetailViewController, session: PhoneSession) async throws {
            let model = session.model
            try await send("Say hello", in: screen)
            try await until("the streamed reply") { model.phase == .ready && model.messages.last?.text == "onetwothree" }
            try await until("the reply's cell") { cellShown(for: model.messages.last?.id, in: screen) }
            guard session.title == "Say hello", screen.title == "Say hello" else {
                throw Failure("the first prompt did not title the session: \(session.title)")
            }
            pass("\(device): prompt sent from the composer, reply streamed into the transcript, session titled")

            try await send("Ask permission", in: screen)
            var sheet: PermissionRequestViewController?
            try await until("the permission sheet") {
                sheet = screen.permissionSheet
                return sheet?.viewIfLoaded?.window != nil && sheet?.isBeingPresented == false
            }
            guard let sheet, let allow = sheet.optionButtons.first, sheet.optionButtons.count == 2 else {
                throw Failure("the permission sheet did not offer the agent's two options")
            }
            allow.sendActions(for: .primaryActionTriggered)
            try await until("the decision to reach the agent") {
                screen.permissionSheet == nil && model.phase == .ready && model.messages.last?.text == "askingallowed"
            }
            guard lines(in: "decisions.log") == 1 else { throw Failure("the agent heard \(lines(in: "decisions.log")) decisions") }
            pass("\(device): permission sheet answered with the agent's own option")

            try await send("Go slow", in: screen)
            try await until("the slow turn's first words") { model.phase == .prompting && model.messages.last?.text == "one" }
            for client in connector.liveClients { client.dropConnectionForTesting() }
            try await until("the banner to say it is reconnecting") {
                screen.banner.isShowing && screen.currentBanner?.title == "Reconnecting to smoke…"
            }
            // The agent finishes the turn on the server while the link is down.
            try await until("the turn to end on the server") { lines(in: "slow.log") == 1 }
            guard model.phase == .prompting, model.messages.last?.text == "one" else {
                throw Failure("the turn went on without the link: \(model.messages.map(\.text))")
            }
            for client in connector.liveClients { await client.probe() }
            try await until("the turn replayed") {
                model.phase == .ready && model.linkState == .connected && model.messages.last?.text == "onetwothree"
            }
            try await until("the banner gone") { !screen.banner.isShowing }
            let texts = model.messages.map(\.text)
            guard texts == ["Say hello", "onetwothree", "Ask permission", "askingallowed", "Go slow", "onetwothree"],
                  lines(in: "prompts.log") == 3, screen.transcript.order.count == texts.count else {
                throw Failure("the turn did not survive the dropped link exactly once: \(texts), "
                    + "\(lines(in: "prompts.log")) prompts, \(screen.transcript.order.count) rows")
            }
            pass("\(device): link dropped mid-turn, reconnecting shown, turn completed once with no duplicates")
        }

        func send(_ text: String, in screen: SessionDetailViewController) async throws {
            screen.composer.textView.text = text
            screen.composer.textViewDidChange(screen.composer.textView)
            try await until("Send to be enabled") { screen.canSend }
            screen.composer.actionButton.sendActions(for: .primaryActionTriggered)
            try await until("the prompt in the transcript") { screen.model.messages.contains { $0.text == text } }
        }

        func cellShown(for id: UUID?, in screen: SessionDetailViewController) -> Bool {
            let transcript = screen.transcript
            guard let id, let row = transcript.order.firstIndex(of: id) else { return false }
            transcript.collectionView.layoutIfNeeded()
            return transcript.collectionView.cellForItem(at: IndexPath(item: row, section: 0)) != nil
        }

        func lines(in file: String) -> Int {
            let text = (try? String(contentsOf: request.workspace.appendingPathComponent(file), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").count
        }

        // MARK: Adopting

        /// Another device's runtime: launched, given a session and prompted over a connection of
        /// its own, then found under "On smoke" and adopted, its history replayed.
        func adoptRuntimeStartedElsewhere(on server: ServerProfile) async throws -> PhoneSession {
            let runtimeID = AgentRuntimeID(UUID().uuidString)
            let connection = LatchRemoteConnection(options: server.connectionOptions)
            defer { connection.close() }
            connection.start()
            _ = try await connection.waitUntilReady()
            _ = try await connection.request(.launchAgent(runtimeID: runtimeID, agent: .custom(server.customCommand),
                                                          workspace: request.workspace.path), timeout: .seconds(20))
            _ = try await connection.request(.newSession(runtimeID: runtimeID), timeout: .seconds(20))
            _ = try await connection.request(.prompt(runtimeID: runtimeID, turnID: UUID(), blocks: [.text("Outside hello")]),
                                             timeout: .seconds(20))
            try await until("the other runtime's turn to reach its agent") { lines(in: "prompts.log") == 4 }

            // On iPhone the list is under the session; back to it, as the back button goes.
            if root.isCollapsed { root.show(.primary) }
            try await until("the sessions list on screen") {
                root.sessions.viewIfLoaded?.window != nil && root.sessions.transitionCoordinator == nil
                    && root.shown?.controller.transitionCoordinator == nil
            }
            // Listed again, as pull to refresh does, until its turn has ended there.
            var listed: LatchRemoteRuntimeSummary?
            let deadline = ContinuousClock.now + .seconds(20)
            while listed == nil || listed?.activeTurnID != nil {
                guard ContinuousClock.now < deadline else { throw Failure("timed out waiting for the runtime under “On smoke”") }
                await library.refreshRuntimes(for: [server.id])
                listed = library.adoptableRuntimes(on: server.id).first { $0.runtimeID == runtimeID }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard listed?.title == "Outside hello" else {
                throw Failure("the runtime was listed as “\(listed?.title ?? "")”, not by its first prompt")
            }
            root.sessions.expandRuntimes(on: server.id)
            let item = SessionsViewController.Item.runtime(serverID: server.id, runtimeID: runtimeID.rawValue)
            var row: IndexPath?
            try await until("the runtime's row") {
                row = root.sessions.dataSource.indexPath(for: item)
                return row != nil
            }
            guard let row else { throw Failure("no row for the runtime") }
            root.sessions.collectionView(root.sessions.collectionView, didSelectItemAt: row)
            try await until("the adopted session on screen") {
                root.shown?.session.model.remoteBinding?.runtimeID == runtimeID.rawValue
                    && root.shown.map { root.isShowing($0.session.id) } == true
            }
            guard let adopted = root.shown?.session else { throw Failure("no adopted session") }
            let model = adopted.model
            try await until("its history", timeout: .seconds(20)) {
                model.phase == .ready && model.messages.map(\.text) == ["Outside hello", "onetwothree"]
            }
            guard model.messages.first?.role == .user, model.messages.last?.role == .assistant,
                  adopted.title == "Outside hello", adopted.pendingAdoption == nil else {
                throw Failure("the adopted history is not the other device's prompt and reply: "
                    + "\(model.messages.map { "\($0.role): \($0.text)" }), titled \(adopted.title)")
            }
            pass("\(device): runtime started elsewhere listed as “Outside hello”, adopted, its prompt and reply replayed")
            return adopted
        }

        // MARK: Scene

        /// What leaving the app and coming back does, through the scene delegate's own paths.
        /// Suspension drops every socket, so the links are dropped too.
        func backgroundAndForeground(_ sessions: [PhoneSession]) async throws {
            delegate.sceneWillResignActive(scene)
            delegate.sceneDidEnterBackground(scene)
            for client in connector.liveClients { client.dropConnectionForTesting() }
            try await until("both links lost") {
                sessions.allSatisfy { if case .reconnecting = $0.model.linkState { true } else { false } }
            }
            // Saved as the next launch reads them, each with the runtime it follows.
            let expected = Set(sessions.compactMap(\.model.remoteBinding?.runtimeID))
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                let saved = try? await SessionStore(directory: AppFiles.directory).load()
                if Set(saved?.sessions.compactMap(\.remote?.runtimeID) ?? []) == expected, expected.count == sessions.count { break }
                guard ContinuousClock.now < deadline else { throw Failure("going to the background did not save both sessions") }
                try await Task.sleep(for: .milliseconds(100))
            }
            delegate.sceneDidBecomeActive(scene)
            try await until("both sessions attached again", timeout: .seconds(20)) {
                sessions.allSatisfy { $0.model.linkState == .connected && $0.model.phase == .ready }
            }
            // The adopted one is on screen; a prompt there shows the attachment carries turns.
            guard let screen = root.shown?.controller as? SessionDetailViewController, screen.model === sessions[1].model
            else { throw Failure("the adopted session is no longer on screen") }
            try await send("Say hello again", in: screen)
            try await until("the reply after coming back") {
                screen.model.phase == .ready && screen.model.messages.last?.text == "onetwothree"
                    && screen.model.messages.count == 4
            }
            pass("\(device): background saved both sessions, foreground re-attached them, a prompt ran after")
        }

        func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + timeout
            while !condition() {
                guard ContinuousClock.now < deadline else { throw Failure("timed out waiting for \(what)") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
#endif
