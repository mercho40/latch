import Foundation
import LatchRemoteProtocol

/// What `latch-server` was asked to do.
public enum ServerCommand: Equatable, Sendable {
    case serve(ServeOptions)
    /// Prints the token, creating it if absent, or a new one with `rotate`.
    case token(ConfigOptions, rotate: Bool)
    /// Prints a `latch://` string for pasting into the app, and with `qr` a QR code of it.
    /// With `device`, the string carries that device's own token, created on first use.
    case pair(ConfigOptions, host: String, port: UInt16, transport: LatchRemoteTransport = .tcp, qr: PairQRCode? = nil, device: String? = nil)
    /// Lists the devices with a token of their own, or with `revoke`, deletes one's.
    case devices(ConfigOptions, revoke: String?)
    /// Checks what serving with these options needs, changing nothing.
    case doctor(ServeOptions)
    /// Writes a systemd user unit that serves with these options, and starts it; `replace`
    /// replaces a unit the user wrote.
    case installService(ServeOptions, replace: Bool)
    /// Stops the service and removes the unit `installService` wrote.
    case uninstallService(ConfigOptions)
    case version
    case help
}

public struct ConfigOptions: Equatable, Sendable {
    public var configDirectory: String?
    public var allowRoot = false

    public init(configDirectory: String? = nil, allowRoot: Bool = false) {
        self.configDirectory = configDirectory
        self.allowRoot = allowRoot
    }
}

/// How `pair --qr` draws the code: which modules the half blocks draw.
public enum PairQRCode: Equatable, Sendable {
    /// The light modules and the quiet zone, in white on black on a terminal.
    case lightModulesDrawn
    /// `--invert`: the dark modules, in black on white on a terminal, for a terminal or
    /// scanner that reads that better.
    case darkModulesDrawn
}

public struct ServeOptions: Equatable, Sendable {
    public var config = ConfigOptions()
    /// `host:port` as given; the default is loopback on the default port.
    public var listen: [String] = []
    public var allowUnencryptedNetwork = false
    /// Zero disables the detached reaper.
    public var detachedTimeout: Duration = .seconds(24 * 60 * 60)
    public var logAgentStandardError = false

    public init() {}

    public var listenAddresses: [String] {
        listen.isEmpty ? [ServerListenPolicy.defaultListen] : listen
    }
}

public struct ServerCommandLineError: Error, Equatable, Sendable, CustomStringConvertible {
    public var description: String

    init(_ description: String) {
        self.description = description
    }
}

public enum ServerCommandLine {
    public static let usage = """
    usage: latch-server [options]            serve until SIGTERM or SIGINT
           latch-server token [--rotate]      print the token, creating it if absent
           latch-server pair --host NAME [--port N] [--wss] [--device DEVICE] [--qr [--invert]]
                                              print a latch:// string for the Latch app
           latch-server devices [--revoke DEVICE]
                                              list the devices paired with --device, or
                                              revoke one
           latch-server doctor [--listen HOST:PORT] [--allow-unencrypted-network]
                                              check what serving with those options needs
           latch-server install-service [options] [--replace]
                                              run latch-server with those options as a
                                              systemd user service, now and at boot
           latch-server uninstall-service    stop that service and remove its unit
           latch-server --version | --help

    options:
      --listen HOST:PORT            numeric address to listen on; repeatable
                                    (default \(ServerListenPolicy.defaultListen))
      --allow-unencrypted-network   allow addresses that are neither loopback nor Tailscale
      --config-dir PATH             where server-token and devices live
                                    (default $XDG_CONFIG_HOME/latch or ~/.config/latch)
      --detached-timeout DURATION   stop idle runtimes nobody attached to for this long,
                                    such as 24h, 90m or 30s; 0 disables (default 24h)
      --log-agent-stderr            log agents' stderr, escaped and rate-limited
      --allow-root                  run as root
      --wss                         with pair, for clients that connect through a TLS proxy
                                    such as a Cloudflare Tunnel (default port 443)
      --qr                          with pair, also print the string as a QR code for the
                                    iPhone's camera; it holds the token, so keep it private
      --invert                      with --qr, draw the dark modules instead of the light
      --device DEVICE               with pair, give the string a token of DEVICE's own,
                                    created on first use, that revoking it ends; a name of
                                    letters, digits, '.', '_' and '-'
      --revoke DEVICE               with devices, delete DEVICE's token
      --replace                     with install-service, replace a latch-server.service
                                    it did not write

    SIGHUP re-reads the token files at once; a rotated or revoked token closes the connections that used it.
    """

    public static func parse(_ arguments: [String]) throws(ServerCommandLineError) -> ServerCommand {
        var remaining = arguments[...]
        var subcommand: String?
        if let first = remaining.first, !first.hasPrefix("-") {
            subcommand = first
            remaining = remaining.dropFirst()
        }

        var serve = ServeOptions()
        var rotate = false
        var host: String?
        var port: UInt16?
        var qr = false
        var invert = false
        var webSocket = false
        var device: String?
        var revoke: String?
        var replace = false
        var version = false
        var help = false
        var seen: Set<String> = []

        func allowed(_ option: String, in commands: Set<String?>) throws(ServerCommandLineError) {
            guard commands.contains(subcommand) else {
                throw ServerCommandLineError("\(option) does not apply to \(subcommand.map { "latch-server \($0)" } ?? "serving")")
            }
        }

        while let argument = remaining.popFirst() {
            var option = argument
            var inlineValue: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                option = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }
            func value() throws(ServerCommandLineError) -> String {
                if let inlineValue { return inlineValue }
                guard let next = remaining.popFirst() else { throw ServerCommandLineError("\(option) needs a value") }
                return next
            }
            func flag() throws(ServerCommandLineError) {
                guard inlineValue == nil else { throw ServerCommandLineError("\(option) takes no value") }
            }
            if option != "--listen" {
                guard seen.insert(option).inserted else { throw ServerCommandLineError("\(option) was given twice") }
            }

            switch option {
            case "--listen":
                try allowed(option, in: [nil, "doctor", "install-service"])
                serve.listen.append(try value())
            case "--allow-unencrypted-network":
                try allowed(option, in: [nil, "doctor", "install-service"])
                try flag()
                serve.allowUnencryptedNetwork = true
            case "--config-dir":
                let path = try value()
                guard !path.isEmpty else { throw ServerCommandLineError("--config-dir needs a path") }
                serve.config.configDirectory = path
            case "--detached-timeout":
                try allowed(option, in: [nil, "install-service"])
                let text = try value()
                guard let duration = parseDuration(text) else {
                    throw ServerCommandLineError("--detached-timeout \(text): expected a duration such as 24h, 90m, 30s or 0")
                }
                serve.detachedTimeout = duration
            case "--log-agent-stderr":
                try allowed(option, in: [nil, "install-service"])
                try flag()
                serve.logAgentStandardError = true
            case "--allow-root":
                try flag()
                serve.config.allowRoot = true
            case "--rotate":
                try allowed(option, in: ["token"])
                try flag()
                rotate = true
            case "--host":
                try allowed(option, in: ["pair"])
                host = try value()
            case "--port":
                try allowed(option, in: ["pair"])
                let text = try value()
                guard (1...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let number = UInt16(text), number > 0 else {
                    throw ServerCommandLineError("--port \(text): expected a number from 1 to 65535")
                }
                port = number
            case "--wss":
                try allowed(option, in: ["pair"])
                try flag()
                webSocket = true
            case "--qr":
                try allowed(option, in: ["pair"])
                try flag()
                qr = true
            case "--invert":
                try allowed(option, in: ["pair"])
                try flag()
                invert = true
            case "--device", "--revoke":
                try allowed(option, in: [option == "--device" ? "pair" : "devices"])
                let name = try value()
                guard ServerDeviceTokens.isValidName(name) else {
                    throw ServerCommandLineError("\(option) \(name): expected 1 to 64 letters, digits, '.', '_' and '-', not starting with '.'")
                }
                if option == "--device" { device = name } else { revoke = name }
            case "--replace":
                try allowed(option, in: ["install-service"])
                try flag()
                replace = true
            case "--version":
                try flag()
                version = true
            case "--help", "-h":
                help = true
            default:
                throw ServerCommandLineError("unknown option \(argument)")
            }
        }

        if help { return .help }
        if version {
            guard subcommand == nil, seen == ["--version"] else { throw ServerCommandLineError("--version takes no other options") }
            return .version
        }
        switch subcommand {
        case nil:
            return .serve(serve)
        case "token":
            return .token(serve.config, rotate: rotate)
        case "pair":
            guard let host else { throw ServerCommandLineError("pair needs --host, the name or address clients reach this server at") }
            guard qr || !invert else { throw ServerCommandLineError("--invert needs --qr") }
            let style: PairQRCode? = qr ? (invert ? .darkModulesDrawn : .lightModulesDrawn) : nil
            let transport: LatchRemoteTransport = webSocket ? .webSocket : .tcp
            return .pair(serve.config, host: host, port: port ?? transport.defaultPort, transport: transport, qr: style, device: device)
        case "devices":
            return .devices(serve.config, revoke: revoke)
        case "doctor":
            return .doctor(serve)
        case "install-service":
            return .installService(serve, replace: replace)
        case "uninstall-service":
            return .uninstallService(serve.config)
        case let other?:
            throw ServerCommandLineError("unknown command \(other)")
        }
    }

    /// `0`, or whole numbers with units `d`, `h`, `m` and `s` in that order, such as `24h`,
    /// `90m` or `1h30m`. A bare number other than 0 is refused so a unit is never guessed.
    public static func parseDuration(_ text: String) -> Duration? {
        if text == "0" { return .zero }
        let units: [(Character, Int64)] = [("d", 86_400), ("h", 3_600), ("m", 60), ("s", 1)]
        var total: Int64 = 0
        var digits = ""
        var nextUnit = 0
        for character in text {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            guard let index = units[nextUnit...].firstIndex(where: { $0.0 == character }),
                  !digits.isEmpty, digits.count <= 9, let value = Int64(digits) else { return nil }
            total += value * units[index].1
            nextUnit = index + 1
            digits = ""
        }
        guard digits.isEmpty, !text.isEmpty else { return nil }
        return .seconds(total)
    }
}
