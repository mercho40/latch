import Foundation
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol
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

/// The built `latch-server` binary, run as a process: serving, signals and exit status.
final class LatchServerExecutableTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-server-exe-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Next to the test bundle in the build directory, or `LATCH_SERVER_BINARY`.
    private func binary() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["LATCH_SERVER_BINARY"] {
            return URL(fileURLWithPath: path)
        }
        #if os(macOS)
        let directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        #else
        let directory = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().deletingLastPathComponent()
        #endif
        let url = directory.appendingPathComponent("latch-server")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw HubTestError.unexpected("no latch-server at \(url.path); build the latch-server product first")
        }
        return url
    }

    /// Root in the Linux container: the server refuses it without the flag.
    private var rootArguments: [String] {
        geteuid() == 0 ? ["--allow-root"] : []
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outputData, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }

    func testVersionTokenAndPair() throws {
        XCTAssertEqual(try run(["--version"]).output, "latch-server \(LatchServerVersion.current)\n")
        XCTAssertEqual(try run(["--bogus"]).status, 2)

        let config = root.appendingPathComponent("config").path
        let token = try run(["token", "--config-dir", config] + rootArguments)
        XCTAssertEqual(token.status, 0, token.error)
        XCTAssertEqual(token.output.trimmingCharacters(in: .newlines), try ServerTokenFile(directory: config).read().rawValue)

        let pair = try run(["pair", "--host", "vps.example.ts.net", "--port", "9000", "--config-dir", config] + rootArguments)
        XCTAssertEqual(pair.status, 0, pair.error)
        let pairing = try LatchRemotePairing(parsing: pair.output)
        XCTAssertEqual(pairing.host, "vps.example.ts.net")
        XCTAssertEqual(pairing.port, 9000)
        XCTAssertEqual(pairing.token.rawValue, token.output.trimmingCharacters(in: .newlines))

        // The string, a blank line, then the code in half blocks, uncoloured into a pipe; the
        // string alone for a paste.
        for arguments in [["--qr"], ["--qr", "--invert"]] {
            let qr = try run(["pair", "--host", "vps.example.ts.net", "--config-dir", config] + arguments + rootArguments)
            XCTAssertEqual(qr.status, 0, qr.error)
            let lines = qr.output.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(try LatchRemotePairing(parsing: String(lines[0])).token, pairing.token)
            XCTAssertEqual(lines[1], "")
            let symbol = try QRCode(String(lines[0]))
            XCTAssertEqual(lines[2...].joined(separator: "\n"), symbol.terminalText(darkModules: arguments.contains("--invert")))
        }
        let longHost = Array(repeating: String(repeating: "a", count: 50), count: 3).joined(separator: ".")
        let tooLong = try run(["pair", "--host", longHost, "--qr", "--config-dir", config] + rootArguments)
        XCTAssertEqual(tooLong.status, 1)
        XCTAssertTrue(tooLong.output.hasPrefix("latch://aaa"), tooLong.output)
        XCTAssertTrue(tooLong.error.contains("too long for a QR code"), tooLong.error)

        let rotated = try run(["token", "--rotate", "--config-dir", config] + rootArguments)
        XCTAssertEqual(rotated.status, 0, rotated.error)
        XCTAssertNotEqual(rotated.output, token.output)

        if geteuid() == 0 {
            XCTAssertEqual(try run(["token", "--config-dir", config]).status, 1)
        }
    }

    func testPairingListingAndRevokingDevices() throws {
        let config = root.appendingPathComponent("config").path
        let none = try run(["devices", "--config-dir", config] + rootArguments)
        XCTAssertEqual(none.status, 0, none.error)
        XCTAssertEqual(none.output, "")

        let shared = try LatchRemotePairing(parsing: run(["pair", "--host", "vps", "--config-dir", config] + rootArguments).output)
        let phone = try run(["pair", "--host", "vps", "--device", "phone", "--config-dir", config] + rootArguments)
        XCTAssertEqual(phone.status, 0, phone.error)
        let phonePairing = try LatchRemotePairing(parsing: phone.output)
        XCTAssertNotEqual(phonePairing.token, shared.token)
        XCTAssertEqual(try LatchRemotePairing(parsing: run(["pair", "--host", "vps", "--device", "phone", "--config-dir", config] + rootArguments).output).token,
                       phonePairing.token)
        XCTAssertEqual(try run(["pair", "--host", "vps", "--device", "tablet", "--config-dir", config] + rootArguments).status, 0)
        XCTAssertEqual(try run(["devices", "--config-dir", config] + rootArguments).output, "phone\ntablet\n")

        let revoked = try run(["devices", "--revoke", "phone", "--config-dir", config] + rootArguments)
        XCTAssertEqual(revoked.status, 0, revoked.error)
        XCTAssertTrue(revoked.error.contains("revoked phone"), revoked.error)
        XCTAssertEqual(try run(["devices", "--config-dir", config] + rootArguments).output, "tablet\n")
        let again = try run(["devices", "--revoke", "phone", "--config-dir", config] + rootArguments)
        XCTAssertEqual(again.status, 1)
        XCTAssertTrue(again.error.contains("no device is named phone"), again.error)
        // The server's own token is untouched.
        XCTAssertEqual(try ServerTokenFile(directory: config).read(), shared.token)
    }

    func testConcurrentFirstRunsPrintOneToken() throws {
        let config = root.appendingPathComponent("config").path
        var runs: [(Process, Pipe)] = []
        for _ in 0..<8 {
            let process = Process()
            process.executableURL = try binary()
            process.arguments = ["token", "--config-dir", config] + rootArguments
            let output = Pipe()
            process.standardOutput = output
            runs.append((process, output))
        }
        for (process, _) in runs { try process.run() }
        var tokens = Set<String>()
        for (process, output) in runs {
            tokens.insert(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config), [ServerTokenFile.fileName])
    }

    func testSIGTERMStopsAgentsAndExitsCleanly() async throws {
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try MockAgent.script.write(to: workspace.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        // Records its PID, then becomes the mock agent under the same PID.
        try "echo $$ > agent.pid\nexec /bin/sh ./agent.sh\n".write(
            to: workspace.appendingPathComponent("pid-agent.sh"), atomically: true, encoding: .utf8
        )
        let server = try await ServerProcess.start(binary(), config: root.appendingPathComponent("config").path, extra: rootArguments)
        defer { server.kill() }
        let token = try ServerTokenFile(directory: server.config).read()
        XCTAssertFalse(server.stderr.text.contains(token.rawValue))

        let client = try await server.authenticated()
        let id = AgentRuntimeID("pid")
        let agent = LatchRemoteAgent.custom("/bin/sh " + AgentCommand.quotedArgument(workspace.appendingPathComponent("pid-agent.sh").path))
        try await client.ok(.launchAgent(runtimeID: id, agent: agent, workspace: workspace.path))
        try await client.ok(.newSession(runtimeID: id))
        let pidText = try String(contentsOf: workspace.appendingPathComponent("agent.pid"), encoding: .utf8)
        let agentPID = try XCTUnwrap(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(agentPID, 0), 0)

        XCTAssertEqual(kill(server.process.processIdentifier, SIGTERM), 0)
        try await client.expectClosed(timeout: .seconds(20))
        let status = await server.exitStatus()
        XCTAssertEqual(status, 0)
        XCTAssertEqual(server.process.terminationReason, .exit)

        // The agent was stopped, not orphaned.
        try await eventually("the agent to be gone", timeout: .seconds(5)) {
            kill(agentPID, 0) == -1 && errno == ESRCH
        }
        let log = try await server.finishedLog()
        for expected in ["runtime pid launched", "SIGTERM: shutting down", "runtime pid stopped", "closed: the server is shutting down", "\nstopped\n"] {
            XCTAssertTrue(log.contains(expected), "missing \(expected) in:\n\(log)")
        }
        XCTAssertFalse(log.contains(token.rawValue))
    }

    func testDoctorAsksTheRunningServer() async throws {
        let config = root.appendingPathComponent("config").path
        let server = try await ServerProcess.start(binary(), config: config, extra: rootArguments)
        defer { server.kill() }
        let listen = ["--listen", "127.0.0.1:\(server.port)"]
        let healthy = try run(["doctor", "--config-dir", config] + listen + rootArguments)
        XCTAssertTrue(healthy.output.contains("✓ latch-server \(LatchServerVersion.current) on "), healthy.output)
        XCTAssertTrue(healthy.output.contains(" answers at 127.0.0.1:\(server.port) and accepts the server token"), healthy.output)

        let other = root.appendingPathComponent("other").path
        XCTAssertEqual(try run(["token", "--config-dir", other] + rootArguments).status, 0)
        let refused = try run(["doctor", "--config-dir", other] + listen + rootArguments)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.output.contains("refuses the token in \(other): it reads another config directory"), refused.output)

        let missing = root.appendingPathComponent("missing").path
        let fresh = try run(["doctor", "--config-dir", missing] + listen + rootArguments)
        XCTAssertTrue(fresh.output.contains("\(missing) does not exist yet"), fresh.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing), "doctor creates nothing")
        XCTAssertEqual(try run(["doctor", "--listen", "bogus"]).status, 2)
    }

    /// latch-server joins an agent's streamed chunks; the hub's own default does not.
    func testTheServerJoinsStreamedChunks() async throws {
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try MockAgent.script.write(to: workspace.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        let server = try await ServerProcess.start(binary(), config: root.appendingPathComponent("config").path, extra: rootArguments)
        defer { server.kill() }
        let client = try await server.authenticated()
        let id = AgentRuntimeID("flood")
        let agent = LatchRemoteAgent.custom("/bin/sh " + AgentCommand.quotedArgument(workspace.appendingPathComponent("agent.sh").path))
        try await client.ok(.launchAgent(runtimeID: id, agent: agent, workspace: workspace.path))
        try await client.ok(.newSession(runtimeID: id))
        try await client.ok(.attach(runtimeID: id, after: 0))
        try await client.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("flood")]))
        let all = (0..<300).map { "flood-\($0)" }.joined()
        var texts: [String] = []
        _ = try await client.readFrames(until: "every chunk") { frame in
            if case let .event(event) = frame, let text = event.chunkText { texts.append(text) }
            return texts.joined() == all
        }
        XCTAssertLessThanOrEqual(texts.count, 30, "\(texts.count) events for 300 chunks")
        try await client.ok(.stopRuntime(runtimeID: id))
        XCTAssertEqual(kill(server.process.processIdentifier, SIGTERM), 0)
        let status = await server.exitStatus()
        XCTAssertEqual(status, 0)
    }

    /// Much sooner than the periodic check, which is 15 s apart.
    func testSIGHUPDropsConnectionsThatUsedARotatedToken() async throws {
        let server = try await ServerProcess.start(binary(), config: root.appendingPathComponent("config").path, extra: rootArguments)
        defer { server.kill() }
        let client = try await server.authenticated()
        let rotated = try run(["token", "--rotate", "--config-dir", server.config] + rootArguments)
        XCTAssertEqual(rotated.status, 0, rotated.error)

        XCTAssertEqual(kill(server.process.processIdentifier, SIGHUP), 0)
        try await client.expectClosed(timeout: .seconds(3))
        _ = try await server.authenticated()
        XCTAssertEqual(kill(server.process.processIdentifier, SIGTERM), 0)
        let status = await server.exitStatus()
        XCTAssertEqual(status, 0)
        let log = try await server.finishedLog()
        XCTAssertTrue(log.contains("SIGHUP: checking the token file"), log)
        XCTAssertTrue(log.contains("closed: the server token changed"), log)
    }

    func testSIGHUPDropsConnectionsOfARevokedDevice() async throws {
        let config = root.appendingPathComponent("config").path
        XCTAssertEqual(try run(["token", "--config-dir", config] + rootArguments).status, 0)
        let token = try LatchRemotePairing(parsing: run(["pair", "--host", "127.0.0.1", "--device", "phone", "--config-dir", config] + rootArguments).output).token
        let server = try await ServerProcess.start(binary(), config: config, extra: rootArguments)
        defer { server.kill() }
        let phone = try TestSocketClient(port: server.port)
        phone.hello(token: token.rawValue)
        guard case .welcome = try await phone.readFrame() else { return XCTFail("expected a welcome") }
        let shared = try await server.authenticated()

        XCTAssertEqual(try run(["devices", "--revoke", "phone", "--config-dir", config] + rootArguments).status, 0)
        XCTAssertEqual(kill(server.process.processIdentifier, SIGHUP), 0)
        try await phone.expectClosed(timeout: .seconds(3))
        shared.send(.ping)
        let pong = try await shared.readFrame()
        XCTAssertEqual(pong, .pong)
        XCTAssertEqual(kill(server.process.processIdentifier, SIGTERM), 0)
        let status = await server.exitStatus()
        XCTAssertEqual(status, 0)
        let log = try await server.finishedLog()
        XCTAssertTrue(log.contains("device tokens: phone\n"), log)
        XCTAssertTrue(log.contains("authenticated as device phone"), log)
        XCTAssertTrue(log.contains("closed: device phone's token is no longer valid"), log)
        XCTAssertFalse(log.contains(token.rawValue))
    }

    /// Every thread of the server, whatever its C library's default stack, parses JSON nested
    /// as deep as the decoder allows. Run with `LATCH_SERVER_BINARY` set to a static build.
    func testDeeplyNestedJSONDoesNotCrashTheServer() async throws {
        let server = try await ServerProcess.start(binary(), config: root.appendingPathComponent("config").path, extra: rootArguments)
        defer { server.kill() }
        let hello = try TestSocketClient(port: server.port)
        hello.send(line: #"{"type":"hello","x":"# + nestedJSON(depth: 510) + "}")
        try await hello.expectClosed()

        let client = try await server.authenticated()
        client.send(line: #"{"type":"ping","x":"# + nestedJSON(depth: 510) + "}")
        let pong = try await client.readFrame()
        XCTAssertEqual(pong, .pong)
        client.send(line: #"{"type":"ping","x":"# + nestedJSON(depth: 100_000) + "}")
        try await client.expectClosed()

        XCTAssertEqual(kill(server.process.processIdentifier, SIGTERM), 0)
        let status = await server.exitStatus()
        XCTAssertEqual(status, 0)
        XCTAssertEqual(server.process.terminationReason, .exit)
    }
}

/// A `latch-server` process listening on 127.0.0.1 with an ephemeral port.
private final class ServerProcess {
    let process: Process
    let config: String
    let port: UInt16
    let stderr: StreamCollector
    private let errorPipe: Pipe
    private let exited: AsyncStream<Int32>

    private init(process: Process, config: String, port: UInt16, stderr: StreamCollector, errorPipe: Pipe, exited: AsyncStream<Int32>) {
        self.process = process
        self.config = config
        self.port = port
        self.stderr = stderr
        self.errorPipe = errorPipe
        self.exited = exited
    }

    static func start(_ binary: URL, config: String, extra: [String]) async throws -> ServerProcess {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--listen", "127.0.0.1:0", "--config-dir", config] + extra
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let stderr = StreamCollector()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in stderr.append(handle.availableData) }
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exited.continuation.yield(process.terminationStatus)
            exited.continuation.finish()
        }
        try process.run()
        do {
            let port = try await stderr.wait("the listening line") { text -> UInt16? in
                guard let range = text.range(of: "listening on 127.0.0.1:") else { return nil }
                let digits = text[range.upperBound...].prefix { $0.isNumber }
                return text[range.upperBound...].dropFirst(digits.count).first == "\n" ? UInt16(digits) : nil
            }
            return ServerProcess(process: process, config: config, port: port, stderr: stderr, errorPipe: errorPipe, exited: exited.stream)
        } catch {
            process.terminate()
            throw error
        }
    }

    func authenticated() async throws -> TestSocketClient {
        let client = try TestSocketClient(port: port)
        client.hello(token: try ServerTokenFile(directory: config).read().rawValue)
        guard case .welcome = try await client.readFrame() else { throw HubTestError.unexpected("no welcome") }
        return client
    }

    func exitStatus() async -> Int32? {
        var statuses = exited.makeAsyncIterator()
        return await statuses.next()
    }

    /// Everything logged, once the last line is in.
    func finishedLog() async throws -> String {
        _ = try await stderr.wait("the last log line") { $0.hasSuffix("\nstopped\n") ? true : nil }
        errorPipe.fileHandleForReading.readabilityHandler = nil
        return stderr.text
    }

    /// For a test that failed before the server stopped.
    func kill() {
        if process.isRunning { process.terminate() }
    }
}

/// Bytes from a pipe, gathered as they arrive.
private final class StreamCollector: Sendable {
    private let data = Mutex(Data())

    var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }

    func append(_ chunk: Data) {
        data.withLock { $0.append(chunk) }
    }

    func wait<Value>(_ description: String, timeout: Duration = .seconds(15), _ extract: (String) -> Value?) async throws -> Value {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let value = extract(text) { return value }
            guard ContinuousClock.now < deadline else { throw HubTestError.timedOut("\(description); stderr so far:\n\(text)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
