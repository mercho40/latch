#if canImport(Network)
import Foundation
import LatchACP
@testable import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import Network
import Synchronization
import XCTest

struct TestTimeout: Error, CustomStringConvertible {
    var what: String
    var description: String { "Timed out waiting for \(what)" }
}

struct InboxFinished: Error {}

/// A buffer read by one waiter at a time, with a deadline on every read so a broken test
/// fails instead of hanging.
final class TestInbox<Element: Sendable>: Sendable {
    private struct State {
        var items: [Element] = []
        var finished = false
        var waiter: (id: UUID, continuation: CheckedContinuation<Element, any Error>)?
    }

    private let state = Mutex(State())
    private let name: String

    init(_ name: String) {
        self.name = name
    }

    func put(_ item: Element) {
        let waiter = state.withLock { state -> CheckedContinuation<Element, any Error>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter.continuation
            }
            state.items.append(item)
            return nil
        }
        waiter?.resume(returning: item)
    }

    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Element, any Error>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter?.continuation
        }
        waiter?.resume(throwing: InboxFinished())
    }

    var count: Int {
        state.withLock { $0.items.count }
    }

    func next(timeout: Double = 5) async throws -> Element {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Element, any Error>? = state.withLock { state in
                if !state.items.isEmpty { return .success(state.items.removeFirst()) }
                if state.finished { return .failure(InboxFinished()) }
                state.waiter = (id, continuation)
                return nil
            }
            if let immediate {
                continuation.resume(with: immediate)
                return
            }
            let name = name
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                let waiter = self?.state.withLock { state -> CheckedContinuation<Element, any Error>? in
                    guard state.waiter?.id == id else { return nil }
                    defer { state.waiter = nil }
                    return state.waiter?.continuation
                }
                waiter?.resume(throwing: TestTimeout(what: name))
            }
        }
    }

    /// Nothing arrives within `seconds`.
    func expectNothing(for seconds: Double) async throws {
        do {
            let item = try await next(timeout: seconds)
            XCTFail("Unexpected \(name): \(item)")
        } catch is TestTimeout {
        }
    }
}

func withTimeout<T: Sendable>(
    _ seconds: Double = 5,
    _ what: String = "an operation",
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TestTimeout(what: what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// A scripted `latch-server` on 127.0.0.1: each test reads the client's frames from the
/// connections it accepts and writes whatever the scenario needs.
final class FakeServer: Sendable {
    let port: UInt16
    /// Accepted connections not yet taken by the test.
    let connections: TestInbox<FakeConnection>
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16, connections: TestInbox<FakeConnection>) {
        self.listener = listener
        self.port = port
        self.connections = connections
    }

    static func start() async throws -> FakeServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = TestInbox<Result<UInt16, any Error>>("the listener")
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: ready.put(.success(listener?.port?.rawValue ?? 0))
            case let .failed(error): ready.put(.failure(error))
            default: break
            }
        }
        let connections = TestInbox<FakeConnection>("a connection")
        listener.newConnectionHandler = { connections.put(FakeConnection($0)) }
        listener.start(queue: DispatchQueue(label: "fake-server"))
        return FakeServer(listener: listener, port: try await ready.next().get(), connections: connections)
    }

    func nextConnection(timeout: Double = 5) async throws -> FakeConnection {
        try await connections.next(timeout: timeout)
    }

    func stop() {
        listener.cancel()
    }

    func options(token: LatchRemoteToken = Fixture.token) -> LatchRemoteConnectionOptions {
        LatchRemoteConnectionOptions(host: "127.0.0.1", port: port, token: token, client: Fixture.client, handshakeTimeout: .seconds(5))
    }

    func channelOptions(runtimeID: AgentRuntimeID = Fixture.runtimeID) -> LatchRemoteRuntimeChannel.Options {
        LatchRemoteRuntimeChannel.Options(
            connection: options(),
            runtimeID: runtimeID,
            backoff: LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200)),
            probeTimeout: .milliseconds(300)
        )
    }
}

/// The server side of one accepted connection.
final class FakeConnection: Sendable {
    let connection: NWConnection
    private let lines = TestInbox<Data>("a frame from the client")
    private let decoder = Mutex(LatchRemoteLineDecoder(maximumLineBytes: 64 * 1024 * 1024))
    private let receivedBytes = Mutex(0)
    private let ended = TestInbox<Void>("the client to close")

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: DispatchQueue(label: "fake-connection"))
        receive()
    }

    var byteCount: Int {
        receivedBytes.withLock { $0 }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                receivedBytes.withLock { $0 += data.count }
                let lines = (try? decoder.withLock { try $0.lines(appending: data) }) ?? []
                lines.forEach { self.lines.put($0) }
            }
            if isComplete || error != nil {
                lines.finish()
                ended.put(())
            } else {
                receive()
            }
        }
    }

    func nextFrame(timeout: Double = 5) async throws -> LatchRemoteClientFrame {
        try LatchRemoteCoding.decode(LatchRemoteClientFrame.self, fromLine: try await lines.next(timeout: timeout))
    }

    /// The next request, skipping heartbeat pings.
    func nextRequest(timeout: Double = 5) async throws -> LatchRemoteRequest {
        while true {
            switch try await nextFrame(timeout: timeout) {
            case let .request(request): return request
            case .ping: continue
            case let frame: throw TestTimeout(what: "a request, not \(frame)")
            }
        }
    }

    @discardableResult
    func acceptHello(heartbeatSeconds: Int = 15, maxFrameBytes: Int = LatchRemoteProtocol.maxFrameBytes) async throws -> LatchRemoteHello {
        guard case let .hello(hello) = try await nextFrame() else { throw TestTimeout(what: "a hello") }
        send(.welcome(Fixture.welcome(heartbeatSeconds: heartbeatSeconds, maxFrameBytes: maxFrameBytes)))
        return hello
    }

    /// Accepts the handshake and the channel's attach, checking its cursor.
    func acceptAttach(after expected: UInt64, record: LatchRemoteRuntimeRecord = Fixture.record(), truncated: Bool = false) async throws {
        try await acceptHello()
        let request = try await nextRequest()
        guard case let .attach(runtimeID, after) = request.command else {
            throw TestTimeout(what: "an attach, not \(request.command.kind)")
        }
        XCTAssertEqual(runtimeID, Fixture.runtimeID)
        XCTAssertEqual(after, expected, "attach cursor")
        reply(request.id, .attached(record: record, backlogFrom: after + 1, truncated: truncated))
    }

    /// The client writes nothing for `seconds`.
    func expectSilence(for seconds: Double) async throws {
        try await lines.expectNothing(for: seconds)
    }

    func send(_ frame: LatchRemoteServerFrame) {
        sendLine(try! LatchRemoteCoding.encodeLine(frame))
    }

    func sendLine(_ line: Data) {
        connection.send(content: line, completion: .idempotent)
    }

    func reply(_ id: UUID, _ response: LatchRemoteResponse) {
        send(.reply(LatchRemoteReply(id: id, result: .success(response))))
    }

    func reply(_ id: UUID, failure code: LatchRemoteFailureCode) {
        send(.reply(LatchRemoteReply(id: id, result: .failure(LatchRemoteError(code: code, message: "Fake \(code)")))))
    }

    func event(_ sequence: UInt64, _ event: LatchRemoteEvent, gap: Bool = false, runtimeID: AgentRuntimeID = Fixture.runtimeID) {
        send(.event(LatchRemoteEventFrame(runtimeID: runtimeID, sequence: sequence, event: event, gap: gap)))
    }

    func drop() {
        connection.cancel()
    }

    /// Waits for the client to close its end.
    func waitForClose(timeout: Double = 5) async throws {
        try await ended.next(timeout: timeout)
    }
}

enum Fixture {
    static let runtimeID = AgentRuntimeID("rt-1")
    static let token = LatchRemoteToken.generate()
    static let client = LatchRemoteClientInfo(name: "LatchTests", version: "1.0", platform: "macOS")
    static let server = LatchRemoteServerInfo(version: "0.2.0", hostname: "fake-vps", os: "Linux", arch: "aarch64", home: "/home/me")
    static let initialization = ACPInitializeResponse(
        protocolVersion: 1,
        agentCapabilities: ACPAgentCapabilities(loadSession: true),
        agentInfo: ACPImplementation(name: "mock-agent", version: "1.0.0")
    )

    static func welcome(heartbeatSeconds: Int = 15, maxFrameBytes: Int = LatchRemoteProtocol.maxFrameBytes) -> LatchRemoteWelcome {
        LatchRemoteWelcome(protocolVersion: 1, server: server, heartbeatSeconds: heartbeatSeconds, maxFrameBytes: maxFrameBytes)
    }

    static func record(
        activeTurnID: UUID? = nil,
        turns: [LatchRemoteTurnRecord] = [],
        lastSequence: UInt64 = 0
    ) -> LatchRemoteRuntimeRecord {
        LatchRemoteRuntimeRecord(
            runtimeID: runtimeID,
            agent: .preset("claudeCode"),
            agentTitle: "Mock",
            workspace: "/home/me/project",
            lifecycle: .ready,
            initialization: initialization,
            activeTurnID: activeTurnID,
            turns: turns,
            lastSequence: lastSequence
        )
    }
}

/// Collects a channel's streams so tests can read them with deadlines.
final class ChannelObserver: Sendable {
    let events = TestInbox<LatchRemoteChannelEvent>("a channel event")
    let links = TestInbox<LatchRemoteLinkState>("a link state")
    private let tasks: Mutex<[Task<Void, Never>]>

    init(_ channel: LatchRemoteRuntimeChannel) {
        let events = events
        let links = links
        tasks = Mutex([
            Task {
                for await event in channel.events { events.put(event) }
                events.finish()
            },
            Task {
                for await state in channel.linkStates { links.put(state) }
                links.finish()
            },
        ])
    }

    /// Reads link states until one matches.
    func waitForLink(timeout: Double = 5, _ matches: (LatchRemoteLinkState) -> Bool) async throws -> LatchRemoteLinkState {
        while true {
            let state = try await links.next(timeout: timeout)
            if matches(state) { return state }
        }
    }

    /// The next journaled event, skipping `reattached` notices.
    func nextEvent(timeout: Double = 5) async throws -> LatchRemoteChannelEvent {
        while true {
            let event = try await events.next(timeout: timeout)
            if case .reattached = event { continue }
            return event
        }
    }

    deinit {
        tasks.withLock { $0.forEach { $0.cancel() } }
    }
}
#endif

#if canImport(Network)
/// `XCTAssertEqual` without autoclosures, so its arguments may `await`.
func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}
#endif
