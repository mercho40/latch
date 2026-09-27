#if canImport(Network)
import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
import XCTest
@testable import LatchAgentServer

/// `LatchRemoteRuntimeChannel`, the Mac and iOS client, against the real server and a mock agent.
final class RemoteServerClientTests: XCTestCase {
    func testAChannelRunsTurnsAcrossADroppedConnection() async throws {
        try await withServer { testbed in
            let id = AgentRuntimeID("channel")
            let options = LatchRemoteRuntimeChannel.Options(
                host: "127.0.0.1",
                port: testbed.port,
                token: testbed.token,
                client: LatchRemoteClientInfo(name: "tests", version: "1", platform: "macOS"),
                runtimeID: id,
                backoff: LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(200)),
                probeTimeout: .milliseconds(500)
            )
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
