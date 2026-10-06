#if DEBUG
import LatchACP
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import UIKit

/// `--ui-fixture <screen>`: the real app over made-up servers and sessions, with nothing read
/// or saved and no network, so a screen can be captured with `xcrun simctl io screenshot` in
/// any appearance and text size the Simulator is set to. Debug builds only. The shell's
/// screens are onboarding, sessions, new-session, servers, server-add (from a link),
/// server-add-manual, scanner (which the Simulator cannot scan with), server-edit and banner;
/// `sessionScreens` are one session open, its agent scripted.
@MainActor
enum UIFixture {
    static let argument = "--ui-fixture"
    /// A conversation from its end, and from its reply's start; a turn streaming, with Stop;
    /// the composer with photos, and suggesting slash commands; a permission request; Claude
    /// Code's questions, and its plan waiting for approval; the link lost mid-turn; a server
    /// that cannot be reached; a new session with nothing in it yet; a turn with thinking, two
    /// subagents and a plan, one subagent open, and with the plan open instead; messages
    /// waiting for a turn to end, under its plan; the agent's saved conversations, offered to
    /// a new session; and on iPad, the split view with the list beside the session.
    static let sessionScreens = ["conversation", "markdown", "streaming", "photos", "slash", "permission", "question",
                                 "plan-approval", "reconnecting", "error", "empty", "subagents", "plan", "queue", "resume",
                                 "split"]

    static var requestedScreen: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "sessions"
    }

    nonisolated static let vps = ServerProfile(id: UUID(uuidString: "5E8A1F43-3C0B-4F7A-9E0B-6E1A2B3C4D01")!, name: "vps",
                                   host: "vps.tailnet.ts.net", token: .generate(), customCommand: "mock-agent")
    nonisolated static let mini = ServerProfile(id: UUID(uuidString: "5E8A1F43-3C0B-4F7A-9E0B-6E1A2B3C4D02")!, name: "Studio Mac",
                                    host: "studio.local", port: 7801, token: .generate())
    nonisolated static let pi = ServerProfile(id: UUID(uuidString: "5E8A1F43-3C0B-4F7A-9E0B-6E1A2B3C4D03")!, name: "Pi",
                                  host: "pi.home.arpa", token: .generate())

    nonisolated static let info = LatchRemoteServerInfo(version: "0.1.0", hostname: "vps", os: "Ubuntu 24.04", arch: "x86_64",
                                            home: "/home/simon")

    /// vps answers; Studio Mac refuses to be sent the token; Pi never answers.
    nonisolated static let check: ServerCheck = { options in
        switch options.host {
        case vps.host: return info
        case pi.host:
            try await Task.sleep(for: .seconds(600))
            throw LatchRemoteClientError.timedOut
        default: throw LatchRemoteClientError.destinationNotAllowed(address: "192.168.1.20")
        }
    }

    /// vps runs two agents no session here follows; Studio Mac cannot be reached.
    nonisolated static let runtimes: RuntimeListing = { options in
        guard options.host == vps.host else { throw LatchRemoteClientError.timedOut }
        return [LatchRemoteRuntimeSummary(runtimeID: AgentRuntimeID("fixture-api"), agentTitle: "Claude Code",
                                          workspace: "/home/simon/api", lifecycle: .ready, activeTurnID: UUID()),
                LatchRemoteRuntimeSummary(runtimeID: AgentRuntimeID("fixture-dotfiles"), agentTitle: "Codex",
                                          workspace: "/home/simon/dotfiles", lifecycle: .ready, pendingPermissionCount: 1)]
    }

    static func root(for screen: String) -> RootViewController {
        let empty = ["onboarding", "scanner", "server-add-manual"].contains(screen)
        let store = InMemoryServerStore(empty ? [] : [vps, mini, pi])
        let library = SessionLibrary(servers: store, connector: ScriptedConnector(), store: nil, listRuntimes: runtimes)
        if !empty { populate(library, now: Date(), scripted: sessionScreens.contains(screen)) }
        let defaults = UserDefaults(suiteName: "dev.latchapp.ios.fixture") ?? .standard
        let memory = ServerMemory(defaults: defaults)
        // vps's home is known, as after any handshake with it; Studio Mac never answered.
        memory.recordHome(info.home, address: vps.address)
        return RootViewController(library: library, servers: store, check: check, badge: nil, defaults: defaults,
                                  memory: memory, makeSessionViewController: SessionDetailViewController.make)
    }

    /// Sessions in every state a row can show, their statuses stated rather than driven. With
    /// `scripted`, the first is a real one whose agent the session screens script instead.
    static func populate(_ library: SessionLibrary, now: Date, scripted: Bool = false) {
        func add(_ title: String, on server: ServerProfile, path: String, agent: AgentPreset, command: String = "",
                 status: (inout SessionRowStatus.Input) -> Void) {
            let saved = SavedSession(id: UUID(), workspacePath: path, title: title, agentID: agent.rawValue,
                                     customCommand: command, draft: "", messages: [], serverID: server.id)
            let session = PhoneSession(saved: saved, connector: library.connector)
            var input = SessionRowStatus.Input(phase: .ready, status: "Connected", lastActiveAt: now.addingTimeInterval(-60))
            status(&input)
            session.stubbedStatus = input
            library.add(session)
        }
        if !scripted {
            add("Fix the flaky reconnect test", on: vps, path: "/home/simon/latch", agent: .claudeCode) {
                $0.phase = .prompting; $0.status = "Working…"; $0.promptStartedAt = now.addingTimeInterval(-74)
                $0.lastActiveAt = now.addingTimeInterval(-10)
            }
        }
        add("Update the release notes for 0.2", on: vps, path: "/home/simon/latch", agent: .codex) {
            $0.phase = .prompting; $0.needsApproval = true; $0.lastActiveAt = now.addingTimeInterval(-40)
        }
        add("Why does the build cache miss on CI?", on: vps, path: "/home/simon/infra", agent: .fx) {
            $0.hasUnseenReply = true; $0.lastActiveAt = now.addingTimeInterval(-600)
        }
        add("Tidy the README", on: vps, path: "/home/simon/site", agent: .custom, command: "mock-agent --acp") {
            $0.phase = .disconnected; $0.lastActiveAt = now.addingTimeInterval(-3 * 86_400)
        }
        add("Profile the transcript scroll", on: mini, path: "/Users/simon/Developer/latch", agent: .claudeCode) {
            $0.phase = .prompting; $0.linkState = .reconnecting(server: "Studio Mac", since: now)
            $0.lastActiveAt = now.addingTimeInterval(-120)
        }
        add("Try the new icon", on: mini, path: "/Users/simon/Developer/icons", agent: .openCode) {
            $0.phase = .disconnected; $0.hasError = true; $0.status = "Not connected"; $0.lastActiveAt = now.addingTimeInterval(-7200)
        }
        add("Benchmark the parser", on: mini, path: "/Users/simon/Developer/parser", agent: .codex) {
            $0.phase = .disconnected; $0.stoppedHere = true; $0.lastActiveAt = now.addingTimeInterval(-86_400)
        }
    }

    /// Puts `screen` up once the window is on screen, then prints `UI FIXTURE: <screen> ready`
    /// for whoever takes the screenshot; sheets and banners may still be animating in.
    static func present(_ screen: String, in root: RootViewController) {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if sessionScreens.contains(screen) {
                await presentSession(screen, in: root)
            } else {
                await presentShell(screen, in: root)
            }
            FileHandle.standardOutput.write(Data("UI FIXTURE: \(screen) ready\n".utf8))
        }
    }

    private static func presentShell(_ screen: String, in root: RootViewController) async {
        let library = root.library
        switch screen {
        case "sessions":
            await library.refreshRuntimes()
            root.sessions.expandRuntimes(on: vps.id)
        case "new-session": root.presentNewSession(serverID: vps.id)
        case "servers": root.presentServers()
        case "server-add":
            root.presentServerEditor(pairing: try? LatchRemotePairing(host: "vps.tailnet.ts.net", token: .generate()))
            try? await Task.sleep(for: .milliseconds(600))
            editor(in: root)?.testConnection()
        case "server-add-manual": root.presentServerEditor()
        case "scanner": root.presentScanner()
        case "server-edit":
            root.presentServerEditor(serverID: mini.id)
            try? await Task.sleep(for: .milliseconds(600))
            editor(in: root)?.testConnection()
        case "banner":
            root.banners.fixedDuration = .seconds(600)
            if let session = library.sessions(on: vps.id).dropFirst().first { library.onAttention?(session, .needsApproval) }
        default: break
        }
    }

    private static func editor(in root: RootViewController) -> ServerEditorViewController? {
        (root.presentedViewController as? UINavigationController)?.topViewController as? ServerEditorViewController
    }

    // MARK: Session screens

    /// Opens a session on vps through the root, as a tap on its row does, and scripts its agent
    /// into the state `screen` names.
    private static func presentSession(_ screen: String, in root: RootViewController) async {
        let library = root.library
        let messages: [ChatMessage] = switch screen {
        case "empty", "photos", "slash", "resume": []
        case "streaming", "reconnecting", "queue": [SampleConversation.prompt, SampleConversation.read]
        case "permission", "question", "plan-approval": [SampleConversation.prompt]
        case "subagents", "plan": SampleSubagents.messages
        default: SampleConversation.messages
        }
        let saved = SavedSession(id: UUID(), workspacePath: "/home/simon/latch",
                                 title: messages.isEmpty ? PhoneSession.untitled : "Fix the flaky reconnect test",
                                 agentID: AgentPreset.claudeCode.rawValue, customCommand: "", draft: "", messages: messages,
                                 agentSessionID: messages.isEmpty ? nil : ScriptedSessionClient.sessionID,
                                 lastActiveAt: Date().addingTimeInterval(-10), serverID: vps.id)
        // Claude Code lists its saved conversations here, as it does in a real folder.
        (library.connector as? ScriptedConnector)?.conversations = screen == "resume" ? SampleConversations.list : nil
        let session = PhoneSession(saved: saved, connector: library.connector)
        library.add(session)
        // The photo with the last prompt was sent from this device, so its picture is kept.
        if messages.contains(SampleConversation.followUp) {
            SentImageCache.shared.store([UIImage(data: photo(hues: (0.58, 0.62), width: 900, height: 1200))],
                                        for: SampleConversation.followUp.id)
        }
        let client = (library.connector as? ScriptedConnector)?.latest
        if screen == "error" {
            client?.failNextLaunch(with: UnreachableServer(
                message: "vps refused the connection at vps.tailnet.ts.net:7800. Check that latch-server is running."))
        }
        if screen == "split" {
            await library.refreshRuntimes()
            root.sessions.expandRuntimes(on: vps.id)
        }
        root.show(session)
        guard let client, let screenController = root.shown?.controller as? SessionDetailViewController else { return }
        let model = session.model
        if screen == "error" { return }
        await until { model.phase == .ready }
        // A conversation under way has used some of the context; the streaming one most of it.
        if !messages.isEmpty {
            client.usage(used: screen == "streaming" ? 168_400 : 62_300, size: 200_000, cost: screen == "streaming" ? 2.86 : 0.41)
        }
        switch screen {
        case "markdown":
            await until { screenController.transcript.order.count == messages.count }
            try? await Task.sleep(for: .milliseconds(300))
            let transcript = screenController.transcript
            if let row = transcript.order.firstIndex(of: SampleConversation.answer.id) {
                transcript.collectionView.scrollToItem(at: IndexPath(item: row, section: 0), at: .top, animated: false)
                transcript.scrollViewDidEndDragging(transcript.collectionView, willDecelerate: false)
            }
        case "streaming", "reconnecting":
            type("Now fix it, and run the test ten times to be sure.", in: screenController)
            screenController.send()
            await until { client.hasOpenTurn }
            client.tool("edit", title: "Edit Tests/RemoteSessionLiveTests.swift", status: "completed")
            client.tool("run", title: "`swift test --filter RemoteSessionLiveTests`", status: "in_progress")
            client.chunk("I changed the restart to keep its port. Running the test ten times now; so far ")
            client.chunk("**7 of 10** passed without a retry, and")
            if screen == "reconnecting" {
                client.emit(.link(.reconnecting(server: vps.name, since: Date())))
            }
        case "photos":
            let images = [(0.35, 0.55), (0.6, 0.45), (0.12, 0.7)].enumerated().compactMap { index, hues in
                ComposerImage.make(from: photo(hues: hues, width: 800 + index * 200, height: 600),
                                   name: "Screenshot \(index + 1)")
            }
            screenController.add(images)
            type("What is wrong with these three screens? The spacing looks off on the second.", in: screenController)
        case "slash":
            client.availableCommands([("compact", "Summarise the conversation to free up context"),
                                      ("review", "Review the current diff"), ("init", "Write a CLAUDE.md for this repository"),
                                      ("cost", "Show what this session has cost")])
            await until { model.commands.count == 4 }
            screenController.composer.textView.becomeFirstResponder()
            type("/", in: screenController)
        case "queue":
            client.plan(SampleSubagents.plan)
            type("Now fix it, and run the test ten times to be sure.", in: screenController)
            screenController.send()
            await until { client.hasOpenTurn }
            client.chunk("I changed the restart to keep its port. Running the test ten times now; so far **7 of 10** passed.")
            type("Then commit it, with a message that says why the port has to stay", in: screenController)
            screenController.send()
            if let image = ComposerImage.make(from: photo(hues: (0.58, 0.62), width: 900, height: 1200), name: "CI log") {
                screenController.add([image])
            }
            type("And compare with this run", in: screenController)
            screenController.send()
            type("Also check the Linux runner", in: screenController)
        case "resume":
            screenController.resumeConversation()
        case "subagents", "plan":
            client.plan(SampleSubagents.plan)
            await until { model.plan.count == SampleSubagents.plan.count }
            if screen == "plan" {
                screenController.composer.planView.toggle()
            } else {
                screenController.transcript.toggle(SampleSubagents.server.id)
            }
            try? await Task.sleep(for: .milliseconds(300))
            screenController.transcript.scrollToBottom(animated: false)
        case "permission":
            type("Clean the build folder and rebuild", in: screenController)
            screenController.send()
            await until { client.hasOpenTurn }
            client.requestPermission(title: "rm -rf .build && swift build", command: "rm -rf .build && swift build")
        case "question", "plan-approval":
            type("Fix the reconnect test", in: screenController)
            screenController.send()
            await until { client.hasOpenTurn }
            if screen == "question" { client.ask() } else { client.requestPlanApproval() }
        default:
            break
        }
    }

    private static func type(_ text: String, in screen: SessionDetailViewController) {
        screen.composer.textView.text = text
        screen.composer.textViewDidChange(screen.composer.textView)
    }

    /// Waits up to five seconds for what the scripted agent's events bring about.
    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A made-up screenshot: two bands of colour and a panel, so each photo is told apart.
    private static func photo(hues: (Double, Double), width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor(hue: hues.0, saturation: 0.45, brightness: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor(hue: hues.1, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 6))
            UIColor.white.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: CGRect(x: width / 8, y: height / 3, width: width * 3 / 4, height: height / 2),
                         cornerRadius: 24).fill()
        }
    }
}

/// Gives every session a scripted agent. A model makes its client as it is made, so the
/// latest client is the latest session's.
@MainActor
final class ScriptedConnector: RemoteSessionConnector {
    private(set) var latest: ScriptedSessionClient?
    /// What the next clients' agent lists as its saved conversations; nil lists none.
    var conversations: [ACPSessionSummary]?

    func makeClient(serverID: UUID) -> AgentServiceClient {
        let client = ScriptedSessionClient(configOptions: ScriptedConfiguration.options, conversations: conversations)
        latest = client
        return client
    }
}

/// Claude Code's saved conversations in ~/latch, as `session/list` gives them: titled, and one
/// not yet, newest first once sorted.
enum SampleConversations {
    static let list = [
        ACPSessionSummary(sessionId: "c1", cwd: "/home/simon/latch", title: "Keep the listener's port across a restart of the loopback server, and check it fifty times on Linux",
                          updatedAt: "2026-09-28T09:15:00Z"),
        ACPSessionSummary(sessionId: "c2", cwd: "/home/simon/latch", title: "Fix the flaky reconnect test",
                          updatedAt: "2026-10-03T16:42:00Z"),
        ACPSessionSummary(sessionId: "c3", cwd: "/home/simon/latch", title: "Update the release notes for 0.2",
                          updatedAt: "2026-09-21T11:03:00Z"),
        ACPSessionSummary(sessionId: "c4", cwd: "/home/simon/latch"),
    ]
}
#endif
