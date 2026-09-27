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
#endif
