import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `latch-server`'s entry point, kept in the library so the executable is only signal setup.
public enum LatchServerMain {
    /// Blocks SIGTERM, SIGINT and SIGHUP in the calling thread, so every thread created after
    /// it inherits the mask and only the `sigwait` thread sees them. Call it first in `main`,
    /// before any thread exists. SIGPIPE gets a handler that does nothing rather than
    /// `SIG_IGN`, which spawned agents would inherit; the Linux spawner resets both anyway.
    public static func prepareSignals() {
        var signals = terminationSignals
        pthread_sigmask(SIG_BLOCK, &signals, nil)
        signal(SIGPIPE, ignoreSignal)
    }

    /// Runs the command line (without the program name) and returns the exit status.
    public static func run(_ arguments: [String]) -> Int32 {
        let command: ServerCommand
        do {
            command = try ServerCommandLine.parse(arguments)
        } catch {
            printError("\(error)\n\n\(ServerCommandLine.usage)")
            return 2
        }
        switch command {
        case .help:
            print(ServerCommandLine.usage)
            return 0
        case .version:
            print("latch-server \(LatchServerVersion.current)")
            return 0
        case let .token(config, rotate):
            guard let tokens = tokenFile(config) else { return 1 }
            do {
                let token = rotate ? try tokens.rotate() : try tokens.readOrCreate()
                print(token.rawValue)
                if rotate {
                    printError("running servers drop connections that used the old token within \(LatchRemoteProtocol.heartbeatSeconds) seconds, or at once on SIGHUP")
                }
                return 0
            } catch {
                printError("\(error)")
                return 1
            }
        case let .pair(config, host, port, transport, qr):
            guard let tokens = tokenFile(config) else { return 1 }
            let pairing: String
            do {
                pairing = try LatchRemotePairing(host: host, port: port, transport: transport, token: tokens.readOrCreate()).string
            } catch let error as ServerTokenError {
                printError("\(error)")
                return 1
            } catch {
                printError("--host \(host): expected a host name or a numeric address")
                return 1
            }
            print(pairing)
            guard let qr else { return 0 }
            do {
                let symbol = try QRCode(pairing)
                print("\n" + symbol.terminalText(darkModules: qr == .darkModulesDrawn, colors: Self.standardOutputTakesColor),
                      terminator: "")
                return 0
            } catch {
                printError("--qr: the string is too long for a QR code (\(error)); paste it instead")
                return 1
            }
        case let .serve(options):
            return serve(options)
        }
    }

    // MARK: Serving

    private static func serve(_ options: ServeOptions) -> Int32 {
        let log = ServerLog()
        defer { log.flush() }
        let addresses: [ServerSocketAddress]
        do {
            addresses = try options.listenAddresses.map { value throws(ServerListenError) in try ServerListenPolicy.parse(value) }
        } catch {
            printError("\(error)")
            return 2
        }
        guard let tokens = tokenFile(options.config) else { return 1 }
        do {
            try tokens.readOrCreate()
        } catch {
            printError("\(error)")
            return 1
        }
        log.log("token file \(tokens.path)")

        let controller = ServeController(log: log)
        startSignalThread(controller)
        guard let listeners = ServerListenBinder.bind(
            addresses, allowUnencryptedNetwork: options.allowUnencryptedNetwork, log: log
        ) else { return 1 }

        let standardErrorLog = options.logAgentStandardError ? AgentStandardErrorLog(log: log) : nil
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.detachedTimeout = options.detachedTimeout
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var standardError: (@Sendable (AgentRuntimeID, Data) -> Void)?
        if let standardErrorLog {
            standardError = { id, data in standardErrorLog.receive(id, data) }
        }
        let lifecycle: @Sendable (AgentRuntimeID, RemoteRuntimeLifecycleEvent) -> Void = { id, event in
            switch event {
            case let .launched(title):
                log.log("runtime \(id.rawValue) launched: \(ServerLog.escape(title))")
            case .stopped:
                standardErrorLog?.forget(id)
                log.log("runtime \(id.rawValue) stopped")
            case let .exited(status):
                standardErrorLog?.forget(id)
                log.log("runtime \(id.rawValue) exited" + (status.map { " with status \($0)" } ?? ""))
            case let .failedToLaunch(title, executable, status, reason):
                standardErrorLog?.forget(id)
                log.log(RemoteRuntimeLifecycleEvent.failedLaunchLine(
                    id, agentTitle: title, executable: executable, status: status, reason: reason,
                    standardErrorLogged: standardErrorLog != nil))
            }
        }
        let service = LatchAgentService(clientInfo: ACPImplementation(
            name: "latch-server", title: "Latch Server", version: LatchServerVersion.current
        ))
        let hub = RemoteRuntimeHub(
            service: service,
            configuration: configuration,
            homeDirectory: home,
            standardError: standardError,
            lifecycle: lifecycle
        )
        wait { await hub.start() }
        let server = RemoteServer(
            hub: hub,
            tokens: tokens,
            configuration: RemoteServerConfiguration(serverInfo: RemoteServerConfiguration.localServerInfo(homeDirectory: home)),
            log: log
        )
        // Before start, so a signal from now on shuts the server down rather than exiting.
        controller.serving(server)
        server.start(listeners)
        for listener in listeners {
            log.log("listening on \(listener.address)")
        }
        controller.waitUntilStopped()
        log.log("stopped")
        return 0
    }

    private static func tokenFile(_ config: ConfigOptions) -> ServerTokenFile? {
        guard geteuid() != 0 || config.allowRoot else {
            printError("refusing to run as root: agents would run as root too; pass --allow-root to do it anyway")
            return nil
        }
        let directory = ServerConfigDirectory.resolve(
            explicit: config.configDirectory,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        do {
            try ServerConfigDirectory.prepare(directory)
        } catch {
            printError("\(error)")
            return nil
        }
        return ServerTokenFile(directory: directory)
    }

    private static var terminationSignals: sigset_t {
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGTERM)
        sigaddset(&signals, SIGINT)
        sigaddset(&signals, SIGHUP)
        return signals
    }

    private static func startSignalThread(_ controller: ServeController) {
        let thread = Thread {
            var signals = terminationSignals
            while true {
                var received: Int32 = 0
                guard sigwait(&signals, &received) == 0 else { continue }
                if received == SIGHUP {
                    controller.reload()
                } else {
                    controller.terminate(signalName: received == SIGINT ? "SIGINT" : "SIGTERM")
                }
            }
        }
        thread.name = "latch.server.signals"
        thread.start()
    }

    /// Runs `body` and blocks this thread, which is not a Swift concurrency thread, until it ends.
    private static func wait(_ body: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task {
            await body()
            done.signal()
        }
        done.wait()
    }

    static func printError(_ message: String) {
        ServerLog.writeToStandardError("latch-server: \(message)")
    }

    /// A terminal that has not asked for no colour, as NO_COLOR and TERM=dumb do.
    private static var standardOutputTakesColor: Bool {
        let environment = ProcessInfo.processInfo.environment
        return isatty(STDOUT_FILENO) == 1 && environment["NO_COLOR"].map(\.isEmpty) ?? true && environment["TERM"] != "dumb"
    }
}

private func ignoreSignal(_: Int32) {}

/// Binds every listen address under the listen policy. A tailnet address that is not up yet,
/// as when the server starts before tailscaled, is retried every `retryInterval` until
/// `retryLimit` has passed.
public enum ServerListenBinder {
    public static func bind(
        _ addresses: [ServerSocketAddress],
        allowUnencryptedNetwork: Bool,
        log: ServerLog,
        interfaces: () -> [ServerInterfaceAddress] = ServerListenPolicy.systemInterfaces,
        retryInterval: Duration = .seconds(2),
        retryLimit: Duration = .seconds(5 * 60)
    ) -> [ServerListener]? {
        var bound: [Int: ServerListener] = [:]
        var warned: Set<Int> = []
        var reportedWaiting = false
        let deadline = ContinuousClock.now + retryLimit
        func fail(_ message: String) -> [ServerListener]? {
            LatchServerMain.printError(message)
            bound.values.forEach { ServerSocket.close($0.descriptor) }
            return nil
        }
        while true {
            let available = interfaces()
            var waiting: [String] = []
            for (index, address) in addresses.enumerated() where bound[index] == nil {
                let decision = ServerListenPolicy.evaluate(address, allowUnencryptedNetwork: allowUnencryptedNetwork, interfaces: available)
                switch decision {
                case let .refused(message):
                    return fail(message)
                case let .tailnetNotUp(message):
                    waiting.append(message)
                    continue
                case let .allowedUnencrypted(message):
                    if warned.insert(index).inserted { log.log("warning: \(message)") }
                case .allowed:
                    break
                }
                do {
                    bound[index] = try ServerListener.bind(address)
                } catch where error.code == EADDRNOTAVAIL && LatchRemoteAddressPolicy.classify(address.bytes) == .tailnet {
                    waiting.append("\(address) is not available yet")
                } catch {
                    return fail("cannot listen on \(address): \(error)")
                }
            }
            if waiting.isEmpty { return addresses.indices.map { bound[$0]! } }
            guard ContinuousClock.now < deadline else {
                return fail("gave up after \(retryLimit): " + waiting.joined(separator: "; "))
            }
            if !reportedWaiting {
                reportedWaiting = true
                log.log("waiting for Tailscale: " + waiting.joined(separator: "; "))
            }
            Thread.sleep(forTimeInterval: Double(retryInterval.components.seconds) + Double(retryInterval.components.attoseconds) / 1e18)
        }
    }
}

/// Where serving is, for the signal thread.
private final class ServeController: Sendable {
    private enum Phase {
        case starting
        case serving(RemoteServer)
        case stopping
    }

    private let log: ServerLog
    private let phase = Mutex(Phase.starting)
    private let stopped = DispatchSemaphore(value: 0)

    init(log: ServerLog) {
        self.log = log
    }

    func serving(_ server: RemoteServer) {
        phase.withLock { $0 = .serving(server) }
    }

    func waitUntilStopped() {
        stopped.wait()
    }

    func terminate(signalName: String) {
        enum Action {
            case exitNow
            case shutDown(RemoteServer)
            case ignore
        }
        let action: Action = phase.withLock { phase in
            switch phase {
            case .starting:
                return .exitNow
            case let .serving(server):
                phase = .stopping
                return .shutDown(server)
            case .stopping:
                return .ignore
            }
        }
        switch action {
        case .exitNow:
            // Nothing runs yet: no agent, no connection.
            log.log("\(signalName) before serving began; exiting")
            log.flush()
            exit(0)
        case let .shutDown(server):
            log.log("\(signalName): shutting down")
            let stopped = stopped
            Task {
                await server.shutdown()
                stopped.signal()
            }
        case .ignore:
            break
        }
    }

    func reload() {
        guard case let .serving(server) = phase.withLock({ $0 }) else { return }
        log.log("SIGHUP: checking the token file")
        server.checkToken()
    }
}
