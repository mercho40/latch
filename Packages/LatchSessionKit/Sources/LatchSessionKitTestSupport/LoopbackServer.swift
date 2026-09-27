#if os(macOS)
import Foundation
import LatchAgentCore
import LatchAgentServer
import LatchRemoteProtocol
import LatchServiceProtocol
import LatchSessionKit

/// `latch-server`'s hub and network layer over this Mac's agent service, listening on an
/// ephemeral loopback port, with its token in a private folder of its own.
@MainActor
public final class LoopbackServer {
    public let workspace: URL
    public private(set) var hub: RemoteRuntimeHub
    public private(set) var server: RemoteServer
    public let port: UInt16
    public let store: InMemoryServerStore
    private let configDirectory: String
    private let tokens: ServerTokenFile
    private let configuration: RemoteRuntimeHubConfiguration
    private var control: RemoteConnectionID
    /// More listeners on the same hub, as a server reached at a second address would be.
    private var others: [RemoteServer] = []

    public static func run(hub configuration: RemoteRuntimeHubConfiguration = RemoteRuntimeHubConfiguration(),
                           _ body: (LoopbackServer) async throws -> Void) async throws {
        let server = try await LoopbackServer(hub: configuration)
        do { try await body(server) } catch {
            await server.close()
            throw error
        }
        await server.close()
    }

    init(hub configuration: RemoteRuntimeHubConfiguration) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("LatchLoopback-\(UUID().uuidString)")
        configDirectory = root.appendingPathComponent("LatchLoopbackConfig-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try RemoteMockAgent.script.write(to: workspace.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        try ServerConfigDirectory.prepare(configDirectory)
        tokens = ServerTokenFile(directory: configDirectory)
        let token = try tokens.readOrCreate()
        self.configuration = configuration
        hub = RemoteRuntimeHub(service: LatchAgentService(), configuration: configuration, homeDirectory: workspace.path)
        control = hub.openConnection(wake: {})
        await hub.start()
        let listener = try ServerListener.bind(ServerSocketAddress(bytes: [127, 0, 0, 1], port: 0))
        port = listener.address.port
        server = Self.serve(hub, tokens: tokens, home: workspace.path, on: listener)
        store = InMemoryServerStore([ServerProfile(
            name: "loopback", host: "127.0.0.1", port: port, token: token,
            customCommand: "/bin/sh " + AgentCommand.quotedArgument(workspace.appendingPathComponent("agent.sh").path))])
    }

    private static func serve(_ hub: RemoteRuntimeHub, tokens: ServerTokenFile, home: String,
                              on listener: ServerListener) -> RemoteServer {
        let server = RemoteServer(
            hub: hub, tokens: tokens,
            configuration: RemoteServerConfiguration(serverInfo: LatchRemoteServerInfo(
                version: "9.9.9", hostname: "loopback", os: "macOS", arch: "arm64", home: home)),
            log: ServerLog(sink: { _ in }))
        server.start([listener])
        return server
    }

    /// Shuts the server down, which stops every agent it runs, and starts a fresh one at the
    /// same address with the same token, as a reboot of the machine would.
    public func restart() async throws {
        await server.shutdown()
        hub = RemoteRuntimeHub(service: LatchAgentService(), configuration: configuration, homeDirectory: workspace.path)
        control = hub.openConnection(wake: {})
        await hub.start()
        server = Self.serve(hub, tokens: tokens, home: workspace.path,
                            on: try ServerListener.bind(ServerSocketAddress(bytes: [127, 0, 0, 1], port: port)))
    }

    /// Serves the same hub, runtimes and token on another loopback port, and returns the port.
    public func listenOnAnotherPort() throws -> UInt16 {
        let listener = try ServerListener.bind(ServerSocketAddress(bytes: [127, 0, 0, 1], port: 0))
        others.append(Self.serve(hub, tokens: tokens, home: workspace.path, on: listener))
        return listener.address.port
    }

    /// Stops the server as SIGTERM does, which stops every agent it runs.
    public func shutdown() async {
        await server.shutdown()
    }

    public var profile: ServerProfile { store.servers[0] }
    public var agentCommand: String { profile.customCommand }

    /// Replaces the server's token and drops every connection that used the old one.
    public func rotateToken() throws -> LatchRemoteToken {
        let token = try tokens.rotate()
        server.checkToken()
        return token
    }

    public func summary(_ id: AgentRuntimeID) async throws -> LatchRemoteRuntimeSummary? {
        try await runtimes().first { $0.runtimeID == id }
    }

    /// The one runtime a test launched.
    public func onlyRuntime() async throws -> AgentRuntimeID {
        let runtimes = try await runtimes()
        guard runtimes.count == 1 else { throw LoopbackError(description: "expected one runtime, found \(runtimes.count)") }
        return runtimes[0].runtimeID
    }

    private func runtimes() async throws -> [LatchRemoteRuntimeSummary] {
        guard case let .success(.runtimes(runtimes)) = await hub.handle(.listRuntimes, from: control) else {
            throw LoopbackError(description: "listRuntimes failed")
        }
        return runtimes
    }

    /// Lines the mock agent wrote to a log in its folder.
    public func lines(in file: String) -> Int {
        let text = (try? String(contentsOf: workspace.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    public func close() async {
        for other in others { await other.shutdown() }
        await server.shutdown()
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(atPath: configDirectory)
    }

    public struct LoopbackError: Error, CustomStringConvertible {
        public let description: String
    }
}

/// An ACP agent in `sh` for remote sessions. Every `case` matches one JSON key, never two:
/// Latch's encoder orders keys differently in every process. The prompt's text picks the
/// turn; a load replays `earlier question`, `earlier answer` and a tool row, as a saved
/// conversation; `prompts.log`, `decisions.log` and `loads.log` count what reached the agent, and
/// `slow.log`, `asked.log`, `tools.log`, `flood.log` and `deluge.log` when a turn got that far. A `fail-new`
/// file fails session/new. The `tools` and `flood` turns hold after their first output until
/// a `go` file appears, and exit with status 3 if a `die` file appears first; so does a load,
/// before its history, while there is a `hold-load` file, and so does `deluge`, which streams about 12 KB, a tool row and `mid` first. A hold also ends that way after a
/// minute, or once the process that started the agent has gone, so a test run that dies
/// mid-turn leaves no agent behind. `SmokeAgent.remoteScript` is the
/// bundle smoke's cut-down copy: a change to the JSON Latch writes must keep both matching.
public enum RemoteMockAgent {
    public static let script = #"""
    PATH=/usr/bin:/bin:$PATH
    prompt_id=
    reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
    fail() { printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\n' "$1" "$2" "$3"; }
    chunk() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$1"; }
    tool() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"%s","toolCallId":"call-7","title":"Read notes","status":"%s"}}}\n' "$1" "$2"; }
    said() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$1"; }
    hold() { n=0; while [ ! -f go ]; do if [ -f die ] || ! kill -0 "$PPID" 2>/dev/null || [ $n -ge 1200 ]; then exit 3; fi; n=$((n+1)); sleep 0.05; done; }
    ask() {
      printf '%s\n' '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"call-1","title":"Edit file"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
    }
    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *\"method\":\"initialize\"*)
          reply "$id" '{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}' ;;
        *\"method\":\"session*/new\"*)
          if [ -f fail-new ]; then fail "$id" -32603 "No sessions today"; continue; fi
          reply "$id" '{"sessionId":"session-1","modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]},"models":{"currentModelId":"model-a","availableModels":[{"modelId":"model-a","name":"Model A"},{"modelId":"model-b","name":"Model B"}]}}' ;;
        *\"method\":\"session*/load\"*)
          echo load >> loads.log
          if [ -f hold-load ]; then hold; fi
          said earlier; said " question"; chunk "earlier answer"
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-h","title":"Read history","status":"completed"}}}'
          reply "$id" '{"modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]}}' ;;
        *\"method\":\"session*/set_mode\"*)
          reply "$id" '{}' ;;
        *\"method\":\"session*/set_model\"*)
          reply "$id" '{}' ;;
        *\"method\":\"session*/prompt\"*)
          echo prompt >> prompts.log
          prompt_id=$id
          case "$line" in
            *permission*) chunk asking; ask ;;
            *slow*) chunk one; sleep 1; chunk two; chunk three; echo done >> slow.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *later*) sleep 1; chunk asking; ask; echo asked >> asked.log ;;
            *signin*) fail "$id" -32000 "Authentication required" ;;
            *broken*) fail "$id" -32603 "Something broke" ;;
            *crash*) exit 3 ;;
            *oversize*) chunk "$(printf '%04000d' 0)"; chunk after; reply "$id" '{"stopReason":"end_turn"}' ;;
            *tools*) chunk reading; tool tool_call pending; hold; tool tool_call_update completed; chunk done
              echo done >> tools.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *deluge*) chunk start; i=0
              while [ $i -lt 40 ]; do chunk "$(printf '%0300d' $i)"; i=$((i+1)); done
              tool tool_call pending; chunk mid; hold; tool tool_call_update completed; chunk done
              echo done >> deluge.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *flood*) chunk start; hold; i=0
              while [ $i -lt 40 ]; do chunk "$(printf '%0300d' $i)"; i=$((i+1)); done
              chunk end; echo done >> flood.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *) chunk one; chunk two; chunk three; reply "$id" '{"stopReason":"end_turn"}' ;;
          esac ;;
        *\"id\":900[,}]*)
          echo decision >> decisions.log
          case "$line" in
            *allow-once*) chunk allowed; reply "$prompt_id" '{"stopReason":"end_turn"}' ;;
            *reject-once*) chunk rejected; reply "$prompt_id" '{"stopReason":"end_turn"}' ;;
            *) reply "$prompt_id" '{"stopReason":"cancelled"}' ;;
          esac ;;
      esac
    done
    """#
}
#endif
