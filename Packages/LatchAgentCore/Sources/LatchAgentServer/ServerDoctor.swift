import Foundation
import LatchAgentCore
import LatchRemoteProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `latch-server doctor`: checks what serving from this machine needs the way `latch-server`
/// itself would, creating and changing nothing, and says what to do about each problem.
struct ServerDoctor {
    enum Mark: String, Sendable {
        case ok = "✓"
        case problem = "✗"
        case note = "·"
    }

    struct Finding: Equatable, Sendable {
        var mark: Mark
        var text: String
    }

    struct Section: Equatable, Sendable {
        var title: String
        var findings: [Finding]
    }

    /// What answered a hello at a listen address.
    enum Answer: Equatable, Sendable {
        case welcomed(version: String, hostname: String)
        case rejected(LatchRemoteRejectReason)
        case nothingListening
        case notLatch
        case unreachable(String)
    }

    var configDirectory: String
    var owner: uid_t
    var runsAsRoot: Bool
    var allowRoot: Bool
    var listen: [ServerSocketAddress]
    var allowUnencryptedNetwork: Bool
    var interfaces: [ServerInterfaceAddress]
    var environment: AgentLaunchEnvironment
    var homeDirectory: String
    /// `node --version` for the executable at a path, such as `v22.10.0`.
    var nodeVersion: (String) -> String?
    /// Sends a hello with the token to a listen address and reports what answered.
    var ask: (ServerSocketAddress, LatchRemoteToken) -> Answer

    func sections() -> [Section] {
        let (configuration, token) = configurationSection()
        return [configuration, networkSection(token: token), agentsSection()]
    }

    static func hasProblems(_ sections: [Section]) -> Bool {
        sections.contains { $0.findings.contains { $0.mark == .problem } }
    }

    static func render(_ sections: [Section], header: String) -> String {
        var lines = [header]
        for section in sections {
            lines.append("")
            lines.append(section.title)
            lines += section.findings.map { "  \($0.mark.rawValue) \($0.text)" }
        }
        let problems = sections.reduce(0) { $0 + $1.findings.count { $0.mark == .problem } }
        lines.append("")
        lines.append(problems == 0 ? "No problems found." : problems == 1 ? "1 problem." : "\(problems) problems.")
        return lines.joined(separator: "\n")
    }

    // MARK: Configuration

    /// With the server token, when it can be read, for the network checks.
    private func configurationSection() -> (Section, LatchRemoteToken?) {
        var findings: [Finding] = []
        func add(_ mark: Mark, _ text: String) { findings.append(Finding(mark: mark, text: text)) }
        let title = "Configuration"
        if runsAsRoot, !allowRoot {
            add(.problem, "running as root: agents would run as root too; run latch-server as an ordinary user")
        }
        var status = stat()
        if lstat(configDirectory, &status) != 0, errno == ENOENT {
            add(.note, "\(abbreviated(configDirectory)) does not exist yet; latch-server creates it, with the server token, when it first runs")
            return (Section(title: title, findings: findings), nil)
        }
        do {
            try ServerConfigDirectory.check(configDirectory, owner: owner)
            add(.ok, "\(abbreviated(configDirectory)) is private to this user")
        } catch {
            add(.problem, "\(error)")
            return (Section(title: title, findings: findings), nil)
        }

        var token: LatchRemoteToken?
        do {
            token = try ServerTokenFile(directory: configDirectory, owner: owner).read()
            add(.ok, "the server token is private")
        } catch .missing {
            add(.note, "no server token yet; latch-server creates one when it first runs")
        } catch {
            add(.problem, "\(error)")
        }

        do {
            let devices = try ServerDeviceTokens(configDirectory: configDirectory, owner: owner).read()
            let usable = devices.filter { (try? $0.token.get()) != nil }.map(\.name)
            if devices.isEmpty {
                add(.note, "no device has a token of its own; `latch-server pair --device NAME` gives one a token you can revoke alone")
            } else if !usable.isEmpty {
                add(.ok, (usable.count == 1 ? "1 device has" : "\(usable.count) devices have") + " a token of its own: " + usable.joined(separator: ", "))
            }
            for case let (name, .failure(error)) in devices {
                add(.problem, "device \(name) is refused: \(error)")
            }
        } catch {
            add(.problem, "\(error)")
        }
        return (Section(title: title, findings: findings), token)
    }

    // MARK: Network

    private func networkSection(token: LatchRemoteToken?) -> Section {
        var findings: [Finding] = []
        func add(_ mark: Mark, _ text: String) { findings.append(Finding(mark: mark, text: text)) }
        let tailnet = interfaces.filter { interface in
            LatchRemoteAddressPolicy.classify(interface.address) == .tailnet
                && ServerListenPolicy.defaultTunnelPrefixes.contains { interface.name.hasPrefix($0) }
        }

        for address in listen {
            switch ServerListenPolicy.evaluate(address, allowUnencryptedNetwork: allowUnencryptedNetwork, interfaces: interfaces) {
            case .allowed:
                let tunnel = tailnet.first { LatchRemoteAddressPolicy.unmapped($0.address) == LatchRemoteAddressPolicy.unmapped(address.bytes) }
                add(.ok, "\(address) is " + (tunnel.map { "Tailscale's address on \($0.name)" } ?? "loopback: only this machine, an SSH tunnel or a proxy on it reaches it"))
            case let .allowedUnencrypted(message):
                add(.note, message)
            case let .tailnetNotUp(message):
                add(.problem, message + "; start Tailscale, or listen on another address")
            case let .refused(message):
                add(.problem, message)
            }
            guard let token else { continue }
            let target = Self.reachable(address)
            switch ask(target, token) {
            case let .welcomed(version, hostname):
                add(.ok, "latch-server \(version) on \(hostname) answers at \(target) and accepts the server token")
            case .rejected(.unauthorized):
                add(.problem, "the latch-server at \(target) refuses the token in \(abbreviated(configDirectory)): it reads another config directory")
            case .rejected(.protocolMismatch):
                add(.problem, "the latch-server at \(target) speaks another version of Latch's protocol; update it, or this one")
            case .rejected:
                add(.problem, "the latch-server at \(target) is busy; try again")
            case .nothingListening:
                add(.problem, "nothing listens at \(target): start latch-server, as `systemctl --user start latch-server` does for the service")
            case .notLatch:
                add(.problem, "something other than latch-server listens at \(target)")
            case let .unreachable(reason):
                add(.problem, "\(target) cannot be reached: \(reason)")
            }
        }

        let listensOnTailnet = listen.contains { LatchRemoteAddressPolicy.classify($0.bytes) == .tailnet }
        if let first = tailnet.first(where: { $0.address.count == 4 }) ?? tailnet.first, !listensOnTailnet,
           let bytes = LatchRemoteAddressPolicy.unmapped(first.address) {
            let address = ServerSocketAddress(bytes: bytes, port: listen.first?.port ?? LatchRemoteProtocol.defaultPort)
            add(.note, "Tailscale is up on \(first.name); for devices on your tailnet, also pass --listen \(address), and pair with this machine's MagicDNS name")
        } else if tailnet.isEmpty, !listensOnTailnet {
            add(.note, "Tailscale is not up here; devices reach a loopback server through a Cloudflare Tunnel or another TLS proxy, or a Mac through an SSH tunnel")
        }
        if let cloudflared = environment.executable(named: "cloudflared"),
           let loopback = listen.first(where: { LatchRemoteAddressPolicy.classify($0.bytes) == .loopback }) {
            add(.note, "cloudflared is installed (\(abbreviated(cloudflared))): a tunnel to http://\(loopback) reaches this server; pair with --wss and the tunnel's host name")
        }
        return Section(title: "Network", findings: findings)
    }

    /// Where to reach a listen address from this machine: an unspecified one at loopback.
    static func reachable(_ address: ServerSocketAddress) -> ServerSocketAddress {
        guard LatchRemoteAddressPolicy.classify(address.bytes) == .unspecified else { return address }
        return ServerSocketAddress(bytes: address.isIPv6 ? Array(repeating: 0, count: 15) + [1] : [127, 0, 0, 1], port: address.port)
    }

    // MARK: Agents

    private func agentsSection() -> Section {
        var findings: [Finding] = []
        func add(_ mark: Mark, _ text: String) { findings.append(Finding(mark: mark, text: text)) }
        var usable = 0
        for preset in [AgentPreset.claudeCode, .codex, .openCode, .fx] {
            guard let recipe = preset.recipe(in: environment) else { continue }
            if let problem = recipe.problem(in: environment) {
                add(.note, "\(preset.title): \(problem)")
                continue
            }
            var text: String
            if recipe.requiresNode, let node = environment.executable(named: "node") {
                guard let version = nodeVersion(node) else {
                    add(.problem, "\(preset.title): \(abbreviated(node)) did not say its version; check that Node.js runs")
                    continue
                }
                guard let major = Self.majorVersion(version), major >= 22 else {
                    add(.problem, "\(preset.title): needs Node.js 22 or later to fetch its adapter; \(abbreviated(node)) is \(version)")
                    continue
                }
                text = "\(preset.title): its adapter is fetched with npx on first use, with Node.js \(version)"
            } else if let parsed = try? AgentCommand(recipe.command), let path = environment.executable(named: parsed.executable) {
                text = "\(preset.title): \(abbreviated(path))"
            } else {
                continue
            }
            if preset == .claudeCode, let claude = environment.environment["CLAUDE_CODE_EXECUTABLE"], !claude.isEmpty {
                text += "; runs Claude Code at \(abbreviated(claude))"
            }
            add(.ok, text)
            usable += 1
        }
        if usable == 0 {
            add(.problem, "no agent can start here: install one, as the user latch-server runs as")
        } else {
            add(.note, "sign-in is not checked: sign in to each agent as this user, as with `claude` or `codex login`")
        }
        return Section(title: "Agents, found as latch-server finds them: on this PATH and in the usual install locations", findings: findings)
    }

    /// 22 for `v22.10.0`.
    static func majorVersion(_ version: String) -> Int? {
        let digits = version.drop { $0 == "v" }.prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    private func abbreviated(_ path: String) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

// MARK: The real checks

extension ServerDoctor {
    /// Connects and sends a hello with `token`.
    static func ask(_ address: ServerSocketAddress, token: LatchRemoteToken) -> Answer {
        do {
            let client = try ServerLocalClient(connectingTo: address, token: token)
            client.close()
            return .welcomed(version: client.welcome.server.version, hostname: client.welcome.server.hostname)
        } catch .nothingListening {
            return .nothingListening
        } catch let .unreachable(reason) {
            return .unreachable(reason)
        } catch let .rejected(reason) {
            return .rejected(reason)
        } catch {
            return .notLatch
        }
    }

    /// `node --version`, or nil when it does not answer within five seconds.
    static func nodeVersion(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + .seconds(5)) == .success else {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !text.isEmpty ? text : nil
    }
}
