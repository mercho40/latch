#if canImport(Network)
import Foundation
import LatchACP
import LatchAgentCore
@testable import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
import XCTest
@testable import LatchAgentServer

/// `LatchRemoteRuntimeChannel`, the Mac and iOS client, against the real server and a mock agent.
final class RemoteServerClientTests: XCTestCase {
    func testAChannelRunsTurnsAcrossADroppedConnection() async throws {
        try await runTurnsAcrossADroppedConnection(webSocket: false)
    }

    /// The same inside a WebSocket, as through a TLS proxy, without the TLS.
    func testAChannelRunsTurnsAcrossADroppedWebSocket() async throws {
        try await runTurnsAcrossADroppedConnection(webSocket: true)
    }

    private func runTurnsAcrossADroppedConnection(webSocket: Bool) async throws {
        try await withServer { testbed in
            let id = AgentRuntimeID("channel")
            var options = LatchRemoteRuntimeChannel.Options(
                host: "127.0.0.1",
                port: testbed.port,
                token: testbed.token,
                client: LatchRemoteClientInfo(name: "tests", version: "1", platform: "macOS"),
                runtimeID: id,
                backoff: LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200)),
                probeTimeout: .milliseconds(500)
            )
            if webSocket { options.connection.useWebSocketWithoutTLSForTesting() }
            let channel = LatchRemoteRuntimeChannel(options: options)
            channel.start()
            let events = ChannelRecorder(channel.events)
            defer { channel.close() }

            let initialization = try await channel.launch(agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path)
            XCTAssertEqual(initialization.agentInfo?.name, "mock-agent")
            guard case .sessionCreated = try await channel.send(.newSession(runtimeID: id)) else { return XCTFail("expected a session") }

            // A turn whose chunks stream in.
            let first = try await channel.prompt(turnID: UUID(), blocks: [.text("hello")])
            XCTAssertEqual(first.stopReason, "end_turn")
            try await events.wait("the first turn's chunks") { $0.chunkTexts == ["one", "two", "three"] }

            // A permission round trip.
            let asking = UUID()
            async let asked = channel.prompt(turnID: asking, blocks: [.text("permission please")])
            let requestID = try await events.wait("a permission request") { events in
                events.lazy.compactMap { event -> UUID? in
                    if case let .permissionRequested(requestID, _) = event { requestID } else { nil }
                }.first
            }
            let resolved = try await channel.send(.resolvePermission(runtimeID: id, requestID: requestID, outcome: .selected(optionID: "allow-once")))
            XCTAssertEqual(resolved, .permissionResolved)
            let allowed = try await asked
            XCTAssertEqual(allowed.stopReason, "end_turn")
            try await events.wait("the allowed chunk") { $0.chunkTexts.contains("allowed") }

            // The connection drops mid-turn; the channel reconnects and the turn completes, once.
            let slow = UUID()
            async let slowOutcome = channel.prompt(turnID: slow, blocks: [.text("slow")])
            try await events.wait("the slow turn's start") { events in
                events.contains { if case let .turnStarted(turnID, _, _) = $0 { turnID == slow } else { false } }
            }
            channel.dropConnectionForTesting()
            let completed = try await slowOutcome
            XCTAssertEqual(completed.stopReason, "end_turn")
            // Three from the first turn, `asking` and `allowed`, then the slow turn's three.
            try await events.wait("the slow turn's chunks") { $0.chunkTexts.count == 8 }
            XCTAssertEqual(events.events.chunkTexts.suffix(3), ["one", "two", "three"])
            XCTAssertEqual(testbed.bed.lines(in: "prompts.log"), 3)
            XCTAssertTrue(events.reattached)
            XCTAssertEqual(events.sequences, Array(1...UInt64(events.sequences.count)))

            // A second channel attaching from the start sees the whole backlog.
            let second = LatchRemoteRuntimeChannel(options: options)
            second.start()
            defer { second.close() }
            let backlog = ChannelRecorder(second.events)
            let attachment = try await second.attach(after: 0)
            XCTAssertEqual(attachment.backlogFrom, 1)
            XCTAssertFalse(attachment.truncated)
            XCTAssertEqual(attachment.record.sessionID, "session-1")
            let seen = events.sequences
            try await backlog.wait("the backlog") { _ in backlog.sequences.count >= seen.count }
            XCTAssertEqual(Array(backlog.sequences.prefix(seen.count)), seen)

            // Stopping ends the runtime for both.
            let received = try await channel.send(.stopRuntime(runtimeID: id))
            XCTAssertEqual(received, .stopped)
            for recorder in [events, backlog] {
                try await recorder.wait("the exit") { events in
                    events.contains { if case .exited(LatchRemoteExit(status: nil, stopped: true)) = $0 { true } else { false } }
                }
            }
        }
    }

    /// Two requests of several megabytes each, such as edits with large diffs, would make a
    /// record too large for one frame, and every re-attach would be refused.
    func testAChannelReattachesToARuntimeWithLargePendingRequests() async throws {
        try await reattachWithLargePendingRequests(webSocket: false)
    }

    /// Each of those frames crosses a WebSocket as many messages.
    func testAChannelReattachesOverAWebSocketWithLargePendingRequests() async throws {
        try await reattachWithLargePendingRequests(webSocket: true)
    }

    private func reattachWithLargePendingRequests(webSocket: Bool) async throws {
        try await withServer { testbed in
            let script = #"""
            PATH=/usr/bin:/bin:$PATH
            reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
            while IFS= read -r line; do
              id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
              case "$line" in
                *\"method\":\"initialize\"*)
                  reply "$id" '{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}' ;;
                *\"method\":\"session*/new\"*)
                  reply "$id" '{"sessionId":"session-1"}' ;;
                *\"method\":\"session*/prompt\"*)
                  big=$(printf '%04500000d' 0)
                  for n in 900 901; do
                    printf '{"jsonrpc":"2.0","id":%s,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"call-%s","title":"%s"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"}]}}\n' "$n" "$n" "$big"
                  done ;;
              esac
            done
            """#
            try script.write(to: testbed.bed.workspace.appendingPathComponent("big.sh"), atomically: true, encoding: .utf8)
            let id = AgentRuntimeID("big")
            var options = LatchRemoteRuntimeChannel.Options(
                host: "127.0.0.1", port: testbed.port, token: testbed.token,
                client: LatchRemoteClientInfo(name: "tests", version: "1", platform: "macOS"),
                runtimeID: id, backoff: LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200)))
            if webSocket { options.connection.useWebSocketWithoutTLSForTesting() }
            let channel = LatchRemoteRuntimeChannel(options: options)
            channel.start()
            let events = ChannelRecorder(channel.events)
            defer { channel.close() }
            _ = try await channel.launch(agent: testbed.bed.script("big.sh"), workspace: testbed.bed.workspace.path)
            _ = try await channel.send(.newSession(runtimeID: id))
            let turn = Task { try? await channel.prompt(turnID: UUID(), blocks: [.text("big")]) }
            defer { turn.cancel() }
            try await eventually("both requests pending") { try await testbed.bed.summary(id).pendingPermissionCount == 2 }
            try await events.wait("both requests delivered") { events in
                events.count { if case .permissionRequested = $0 { true } else { false } } == 2
            }

            channel.dropConnectionForTesting()
            let answered = try await channel.send(.listRuntimes)
            guard case .runtimes = answered else { return XCTFail("\(answered)") }
            XCTAssertEqual(channel.linkState, .connected)
            XCTAssertTrue(events.reattached)
            let record = try await testbed.bed.record(id)
            XCTAssertEqual(record.pendingPermissions.count, 2)
        }
    }

    /// As when Latch launches with many sessions on one server: each opens a connection of
    /// its own at the same moment.
    func testManyChannelsConnectingAtOnceAllGetIn() async throws {
        try await withServer { testbed in
            let channels = (0..<40).map { index in
                LatchRemoteRuntimeChannel(options: LatchRemoteRuntimeChannel.Options(
                    host: "127.0.0.1", port: testbed.port, token: testbed.token,
                    client: LatchRemoteClientInfo(name: "tests", version: "1", platform: "macOS"),
                    runtimeID: AgentRuntimeID("storm-\(index)")))
            }
            defer { channels.forEach { $0.close() } }
            channels.forEach { $0.start() }
            // Well inside the Mac app's 15-second limit on a first connection.
            try await eventually("every channel connected", timeout: .seconds(8)) {
                channels.allSatisfy(\.hasConnected)
            }
        }
    }
}

/// Collects a channel's events as they arrive.
private final class ChannelRecorder: Sendable {
    private final class Storage: Sendable {
        let state = Mutex<(events: [(UInt64, LatchRemoteEvent)], reattached: Bool)>(([], false))
    }

    private let storage: Storage
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<LatchRemoteChannelEvent>) {
        let storage = Storage()
        self.storage = storage
        task = Task {
            for await event in stream {
                storage.state.withLock { state in
                    switch event {
                    case let .event(sequence, event): state.events.append((sequence, event))
                    case .reattached: state.reattached = true
                    case .gap: break
                    }
                }
            }
        }
    }

    deinit {
        task.cancel()
    }

    var events: [LatchRemoteEvent] { storage.state.withLock { $0.events.map(\.1) } }
    var sequences: [UInt64] { storage.state.withLock { $0.events.map(\.0) } }
    var reattached: Bool { storage.state.withLock { $0.reattached } }

    func wait(_ description: String, _ condition: ([LatchRemoteEvent]) -> Bool) async throws {
        _ = try await wait(description) { condition($0) ? true : nil }
    }

    func wait<Value>(_ description: String, _ extract: ([LatchRemoteEvent]) -> Value?) async throws -> Value {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            if let value = extract(events) { return value }
            guard ContinuousClock.now < deadline else { throw HubTestError.timedOut("\(description); saw \(events.map(\.kind))") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private extension Array where Element == LatchRemoteEvent {
    var chunkTexts: [String] {
        compactMap { LatchRemoteEventFrame(runtimeID: AgentRuntimeID("x"), sequence: 0, event: $0).chunkText }
    }
}
#endif
