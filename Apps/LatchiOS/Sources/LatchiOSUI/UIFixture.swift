#if DEBUG
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit
import UIKit

/// `--ui-fixture <screen>`: the real app over made-up servers and sessions, with nothing read
/// or saved and no network, so a screen can be captured with `xcrun simctl io screenshot` in
/// any appearance and text size the Simulator is set to. Debug builds only. The screens:
/// onboarding, sessions, new-session, servers, server-add, server-edit, banner.
@MainActor
enum UIFixture {
    static let argument = "--ui-fixture"

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
        let store = InMemoryServerStore(screen == "onboarding" ? [] : [vps, mini, pi])
        let library = SessionLibrary(servers: store, connector: UnconnectedRemoteSessionConnector(), store: nil,
                                     listRuntimes: runtimes)
        if screen != "onboarding" { populate(library, now: Date()) }
        return RootViewController(library: library, servers: store, check: check, badge: nil,
                                  defaults: UserDefaults(suiteName: "dev.latchapp.ios.fixture") ?? .standard)
    }

    /// Sessions in every state a row can show, their statuses stated rather than driven.
    static func populate(_ library: SessionLibrary, now: Date) {
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
        add("Fix the flaky reconnect test", on: vps, path: "/home/simon/latch", agent: .claudeCode) {
            $0.phase = .prompting; $0.status = "Working…"; $0.promptStartedAt = now.addingTimeInterval(-74)
            $0.lastActiveAt = now.addingTimeInterval(-10)
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

    /// Puts `screen` up once the window is on screen.
    static func present(_ screen: String, in root: RootViewController) {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            let library = root.library
            switch screen {
            case "sessions":
                await library.refreshRuntimes()
                root.sessions.expandRuntimes(on: vps.id)
                if root.traitCollection.horizontalSizeClass == .regular, let first = library.sessions(on: vps.id).first {
                    root.show(first)
                }
            case "new-session": root.presentNewSession(serverID: vps.id)
            case "servers": root.presentServers()
            case "server-add":
                root.presentServerEditor(pairing: try? LatchRemotePairing(host: "vps.tailnet.ts.net", token: .generate()))
                try? await Task.sleep(for: .milliseconds(600))
                editor(in: root)?.testConnection()
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
    }

    private static func editor(in root: RootViewController) -> ServerEditorViewController? {
        (root.presentedViewController as? UINavigationController)?.topViewController as? ServerEditorViewController
    }
}
#endif
