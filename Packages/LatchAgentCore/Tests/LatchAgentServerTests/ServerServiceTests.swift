import Foundation
import Synchronization
import XCTest
@testable import LatchAgentServer

/// systemctl and loginctl as a test answers them, with the commands run.
private final class FakeSystem: Sendable {
    let commands = Mutex<[String]>([])
    let active = Mutex(false)
    let linger = Mutex("no")
    let lingerAllowed = Mutex(true)
    let failing = Mutex<String?>(nil)

    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let line = arguments.joined(separator: " ")
        commands.withLock { $0.append(line) }
        if let failing = failing.withLock({ $0 }), line.hasPrefix(failing) { return (1, "Failed to connect to bus: No medium found\n") }
        switch arguments.prefix(3) {
        case ["systemctl", "--user", "is-active"]: return (active.withLock { $0 } ? 0 : 3, "")
        case ["loginctl", "show-user", arguments.dropFirst(2).first ?? ""]: return (0, linger.withLock { $0 } + "\n")
        case ["loginctl", "enable-linger", arguments.dropFirst(2).first ?? ""]: return (lingerAllowed.withLock { $0 } ? 0 : 1, "")
        default: return (0, "")
        }
    }
}

final class ServerServiceTests: XCTestCase {
    private var root: String!
    private var system: FakeSystem!
    private var service: ServerService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("latch-service-\(UUID().uuidString)").path
        system = FakeSystem()
        let system = system!
        service = ServerService(unitDirectory: root + "/systemd/user", homeDirectory: "/home/me", user: "me", run: { system.run($0) })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private var unit: String? {
        FileManager.default.contents(atPath: service.unitPath).map { String(decoding: $0, as: UTF8.self) }
    }

    func testTheUnitIsTheOneTheGuideDescribes() {
        XCTAssertEqual(service.unit(executable: "/home/me/.local/bin/latch-server", options: ServeOptions()), """
        \(ServerService.marker)
        [Unit]
        Description=Latch server
        StartLimitIntervalSec=0

        [Service]
        ExecStart=%h/.local/bin/latch-server --listen 127.0.0.1:7428
        ExecReload=/bin/kill -HUP $MAINPID
        Restart=on-failure
        RestartSec=2s

        [Install]
        WantedBy=default.target

        """)
    }

    func testTheCommandLineCarriesTheOptionsEscaped() {
        var options = ServeOptions()
        options.listen = ["127.0.0.1:7428", "100.101.102.103:7428"]
        options.allowUnencryptedNetwork = true
        options.config.configDirectory = "/srv/latch config"
        options.detachedTimeout = .seconds(90 * 60)
        options.logAgentStandardError = true
        XCTAssertEqual(service.execStart(executable: "/opt/latch 100%/latch-server", options: options),
                       #""/opt/latch 100%%/latch-server" --listen 127.0.0.1:7428 --listen 100.101.102.103:7428 "#
                       + #"--allow-unencrypted-network --config-dir "/srv/latch config" --detached-timeout 90m --log-agent-stderr"#)
        XCTAssertEqual(ServerService.escape("a$b"), "a$$b")
        XCTAssertEqual(ServerService.escape(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(ServerService.escape(""), #""""#)
        XCTAssertEqual(ServerService.format(.seconds(86_400)), "1d")
        XCTAssertEqual(ServerService.format(.seconds(45)), "45s")
        XCTAssertEqual(ServerService.format(.zero), "0")
        XCTAssertEqual(ServerService.unitDirectory(environment: ["XDG_CONFIG_HOME": "/xdg"], homeDirectory: "/home/me"), "/xdg/systemd/user")
        XCTAssertEqual(ServerService.unitDirectory(environment: [:], homeDirectory: "/home/me"), "/home/me/.config/systemd/user")
    }

    func testInstallingWritesEnablesStartsAndLingers() {
        let outcome = service.install(executable: "/home/me/.local/bin/latch-server", options: ServeOptions(), replace: false)
        XCTAssertEqual(outcome.status, 0, "\(outcome.lines)")
        XCTAssertTrue(unit?.hasPrefix(ServerService.marker) == true)
        XCTAssertEqual(system.commands.withLock { $0 }, [
            "systemctl --user is-active --quiet latch-server.service",
            "systemctl --user daemon-reload",
            "systemctl --user enable latch-server.service",
            "systemctl --user start latch-server.service",
            "loginctl show-user me --property=Linger --value",
            "loginctl enable-linger me",
        ])
        XCTAssertTrue(outcome.lines.contains("started latch-server"), "\(outcome.lines)")

        // The same unit again, running, lingering: nothing restarts.
        system.commands.withLock { $0 = [] }
        system.active.withLock { $0 = true }
        system.linger.withLock { $0 = "yes" }
        XCTAssertEqual(service.install(executable: "/home/me/.local/bin/latch-server", options: ServeOptions(), replace: false).status, 0)
        XCTAssertFalse(system.commands.withLock { $0 }.contains { $0.contains("restart") || $0.contains("start latch") })

        // Other options: the unit changes, and the running service restarts with it.
        var options = ServeOptions()
        options.listen = ["127.0.0.1:7801"]
        XCTAssertEqual(service.install(executable: "/home/me/.local/bin/latch-server", options: options, replace: false).status, 0)
        XCTAssertTrue(system.commands.withLock { $0 }.contains("systemctl --user restart latch-server.service"))
        XCTAssertTrue(unit?.contains("--listen 127.0.0.1:7801") == true)
    }

    func testAUnitTheUserWroteIsReplacedOnlyWhenAsked() throws {
        try FileManager.default.createDirectory(atPath: root + "/systemd/user", withIntermediateDirectories: true)
        let own = "[Service]\nExecStart=/usr/local/bin/latch-server --listen 127.0.0.1:7428\n"
        try Data(own.utf8).write(to: URL(fileURLWithPath: service.unitPath))
        let refused = service.install(executable: "/home/me/.local/bin/latch-server", options: ServeOptions(), replace: false)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.lines.joined().contains("pass --replace"), "\(refused.lines)")
        XCTAssertEqual(unit, own)
        XCTAssertEqual(system.commands.withLock { $0 }, [])
        XCTAssertEqual(service.uninstall().status, 1)
        XCTAssertEqual(unit, own)

        XCTAssertEqual(service.install(executable: "/home/me/.local/bin/latch-server", options: ServeOptions(), replace: true).status, 0)
        XCTAssertTrue(unit?.hasPrefix(ServerService.marker) == true)
    }

    func testWithoutAUserSessionItSaysWhy() {
        system.failing.withLock { $0 = "systemctl --user daemon-reload" }
        let outcome = service.install(executable: "/usr/local/bin/latch-server", options: ServeOptions(), replace: false)
        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.lines.contains { $0.contains("Failed to connect to bus") }, "\(outcome.lines)")
        XCTAssertTrue(outcome.lines.contains { $0.contains("log in as me over SSH") }, "\(outcome.lines)")
    }

    func testLingeringItCannotEnableIsLeftToTheUser() {
        system.lingerAllowed.withLock { $0 = false }
        let outcome = service.install(executable: "/usr/local/bin/latch-server", options: ServeOptions(), replace: false)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertTrue(outcome.lines.contains { $0.contains("sudo loginctl enable-linger me") }, "\(outcome.lines)")
    }

    func testUninstallingStopsAndRemovesOnlyItsOwnUnit() {
        XCTAssertEqual(service.uninstall().status, 1)
        XCTAssertEqual(service.install(executable: "/usr/local/bin/latch-server", options: ServeOptions(), replace: false).status, 0)
        system.commands.withLock { $0 = [] }
        let outcome = service.uninstall()
        XCTAssertEqual(outcome.status, 0, "\(outcome.lines)")
        XCTAssertNil(unit)
        XCTAssertEqual(system.commands.withLock { $0 }, [
            "systemctl --user disable --now latch-server.service",
            "systemctl --user daemon-reload",
        ])
    }
}
