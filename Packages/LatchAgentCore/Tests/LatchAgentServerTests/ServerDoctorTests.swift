import Foundation
import LatchAgentCore
import LatchRemoteProtocol
import Synchronization
import XCTest
@testable import LatchAgentServer
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The addresses a doctor asked.
private final class Asked: Sendable {
    let addresses = Mutex<[ServerSocketAddress]>([])
}

final class ServerDoctorTests: XCTestCase {
    private var root: URL!
    private var config: String { root.appendingPathComponent("config").path }
    private var bin: URL { root.appendingPathComponent("bin") }
    private let loopback = ServerSocketAddress(bytes: [127, 0, 0, 1], port: 7428)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("latch-doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func install(_ names: String...) throws {
        for name in names {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func doctor(
        listen: [ServerSocketAddress]? = nil,
        allowUnencryptedNetwork: Bool = false,
        interfaces: [ServerInterfaceAddress] = [],
        node: String? = "v22.10.0",
        answer: ServerDoctor.Answer = .welcomed(version: "9.9.9", hostname: "vps"),
        asked: Asked? = nil
    ) -> (sections: [ServerDoctor.Section], text: String) {
        let doctor = ServerDoctor(
            configDirectory: config, owner: geteuid(), runsAsRoot: false, allowRoot: false,
            listen: listen ?? [loopback], allowUnencryptedNetwork: allowUnencryptedNetwork, interfaces: interfaces,
            environment: AgentLaunchEnvironment(environment: ["PATH": bin.path], home: root, includeCommonLocations: false),
            homeDirectory: root.path,
            nodeVersion: { _ in node },
            ask: { address, _ in
                asked?.addresses.withLock { $0.append(address) }
                return answer
            }
        )
        let sections = doctor.sections()
        return (sections, ServerDoctor.render(sections, header: "doctor"))
    }

    private func assertContains(_ text: String, _ fragments: String..., file: StaticString = #filePath, line: UInt = #line) {
        for fragment in fragments {
            XCTAssertTrue(text.contains(fragment), "missing \(fragment) in:\n\(text)", file: file, line: line)
        }
    }

    func testAServerThatIsSetUpHasNoProblems() throws {
        try ServerConfigDirectory.prepare(config)
        try ServerTokenFile(directory: config).readOrCreate()
        try ServerDeviceTokens(configDirectory: config).readOrCreate("phone")
        try install("claude-agent-acp", "claude")
        let (sections, text) = doctor()
        XCTAssertFalse(ServerDoctor.hasProblems(sections), text)
        assertContains(text,
                       "✓ ~/config is private to this user",
                       "✓ the server token is private",
                       "✓ 1 device has a token of its own: phone",
                       "✓ 127.0.0.1:7428 is loopback",
                       "✓ latch-server 9.9.9 on vps answers at 127.0.0.1:7428 and accepts the server token",
                       "✓ Claude Code: ~/bin/claude-agent-acp; runs Claude Code at ~/bin/claude",
                       "· Codex: ",
                       "No problems found.")
    }

    func testDevicesNobodyUsesArePointedOut() throws {
        try ServerConfigDirectory.prepare(config)
        try ServerTokenFile(directory: config).readOrCreate()
        let devices = ServerDeviceTokens(configDirectory: config)
        for name in ["phone", "old-ipad", "spare", "new"] { try devices.readOrCreate(name) }
        let now = Date()
        let use = ServerTokenUse(configDirectory: config, now: { now.addingTimeInterval(-40 * 86_400) })
        use.note(device: "old-ipad", from: "100.64.0.2")
        ServerTokenUse(configDirectory: config, now: { now.addingTimeInterval(-3600) }).note(device: "phone", from: "100.64.0.1")
        // Paired ten days ago and never seen; "new" was paired just now. An hour more, so the
        // round trip through the file's timestamp cannot make it 9.99 days.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86_400 - 3600)], ofItemAtPath: devices.directory + "/spare")
        try install("claude-agent-acp")
        var doctor = ServerDoctor(
            configDirectory: config, owner: geteuid(), runsAsRoot: false, allowRoot: false, listen: [loopback],
            allowUnencryptedNetwork: false, interfaces: [],
            environment: AgentLaunchEnvironment(environment: ["PATH": bin.path], home: root, includeCommonLocations: false),
            homeDirectory: root.path, nodeVersion: { _ in nil }, ask: { _, _ in .welcomed(version: "1", hostname: "h") })
        doctor.now = now
        let sections = doctor.sections()
        let text = ServerDoctor.render(sections, header: "doctor")
        assertContains(text,
                       "· device old-ipad last connected 40 days ago; if it is gone, `latch-server devices --revoke old-ipad`",
                       "· device spare has not connected since it was paired 10 days ago")
        XCTAssertFalse(text.contains("device phone last"), text)
        XCTAssertFalse(text.contains("device new has"), text)
        XCTAssertFalse(ServerDoctor.hasProblems(sections), text)
    }

    func testNothingSetUpYetSaysWhatComesFirst() {
        let asked = Asked()
        let (sections, text) = doctor(asked: asked)
        assertContains(text,
                       "· ~/config does not exist yet; latch-server creates it",
                       "✗ no agent can start here",
                       "1 problem.")
        XCTAssertTrue(ServerDoctor.hasProblems(sections))
        // Without a token there is nothing to ask a server with.
        XCTAssertEqual(asked.addresses.withLock { $0 }, [])
        // Nothing was created.
        XCTAssertFalse(FileManager.default.fileExists(atPath: config))
    }

    func testEachProblemSaysWhatToDo() throws {
        try ServerConfigDirectory.prepare(config)
        let tokens = ServerTokenFile(directory: config)
        try tokens.readOrCreate()
        let devices = ServerDeviceTokens(configDirectory: config)
        try devices.readOrCreate("phone")
        XCTAssertEqual(chmod(devices.directory + "/phone", 0o644), 0)
        try install("claude-agent-acp")

        var text = doctor(answer: .rejected(.unauthorized)).text
        assertContains(text,
                       "✗ device phone is refused: \(devices.directory)/phone is accessible to other users; run chmod go= on it",
                       "✗ the latch-server at 127.0.0.1:7428 refuses the token in ~/config: it reads another config directory")
        text = doctor(answer: .nothingListening).text
        assertContains(text, "✗ nothing listens at 127.0.0.1:7428: start latch-server")
        text = doctor(answer: .notLatch).text
        assertContains(text, "✗ something other than latch-server listens at 127.0.0.1:7428")

        XCTAssertEqual(chmod(tokens.path, 0o640), 0)
        text = doctor().text
        assertContains(text, "✗ \(tokens.path) is accessible to other users; run chmod go= on it")
        XCTAssertFalse(text.contains("answers at"), text)
    }

    func testListenAddressesAreCheckedAsServingWouldCheckThem() throws {
        try ServerConfigDirectory.prepare(config)
        try ServerTokenFile(directory: config).readOrCreate()
        let tailnet = ServerSocketAddress(bytes: [100, 101, 102, 103], port: 7428)
        let everywhere = ServerSocketAddress(bytes: [0, 0, 0, 0], port: 7428)

        var text = doctor(listen: [tailnet]).text
        assertContains(text, "✗ 100.101.102.103:7428 is not on a Tailscale interface yet; start Tailscale")
        text = doctor(listen: [everywhere]).text
        assertContains(text, "✗ 0.0.0.0:7428 listens on every interface; pass --allow-unencrypted-network")

        // Every interface is checked at loopback.
        let asked = Asked()
        text = doctor(listen: [everywhere], allowUnencryptedNetwork: true, asked: asked).text
        assertContains(text, "· 0.0.0.0:7428 listens on every interface; the token and all traffic can cross the network unencrypted")
        XCTAssertEqual(asked.addresses.withLock { $0 }, [loopback])

        // Tailscale up, the server on loopback only: say how to reach it from the tailnet.
        #if os(macOS)
        let tunnel = "utun3"
        #else
        let tunnel = "tailscale0"
        #endif
        let up = [ServerInterfaceAddress(name: tunnel, address: [100, 101, 102, 103])]
        text = doctor(interfaces: up).text
        assertContains(text, "· Tailscale is up on \(tunnel); for devices on your tailnet, also pass --listen 100.101.102.103:7428")
        text = doctor(listen: [tailnet], interfaces: up).text
        assertContains(text, "✓ 100.101.102.103:7428 is Tailscale's address on \(tunnel)")
        XCTAssertFalse(text.contains("also pass --listen"), text)
    }

    func testAdaptersFetchedWithNpxNeedNode22() throws {
        try install("node", "npx")
        var text = doctor(node: "v18.19.0").text
        assertContains(text, "✗ Claude Code: needs Node.js 22 or later to fetch its adapter; ~/bin/node is v18.19.0",
                       "✗ no agent can start here")
        text = doctor(node: nil).text
        assertContains(text, "✗ Codex: ~/bin/node did not say its version")
        text = doctor(node: "v22.0.0").text
        assertContains(text, "✓ Claude Code: its adapter is fetched with npx on first use, with Node.js v22.0.0",
                       "· sign-in is not checked")
        XCTAssertEqual(ServerDoctor.majorVersion("v26.10.0"), 26)
        XCTAssertEqual(ServerDoctor.majorVersion("22"), 22)
        XCTAssertNil(ServerDoctor.majorVersion("node"))
    }
}
