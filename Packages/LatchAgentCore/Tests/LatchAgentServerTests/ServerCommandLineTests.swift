import Foundation
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest
@testable import LatchAgentServer

final class ServerCommandLineTests: XCTestCase {
    private func parse(_ arguments: String...) throws -> ServerCommand {
        try ServerCommandLine.parse(arguments)
    }

    private static func parseError(_ arguments: [String]) -> ServerCommandLineError? {
        do {
            _ = try ServerCommandLine.parse(arguments)
            return nil
        } catch {
            return error
        }
    }

    private func assertRejected(_ arguments: [String], _ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ServerCommandLine.parse(arguments), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(fragment), "\(error)", file: file, line: line)
        }
    }

    func testServeDefaults() throws {
        guard case let .serve(options) = try parse() else { return XCTFail("expected serve") }
        XCTAssertEqual(options, ServeOptions())
        XCTAssertEqual(options.listenAddresses, ["127.0.0.1:7428"])
        XCTAssertEqual(options.detachedTimeout, .seconds(86_400))
        XCTAssertFalse(options.allowUnencryptedNetwork)
        XCTAssertFalse(options.logAgentStandardError)
        XCTAssertFalse(options.config.allowRoot)
        XCTAssertNil(options.config.configDirectory)
    }

    func testServeOptions() throws {
        guard case let .serve(options) = try parse(
            "--listen", "127.0.0.1:0", "--listen=[::1]:9", "--allow-unencrypted-network", "--config-dir", "/tmp/c",
            "--detached-timeout", "90m", "--log-agent-stderr", "--allow-root"
        ) else { return XCTFail("expected serve") }
        XCTAssertEqual(options.listenAddresses, ["127.0.0.1:0", "[::1]:9"])
        XCTAssertTrue(options.allowUnencryptedNetwork)
        XCTAssertEqual(options.config, ConfigOptions(configDirectory: "/tmp/c", allowRoot: true))
        XCTAssertEqual(options.detachedTimeout, .seconds(5400))
        XCTAssertTrue(options.logAgentStandardError)
    }

    func testSubcommands() throws {
        XCTAssertEqual(try parse("token"), .token(ConfigOptions(), rotate: false))
        XCTAssertEqual(try parse("token", "--rotate", "--config-dir=/c"), .token(ConfigOptions(configDirectory: "/c"), rotate: true))
        XCTAssertEqual(try parse("pair", "--host", "vps.tailnet.ts.net"), .pair(ConfigOptions(), host: "vps.tailnet.ts.net", port: 7428))
        XCTAssertEqual(try parse("pair", "--host", "vps", "--port", "9000", "--allow-root"), .pair(ConfigOptions(allowRoot: true), host: "vps", port: 9000))
        XCTAssertEqual(try parse("pair", "--host", "vps", "--qr"), .pair(ConfigOptions(), host: "vps", port: 7428, qr: .lightModulesDrawn))
        XCTAssertEqual(try parse("pair", "--invert", "--qr", "--host=vps"), .pair(ConfigOptions(), host: "vps", port: 7428, qr: .darkModulesDrawn))
        XCTAssertEqual(try parse("pair", "--host", "latch.example.com", "--wss"),
                       .pair(ConfigOptions(), host: "latch.example.com", port: 443, transport: .webSocket))
        XCTAssertEqual(try parse("pair", "--wss", "--port", "8443", "--host", "latch.example.com", "--qr"),
                       .pair(ConfigOptions(), host: "latch.example.com", port: 8443, transport: .webSocket, qr: .lightModulesDrawn))
        XCTAssertEqual(try parse("pair", "--host", "vps", "--device", "phone", "--qr"),
                       .pair(ConfigOptions(), host: "vps", port: 7428, qr: .lightModulesDrawn, device: "phone"))
        XCTAssertEqual(try parse("pair", "--host", "latch.example.com", "--wss", "--device", "phone"),
                       .pair(ConfigOptions(), host: "latch.example.com", port: 443, transport: .webSocket, device: "phone"))
        XCTAssertEqual(try parse("devices"), .devices(ConfigOptions(), revoke: nil))
        var checked = ServeOptions()
        checked.listen = ["100.101.102.103:7428"]
        checked.allowUnencryptedNetwork = true
        checked.config.configDirectory = "/c"
        XCTAssertEqual(try parse("doctor", "--listen", "100.101.102.103:7428", "--allow-unencrypted-network", "--config-dir", "/c"), .doctor(checked))
        XCTAssertEqual(try parse("doctor"), .doctor(ServeOptions()))
        var service = ServeOptions()
        service.listen = ["127.0.0.1:7801"]
        service.detachedTimeout = .seconds(3600)
        service.logAgentStandardError = true
        XCTAssertEqual(try parse("install-service", "--listen", "127.0.0.1:7801", "--detached-timeout", "1h", "--log-agent-stderr", "--replace"),
                       .installService(service, replace: true))
        XCTAssertEqual(try parse("install-service"), .installService(ServeOptions(), replace: false))
        XCTAssertEqual(try parse("uninstall-service", "--config-dir", "/c"), .uninstallService(ConfigOptions(configDirectory: "/c")))
        XCTAssertEqual(try parse("devices", "--revoke=phone", "--config-dir", "/c"), .devices(ConfigOptions(configDirectory: "/c"), revoke: "phone"))
        XCTAssertEqual(try parse("--version"), .version)
        XCTAssertEqual(try parse("--help"), .help)
        XCTAssertEqual(try parse("token", "-h"), .help)
    }

    func testRejectsWhatDoesNotApply() {
        assertRejected(["serve"], "unknown command")
        assertRejected(["--listen"], "needs a value")
        assertRejected(["--bogus"], "unknown option")
        assertRejected(["token", "--listen", "127.0.0.1:1"], "does not apply")
        assertRejected(["--rotate"], "does not apply")
        assertRejected(["pair"], "needs --host")
        assertRejected(["pair", "--host", "h", "--port", "0"], "--port")
        assertRejected(["pair", "--host", "h", "--port", "70000"], "--port")
        assertRejected(["pair", "--host", "h", "--invert"], "--invert needs --qr")
        assertRejected(["pair", "--host", "h", "--qr=yes"], "takes no value")
        assertRejected(["token", "--qr"], "does not apply")
        assertRejected(["--wss"], "does not apply")
        assertRejected(["pair", "--host", "h", "--wss=yes"], "takes no value")
        assertRejected(["--qr"], "does not apply")
        assertRejected(["--detached-timeout", "soon"], "--detached-timeout")
        assertRejected(["--config-dir", "/a", "--config-dir", "/b"], "twice")
        assertRejected(["--allow-root=yes"], "takes no value")
        assertRejected(["--version", "--allow-root"], "--version")
        assertRejected(["--config-dir="], "needs a path")
        assertRejected(["pair", "--host", "h", "--device", "../server-token"], "--device ../server-token")
        assertRejected(["pair", "--host", "h", "--device", ".phone"], "--device .phone")
        assertRejected(["pair", "--host", "h", "--device"], "needs a value")
        assertRejected(["devices", "--revoke", "my phone"], "--revoke my phone")
        assertRejected(["token", "--device", "phone"], "does not apply")
        assertRejected(["devices", "--device", "phone"], "does not apply")
        assertRejected(["pair", "--host", "h", "--revoke", "phone"], "does not apply")
        assertRejected(["devices", "--revoke", "a", "--revoke", "b"], "twice")
        assertRejected(["doctor", "--detached-timeout", "1h"], "does not apply")
        assertRejected(["doctor", "--qr"], "does not apply")
        assertRejected(["--replace"], "does not apply")
        assertRejected(["uninstall-service", "--listen", "127.0.0.1:1"], "does not apply")
    }

    func testPairSuggestsWhatTheHostCanBe() {
        XCTAssertEqual(Self.parseError(["pair"]), .pairNeedsHost)
        let suggestions = ServerCommandLine.hostSuggestions(interfaces: [
            ServerInterfaceAddress(name: ServerListenPolicy.defaultTunnelPrefixes[0] + "0", address: [100, 101, 102, 103]),
            ServerInterfaceAddress(name: "eth0", address: [192, 168, 1, 7]),
            ServerInterfaceAddress(name: "lo", address: [127, 0, 0, 1]),
        ])
        XCTAssertEqual(suggestions.count, 3)
        XCTAssertTrue(suggestions[0].hasPrefix("  --host 100.101.102.103 "), suggestions[0])
        XCTAssertTrue(suggestions[1].hasPrefix("  --host 127.0.0.1 "), suggestions[1])
        XCTAssertTrue(suggestions[2].hasPrefix("  --host NAME --wss "), suggestions[2])
        XCTAssertFalse(suggestions.joined().contains("192.168"), "an unencrypted network is never suggested")
    }

    func testDurations() {
        XCTAssertEqual(ServerCommandLine.parseDuration("0"), .zero)
        XCTAssertEqual(ServerCommandLine.parseDuration("24h"), .seconds(86_400))
        XCTAssertEqual(ServerCommandLine.parseDuration("90m"), .seconds(5_400))
        XCTAssertEqual(ServerCommandLine.parseDuration("30s"), .seconds(30))
        XCTAssertEqual(ServerCommandLine.parseDuration("2d"), .seconds(172_800))
        XCTAssertEqual(ServerCommandLine.parseDuration("1h30m"), .seconds(5_400))
        XCTAssertEqual(ServerCommandLine.parseDuration("0m"), .zero)
        for invalid in ["", "10", "h", "1x", "30m1h", "1h1h", "-5m", "1.5h", "1h 30m", "9999999999h"] {
            XCTAssertNil(ServerCommandLine.parseDuration(invalid), invalid)
        }
    }

    func testEscapingLogLines() {
        XCTAssertEqual(ServerLog.escape("plain text"), "plain text")
        XCTAssertEqual(ServerLog.escape("a\nb\rc\u{1B}[31m"), "a\\u{A}b\\u{D}c\\u{1B}[31m")
        XCTAssertEqual(ServerLog.escape("\u{202E}evil\u{2066}"), "\\u{202E}evil\\u{2066}")
        XCTAssertEqual(ServerLog.escape("back\\slash"), "back\\\\slash")
        XCTAssertEqual(ServerLog.escape("naïve ✓"), "naïve ✓")
    }

    func testAgentStandardErrorIsSplitCappedAndRateLimited() {
        let lines = LogCollector()
        let log = ServerLog(sink: lines.sink)
        let clock = TestClock()
        let stderrLog = AgentStandardErrorLog(log: log, maxLineLength: 10, linesPerWindow: 3, window: .seconds(10), clock: { clock.now })
        let id = AgentRuntimeID("rt-1")

        stderrLog.receive(id, Data("one\ntw".utf8))
        stderrLog.receive(id, Data("o\r\n\u{1B}]0;title\u{07}\n".utf8))
        stderrLog.receive(id, Data("dropped\nalso dropped\n".utf8))
        clock.set(.seconds(11))
        stderrLog.receive(id, Data(String(repeating: "x", count: 100).utf8 + Data("\nlast\n".utf8)))
        log.flush()
        XCTAssertEqual(lines.all, [
            "agent rt-1: one",
            "agent rt-1: two",
            "agent rt-1: \\u{1B}]0;title\\u{7}",
            "agent rt-1: (2 lines of stderr not logged)",
            "agent rt-1: xxxxxxxxxx…",
            "agent rt-1: last",
        ])
    }
}
