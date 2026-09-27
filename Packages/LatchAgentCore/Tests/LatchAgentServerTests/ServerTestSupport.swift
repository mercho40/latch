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

/// A plain POSIX client that speaks NDJSON, for testing the server byte for byte. Reads block
/// on a dispatch queue, never on a Swift concurrency thread.
final class TestSocketClient: Sendable {
    let descriptor: Int32
    private let decoder = Mutex(LatchRemoteLineDecoder(maximumLineBytes: 64 * 1024 * 1024))

    init(port: UInt16) throws {
        descriptor = socket(AF_INET, ServerSocket.streamType, 0)
        guard descriptor >= 0 else { throw ServerSocketError("socket") }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let result = ServerSocketAddress(bytes: [127, 0, 0, 1], port: port).withSocketAddress { connect(descriptor, $0, $1) }
        guard result == 0 else {
            let error = ServerSocketError("connect")
            closeDescriptor(descriptor)
            throw error
        }
    }

    deinit {
        closeDescriptor(descriptor)
    }

    /// False once the server has closed.
    @discardableResult
    func send(_ data: Data) -> Bool {
        ServerSocket.sendAll(descriptor, data)
    }

    @discardableResult
    func send(line: String) -> Bool {
        send(Data((line + "\n").utf8))
    }

    @discardableResult
    func send(_ frame: LatchRemoteClientFrame) -> Bool {
        send((try? LatchRemoteCoding.encodeLine(frame)) ?? Data())
    }

    /// False once the server has closed its end. Never blocks, and consumes nothing.
    var isOpen: Bool {
        var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
        guard poll(&descriptors, 1, 0) > 0 else { return true }
        var byte: UInt8 = 0
        return recv(descriptor, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT)) > 0
    }

    /// Shuts the socket down; the server sees the end of the stream.
    func disconnect() {
        ServerSocket.shutdownBoth(descriptor)
    }

    func hello(token: String, range: LatchRemoteVersionRange = .supported) {
        send(.hello(LatchRemoteHello(protocolRange: range, token: token, client: LatchRemoteClientInfo(name: "test", version: "1", platform: "test"))))
    }

    /// Sends a request and returns its id.
    @discardableResult
    func request(_ command: LatchRemoteCommand, id: UUID = UUID()) -> UUID {
        send(.request(LatchRemoteRequest(id: id, command: command)))
        return id
    }

    /// The next line, or nil when the server closed the connection.
    func readLine(timeout: Duration = .seconds(10)) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try self.readLineBlocking(timeout: timeout) })
            }
        }
    }

    func readFrame(timeout: Duration = .seconds(10)) async throws -> LatchRemoteServerFrame {
        guard let line = try await readLine(timeout: timeout) else { throw HubTestError.unexpected("the server closed the connection") }
        return try LatchRemoteCoding.decode(LatchRemoteServerFrame.self, fromLine: line)
    }

    /// Reads frames until one satisfies `condition`, returning all of them.
    func readFrames(until description: String, timeout: Duration = .seconds(15), _ condition: (LatchRemoteServerFrame) -> Bool) async throws -> [LatchRemoteServerFrame] {
        let deadline = ContinuousClock.now + timeout
        var frames: [LatchRemoteServerFrame] = []
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw HubTestError.timedOut(description) }
            let frame = try await readFrame(timeout: remaining)
            frames.append(frame)
            if condition(frame) { return frames }
        }
    }

    func reply(to id: UUID, timeout: Duration = .seconds(15)) async throws -> LatchRemoteReplyResult {
        let frames = try await readFrames(until: "the reply to \(id)", timeout: timeout) { frame in
            if case let .reply(reply) = frame { return reply.id == id }
            return false
        }
        guard case let .reply(reply) = frames.last else { throw HubTestError.unexpected("no reply") }
        return reply.result
    }

    @discardableResult
    func ok(_ command: LatchRemoteCommand) async throws -> LatchRemoteResponse {
        switch try await reply(to: request(command)) {
        case let .success(response): return response
        case let .failure(error): throw HubTestError.failed(error)
        }
    }

    /// Waits for the server to close, failing if it sends a frame first.
    func expectClosed(timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line) async throws {
        if let received = try await readLine(timeout: timeout) {
            XCTFail("expected the connection to close, got \(String(decoding: received, as: UTF8.self).prefix(200))", file: file, line: line)
        }
    }

    private func readLineBlocking(timeout: Duration) throws -> Data? {
        let deadline = ContinuousClock.now + timeout
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            if let line = try decoder.withLock({ try $0.nextLine() }) { return line }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw HubTestError.timedOut("no line from the server") }
            var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
            let milliseconds = Int32(min(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000 + 1, 60_000))
            let ready = poll(&descriptors, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            if ready == 0 { continue }
            let count = ServerSocket.receive(descriptor, into: buffer, count: 64 * 1024)
            // A reset after the server closed with unread input counts as closed.
            if count <= 0 { return nil }
            decoder.withLock { $0.append(Data(bytes: buffer, count: count)) }
        }
    }
}

private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}

/// `{"a":{"a":…1…}}`, `depth` objects deep.
func nestedJSON(depth: Int) -> String {
    String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
}

/// Log lines a server wrote, for assertions.
final class LogCollector: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] { lines.withLock { $0 } }

    var sink: @Sendable (String) -> Void {
        { line in self.lines.withLock { $0.append(line) } }
    }
}

extension MockAgent {
    /// Answers `initialize` and nothing else, so `newSession` waits until the agent is stopped.
    static let hangingSessionScript = #"""
    PATH=/usr/bin:/bin:$PATH
    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\n' "$id" ;;
      esac
    done
    """#
}

/// A `RemoteServer` on 127.0.0.1 with an ephemeral port, over a `HubTestbed`.
final class ServerTestbed {
    let bed: HubTestbed
    let configDirectory: String
    let tokens: ServerTokenFile
    let token: LatchRemoteToken
    let server: RemoteServer
    let port: UInt16
    let log = LogCollector()

    static let serverInfo = LatchRemoteServerInfo(version: "9.9.9", hostname: "testhost", os: "TestOS", arch: "testarch", home: "/home/tester")

    init(_ configure: (inout RemoteServerConfiguration) -> Void = { _ in }) async throws {
        bed = try await HubTestbed()
        try MockAgent.hangingSessionScript.write(
            to: bed.workspace.appendingPathComponent("hanging-session.sh"), atomically: true, encoding: .utf8
        )
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-server-\(UUID().uuidString)").path
        try ServerConfigDirectory.prepare(configDirectory)
        tokens = ServerTokenFile(directory: configDirectory)
        token = try tokens.readOrCreate()
        var configuration = RemoteServerConfiguration(serverInfo: Self.serverInfo)
        configure(&configuration)
        server = RemoteServer(hub: bed.hub, tokens: tokens, configuration: configuration, log: ServerLog(sink: log.sink))
        let listener = try ServerListener.bind(ServerSocketAddress(bytes: [127, 0, 0, 1], port: 0))
        port = listener.address.port
        server.start([listener])
    }

    func connect() throws -> TestSocketClient {
        try TestSocketClient(port: port)
    }

    /// A connection that has been welcomed.
    func authenticated() async throws -> TestSocketClient {
        let client = try connect()
        client.hello(token: token.rawValue)
        guard case .welcome = try await client.readFrame() else { throw HubTestError.unexpected("no welcome") }
        return client
    }

    /// Log lines are written on a queue of their own, after the event they describe.
    func waitForLog(_ fragment: String) async throws {
        try await eventually("a log line with \(fragment); logged \(log.all)") {
            self.log.all.contains { $0.contains(fragment) }
        }
    }

    func close() async {
        await server.shutdown()
        await bed.close()
        try? FileManager.default.removeItem(atPath: configDirectory)
    }
}

func withServer(
    _ configure: (inout RemoteServerConfiguration) -> Void = { _ in },
    _ body: (ServerTestbed) async throws -> Void
) async throws {
    let testbed = try await ServerTestbed(configure)
    do {
        try await body(testbed)
    } catch {
        await testbed.close()
        throw error
    }
    await testbed.close()
}
