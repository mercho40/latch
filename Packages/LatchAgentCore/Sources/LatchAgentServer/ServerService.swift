import Foundation

/// `latch-server install-service` and `uninstall-service`: the systemd user unit
/// docs/server.md describes, written, enabled and started, and taken away again. Linux only.
struct ServerService {
    static let unitName = "latch-server.service"
    /// The first line of a unit `install-service` wrote: one without it is the user's own, which
    /// it replaces only when asked and `uninstall-service` never removes.
    static let marker = "# Written by latch-server install-service; latch-server uninstall-service removes it."

    /// Runs a command, `systemctl` or `loginctl`, and returns its status and what it printed.
    typealias Runner = ([String]) -> (status: Int32, output: String)

    var unitDirectory: String
    var homeDirectory: String
    var user: String
    var run: Runner

    var unitPath: String { (unitDirectory as NSString).appendingPathComponent(Self.unitName) }

    /// `$XDG_CONFIG_HOME/systemd/user`, else `~/.config/systemd/user`.
    static func unitDirectory(environment: [String: String], homeDirectory: String) -> String {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? (homeDirectory as NSString).appendingPathComponent(".config")
        return ((base as NSString).appendingPathComponent("systemd") as NSString).appendingPathComponent("user")
    }

    // MARK: The unit

    func unit(executable: String, options: ServeOptions) -> String {
        """
        \(Self.marker)
        [Unit]
        Description=Latch server
        StartLimitIntervalSec=0

        [Service]
        ExecStart=\(execStart(executable: executable, options: options))
        ExecReload=/bin/kill -HUP $MAINPID
        Restart=on-failure
        RestartSec=2s

        [Install]
        WantedBy=default.target

        """
    }

    /// The command line, with the options serving was given and the listen address always
    /// written out, so the unit says where the server listens.
    func execStart(executable: String, options: ServeOptions) -> String {
        var arguments = [executable] + options.listenAddresses.flatMap { ["--listen", $0] }
        if options.allowUnencryptedNetwork { arguments.append("--allow-unencrypted-network") }
        if let directory = options.config.configDirectory { arguments += ["--config-dir", directory] }
        if options.detachedTimeout != ServeOptions().detachedTimeout {
            arguments += ["--detached-timeout", Self.format(options.detachedTimeout)]
        }
        if options.logAgentStandardError { arguments.append("--log-agent-stderr") }
        return arguments.enumerated().map { index, argument in
            // `%h` keeps a binary under the home directory where the unit expects it.
            let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
            if index == 0, !home.isEmpty, argument.hasPrefix(home + "/") {
                return "%h" + Self.escape(String(argument.dropFirst(home.count)))
            }
            return Self.escape(argument)
        }.joined(separator: " ")
    }

    /// The first `--listen` address on a unit's ExecStart line.
    static func listenAddress(inUnit unit: String) -> String? {
        guard let execStart = unit.split(separator: "\n").first(where: { $0.hasPrefix("ExecStart=") }) else { return nil }
        let words = execStart.split(separator: " ")
        guard let index = words.firstIndex(of: "--listen"), index + 1 < words.count else { return nil }
        return String(words[index + 1])
    }

    /// One argument as systemd reads it: `%` and `$` doubled, and quoted when it has a space,
    /// a quote or a backslash.
    static func escape(_ argument: String) -> String {
        var escaped = argument.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "$", with: "$$")
        guard escaped.isEmpty || escaped.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "'" || $0 == "\\" }) else {
            return escaped
        }
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// `90m` for 90 minutes: the largest unit that divides it, as `--detached-timeout` reads it.
    static func format(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        if seconds == 0 { return "0" }
        for (unit, size) in [("d", Int64(86_400)), ("h", 3_600), ("m", 60)] where seconds % size == 0 {
            return "\(seconds / size)\(unit)"
        }
        return "\(seconds)s"
    }

    // MARK: Installing

    struct Outcome: Equatable {
        var status: Int32
        var lines: [String]
    }

    /// Writes the unit, unless one the user wrote is there and `replace` is false, then reloads
    /// systemd, enables and starts the service, and keeps the user's services running after
    /// logout. A running service whose unit changed restarts only when `runningAgents`, asked
    /// at the address the old unit listens on, says it runs none: a restart stops every agent.
    func install(executable: String, options: ServeOptions, replace: Bool,
                 runningAgents: (_ listen: String) -> Int? = { _ in 0 }) -> Outcome {
        var lines: [String] = []
        let content = unit(executable: executable, options: options)
        let existing = FileManager.default.contents(atPath: unitPath).map { String(decoding: $0, as: UTF8.self) }
        if let existing, existing != content, !existing.hasPrefix(Self.marker), !replace {
            return Outcome(status: 1, lines: [
                "\(unitPath) exists and was not written by install-service; pass --replace to replace it",
            ])
        }
        let changed = existing != content
        if changed {
            do {
                try FileManager.default.createDirectory(atPath: unitDirectory, withIntermediateDirectories: true)
                try Data(content.utf8).write(to: URL(fileURLWithPath: unitPath), options: .atomic)
            } catch {
                return Outcome(status: 1, lines: ["cannot write \(unitPath): \(error.localizedDescription)"])
            }
            lines.append((existing == nil ? "wrote " : "replaced ") + unitPath)
        } else {
            lines.append("\(unitPath) is already this unit")
        }

        lines.append("the service runs \(executable)")
        let wasActive = run(["systemctl", "--user", "is-active", "--quiet", Self.unitName]).status == 0
        var commands = [["systemctl", "--user", "daemon-reload"], ["systemctl", "--user", "enable", Self.unitName]]
        var heldRestart: Int??
        if !wasActive {
            commands.append(["systemctl", "--user", "start", Self.unitName])
        } else if changed {
            let agents = runningAgents(existing.flatMap(Self.listenAddress(inUnit:)) ?? ServerListenPolicy.defaultListen)
            if agents == 0 {
                commands.append(["systemctl", "--user", "restart", Self.unitName])
            } else {
                heldRestart = .some(agents)
            }
        }
        for command in commands {
            let result = run(command)
            guard result.status == 0 else {
                lines.append("`\(command.joined(separator: " "))` failed: " + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                lines.append("systemctl --user needs your own login session: log in as \(user) over SSH rather than through su or sudo -u")
                return Outcome(status: 1, lines: lines)
            }
        }
        switch heldRestart {
        case let .some(agents?):
            lines.append("latch-server runs \(agents == 1 ? "1 agent" : "\(agents) agents"), which a restart would stop: it keeps its old options until `systemctl --user restart latch-server`, once they are done")
        case .some(nil):
            lines.append("latch-server could not be asked what it runs, and a restart would stop its agents: it keeps its old options until `systemctl --user restart latch-server`")
        case nil:
            lines.append(wasActive ? (changed ? "restarted latch-server with the new unit" : "latch-server was already running") : "started latch-server")
        }

        let linger = run(["loginctl", "show-user", user, "--property=Linger", "--value"])
        if linger.output.trimmingCharacters(in: .whitespacesAndNewlines) != "yes" {
            if run(["loginctl", "enable-linger", user]).status == 0 {
                lines.append("enabled lingering for \(user): the service starts at boot and keeps running after you log out")
            } else {
                lines.append("run `sudo loginctl enable-linger \(user)`, or the service stops when your last session ends")
            }
        }
        lines.append("check it with `latch-server doctor`; pair a device with `latch-server pair --host NAME --device DEVICE --qr`")
        return Outcome(status: 0, lines: lines)
    }

    /// Stops and disables the service and removes the unit, if install-service wrote it.
    func uninstall() -> Outcome {
        guard let existing = FileManager.default.contents(atPath: unitPath).map({ String(decoding: $0, as: UTF8.self) }) else {
            return Outcome(status: 1, lines: ["there is no \(unitPath)"])
        }
        guard existing.hasPrefix(Self.marker) else {
            return Outcome(status: 1, lines: [
                "\(unitPath) was not written by install-service; stop it with `systemctl --user disable --now latch-server` and remove it yourself",
            ])
        }
        var lines: [String] = []
        let stopped = run(["systemctl", "--user", "disable", "--now", Self.unitName])
        guard stopped.status == 0 else {
            return Outcome(status: 1, lines: ["`systemctl --user disable --now \(Self.unitName)` failed: "
                + stopped.output.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        lines.append("stopped and disabled latch-server, and with it every agent it ran")
        do {
            try FileManager.default.removeItem(atPath: unitPath)
        } catch {
            return Outcome(status: 1, lines: lines + ["cannot remove \(unitPath): \(error.localizedDescription)"])
        }
        _ = run(["systemctl", "--user", "daemon-reload"])
        lines.append("removed \(unitPath); the token, device tokens and the binary are untouched")
        return Outcome(status: 0, lines: lines)
    }

    // MARK: The real runner

    static func runCommand(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (127, "\(error.localizedDescription)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
