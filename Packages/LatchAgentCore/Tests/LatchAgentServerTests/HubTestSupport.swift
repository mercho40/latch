import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
import XCTest
@testable import LatchAgentServer

/// A capable ACP agent in `sh`. Every `case` matches one JSON key, never two: Latch's encoder
/// orders keys differently in every process. A load replays a question, two chunks of answer
/// and a tool call around them; the session ID picks a load with no history (`empty`), with a
/// chunk of 4000 characters before the last (`huge`), or one that sends all of its history a
/// second before it replies (`slow`). The prompt text picks the turn's behavior, and
/// `sessions.log` and `prompts.log` in the workspace count what actually reached the agent. It
/// sets its own PATH so tests can launch it with a minimal environment.
enum MockAgent {
    static let script = #"""
    PATH=/usr/bin:/bin:$PATH
    session=session-1
    prompt_id=
    reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
    update() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":%s}}\n' "$session" "$1"; }
    chunk() { update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"'"$1"'"}}'; }
    ask() {
      printf '%s\n' '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"'"$session"'","toolCall":{"toolCallId":"call-1","title":"Edit file"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
    }
    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *\"method\":\"initialize\"*)
          reply "$id" '{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}' ;;
        *\"method\":\"session*/new\"*)
          echo new >> sessions.log
          reply "$id" '{"sessionId":"session-1","configOptions":[{"id":"effort","name":"Effort","type":"select","currentValue":"low","options":[{"value":"low","name":"Low"},{"value":"high","name":"High"}]}],"modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]},"models":{"currentModelId":"model-a","availableModels":[{"modelId":"model-a","name":"Model A"},{"modelId":"model-b","name":"Model B"}]}}' ;;
        *\"method\":\"session*/load\"*)
          echo load >> sessions.log
          session=saved-1
          case "$line" in
            *empty*) ;;
            *)
              update '{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"earlier question"}}'
              chunk "history one"
              update '{"sessionUpdate":"tool_call","toolCallId":"call-h","title":"Read notes","status":"completed"}'
              case "$line" in *huge*) chunk "$(printf '%04000d' 0)" ;; esac
              chunk "history two" ;;
          esac
          case "$line" in *slow*) sleep 1 ;; esac
          reply "$id" '{"modes":{"currentModeId":"code","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]}}' ;;
        *\"method\":\"session*/set_config_option\"*)
          reply "$id" '{"configOptions":[{"id":"effort","name":"Effort","type":"select","currentValue":"high","options":[{"value":"low","name":"Low"},{"value":"high","name":"High"}]}]}' ;;
        *\"method\":\"session*/set_mode\"*)
          update '{"sessionUpdate":"current_mode_update","currentModeId":"code"}'
          reply "$id" '{}' ;;
        *\"method\":\"session*/set_model\"*)
          reply "$id" '{}' ;;
        *\"method\":\"session*/prompt\"*)
          echo prompt >> prompts.log
          prompt_id=$id
          case "$line" in
            *permission*) chunk asking; ask ;;
            *crash*) chunk asking; ask; sleep 1; exit 3 ;;
            *oversize*) chunk "$(printf '%04000d' 0)"; reply "$id" '{"stopReason":"end_turn"}' ;;
            *flood*) i=0; while [ $i -lt 300 ]; do chunk "flood-$i"; i=$((i+1)); done; sleep 5; reply "$id" '{"stopReason":"end_turn"}' ;;
            *slow*) sleep 1; chunk one; chunk two; chunk three; reply "$id" '{"stopReason":"end_turn"}' ;;
            *) chunk one; chunk two; chunk three; reply "$id" '{"stopReason":"end_turn"}' ;;
          esac ;;
        *\"id\":900[,}]*)
          case "$line" in
            *\"selected\"*) chunk allowed; reply "$prompt_id" '{"stopReason":"end_turn"}' ;;
            *) reply "$prompt_id" '{"stopReason":"cancelled"}' ;;
          esac ;;
      esac
    done
    """#

    /// Answers `initialize` and exits at once, racing the launch's reply.
    static let exitAfterInitializeScript = #"""
    PATH=/usr/bin:/bin:$PATH
    IFS= read -r line
    id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\n' "$id"
    exit 4
    """#

    /// Answers `initialize` with ACP's authentication-required error.
    static let signedOutScript = #"""
    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"Authentication required"}}\n' "$id" ;;
      esac
    done
    """#
}

enum HubTestError: Error, CustomStringConvertible {
    case failed(LatchRemoteError)
    case unexpected(String)
    case timedOut(String)

    var description: String {
        switch self {
        case let .failed(error): "request failed: \(error.code) \(error.message)"
        case let .unexpected(message): "unexpected: \(message)"
        case let .timedOut(message): "timed out: \(message)"
        }
    }
}

final class TestClock: Sendable {
    let base = ContinuousClock.now
    private let offset = Mutex(Duration.zero)

    var now: ContinuousClock.Instant { base + offset.withLock { $0 } }

    func set(_ duration: Duration) {
        offset.withLock { $0 = duration }
    }
}

final class WakeCounter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

/// A hub over a real `LatchAgentService`, with a temporary workspace holding the mock agent.
final class HubTestbed {
    let workspace: URL
    let service = LatchAgentService()
    let hub: RemoteRuntimeHub
    let clock = TestClock()
    /// For requests whose connection does not matter.
    let control: RemoteConnectionID

    init(
        configuration: RemoteRuntimeHubConfiguration = RemoteRuntimeHubConfiguration(),
        launchEnvironment: (@Sendable () -> AgentLaunchEnvironment)? = nil,
        homeDirectory: String? = nil,
        lifecycle: (@Sendable (AgentRuntimeID, RemoteRuntimeLifecycleEvent) -> Void)? = nil
    ) async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-hub-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try MockAgent.script.write(to: workspace.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        try MockAgent.signedOutScript.write(to: workspace.appendingPathComponent("signed-out.sh"), atomically: true, encoding: .utf8)
        try MockAgent.exitAfterInitializeScript.write(
            to: workspace.appendingPathComponent("exit-after-initialize.sh"), atomically: true, encoding: .utf8
        )
        let clock = clock
        hub = RemoteRuntimeHub(
            service: service,
            configuration: configuration,
            launchEnvironment: launchEnvironment ?? { AgentLaunchEnvironment() },
            homeDirectory: homeDirectory ?? workspace.path,
            clock: { clock.now },
            lifecycle: lifecycle
        )
        control = hub.openConnection(wake: {})
        await hub.start()
    }

    func close() async {
        await hub.shutdown()
        try? FileManager.default.removeItem(at: workspace)
    }

    var mockAgent: LatchRemoteAgent { script("agent.sh") }

    func script(_ name: String) -> LatchRemoteAgent {
        .custom("/bin/sh " + AgentCommand.quotedArgument(workspace.appendingPathComponent(name).path))
    }

    func send(_ command: LatchRemoteCommand, from connection: RemoteConnectionID? = nil) async -> LatchRemoteReplyResult {
        await hub.handle(command, from: connection ?? control)
    }

    @discardableResult
    func ok(_ command: LatchRemoteCommand, from connection: RemoteConnectionID? = nil) async throws -> LatchRemoteResponse {
        switch await send(command, from: connection) {
        case let .success(response): return response
        case let .failure(error): throw HubTestError.failed(error)
        }
    }

    func failure(_ command: LatchRemoteCommand) async throws -> LatchRemoteError {
        switch await send(command) {
        case let .success(response): throw HubTestError.unexpected("\(command.kind) succeeded with \(response.kind)")
        case let .failure(error): return error
        }
    }

    func expect(
        _ command: LatchRemoteCommand,
        returns expected: LatchRemoteResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let response = try await ok(command)
        XCTAssertEqual(response, expected, file: file, line: line)
    }

    func expect(
        _ command: LatchRemoteCommand,
        fails code: LatchRemoteFailureCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let error = try await failure(command)
        XCTAssertEqual(error.code, code, error.message, file: file, line: line)
    }

    func expect(
        _ id: AgentRuntimeID,
        lifecycle: LatchRemoteLifecycle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let summary = try await summary(id)
        XCTAssertEqual(summary.lifecycle, lifecycle, "\(id)", file: file, line: line)
    }

    @discardableResult
    func launch(_ id: AgentRuntimeID, workspace path: String? = nil) async throws -> ACPInitializeResponse {
        let response = try await ok(.launchAgent(runtimeID: id, agent: mockAgent, workspace: path ?? workspace.path))
        guard case let .launched(initialization) = response else { throw HubTestError.unexpected(response.kind) }
        return initialization
    }

    @discardableResult
    func launchWithSession(_ id: AgentRuntimeID) async throws -> ACPNewSessionResponse {
        try await launch(id)
        let response = try await ok(.newSession(runtimeID: id))
        guard case let .sessionCreated(session) = response else { throw HubTestError.unexpected(response.kind) }
        return session
    }

    func summary(_ id: AgentRuntimeID) async throws -> LatchRemoteRuntimeSummary {
        let response = try await ok(.listRuntimes)
        guard case let .runtimes(summaries) = response, let summary = summaries.first(where: { $0.runtimeID == id }) else {
            throw HubTestError.unexpected("no summary for \(id)")
        }
        return summary
    }

    func record(_ id: AgentRuntimeID) async throws -> LatchRemoteRuntimeRecord {
        // A throwaway connection. Closing it restarts the runtime's detached timeout.
        let probe = hub.openConnection(wake: {})
        defer { hub.closeConnection(probe) }
        let response = try await ok(.attach(runtimeID: id, after: 0), from: probe)
        guard case let .attached(record, _, _) = response else { throw HubTestError.unexpected(response.kind) }
        return record
    }

    /// Waits until the runtime has no turn running and has journaled at least `sequence` events.
    func waitForIdle(_ id: AgentRuntimeID, through sequence: UInt64) async throws {
        try await eventually("\(id) idle through \(sequence)") {
            let summary = try await self.summary(id)
            return summary.activeTurnID == nil && summary.lastSequence >= sequence
        }
    }

    func lines(in file: String) -> Int {
        let text = (try? String(contentsOf: workspace.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    func viewer() -> Viewer {
        Viewer(hub: hub)
    }
}

/// One connection's view: attaches like a connection layer would and decodes what it pulls.
final class Viewer {
    let hub: RemoteRuntimeHub
    let connection: RemoteConnectionID
    let wakes = WakeCounter()
    private(set) var frames: [LatchRemoteEventFrame] = []

    init(hub: RemoteRuntimeHub) {
        self.hub = hub
        let wakes = wakes
        connection = hub.openConnection(wake: { wakes.increment() })
    }

    /// Attaches and activates at once, as a connection layer's writer does after writing the reply.
    @discardableResult
    func attach(_ id: AgentRuntimeID, after: UInt64 = 0) async throws -> (record: LatchRemoteRuntimeRecord, backlogFrom: UInt64, truncated: Bool) {
        let result = try await attachInactive(id, after: after)
        hub.activateAttachment(of: id, for: connection)
        return result
    }

    @discardableResult
    func attachInactive(_ id: AgentRuntimeID, after: UInt64 = 0) async throws -> (record: LatchRemoteRuntimeRecord, backlogFrom: UInt64, truncated: Bool) {
        switch await hub.handle(.attach(runtimeID: id, after: after), from: connection) {
        case let .success(.attached(record, backlogFrom, truncated)): return (record, backlogFrom, truncated)
        case let .success(response): throw HubTestError.unexpected(response.kind)
        case let .failure(error): throw HubTestError.failed(error)
        }
    }

    /// Pulls once and decodes, checking each line is a complete frame.
    @discardableResult
    func pull(byteBudget: Int = 1 << 20) throws -> [LatchRemoteEventFrame] {
        let pulled = try hub.pullEventLines(for: connection, byteBudget: byteBudget).map { line in
            guard line.last == 0x0A else { throw HubTestError.unexpected("a line without its newline") }
            let frame = try LatchRemoteCoding.decode(LatchRemoteServerFrame.self, fromLine: line.dropLast())
            guard case let .event(event) = frame else { throw HubTestError.unexpected("a frame that is not an event") }
            return event
        }
        frames += pulled
        return pulled
    }

    /// Pulls until everything pulled so far satisfies `condition`.
    @discardableResult
    func pull(
        until description: String,
        timeout: Duration = .seconds(15),
        _ condition: ([LatchRemoteEventFrame]) -> Bool
    ) async throws -> [LatchRemoteEventFrame] {
        let deadline = ContinuousClock.now + timeout
        while !condition(frames) {
            if try pull().isEmpty {
                guard ContinuousClock.now < deadline else {
                    throw HubTestError.timedOut("\(description); pulled \(frames.map(\.event.kind))")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        return frames
    }

    func close() {
        hub.closeConnection(connection)
    }
}

func eventually(
    _ description: String,
    timeout: Duration = .seconds(15),
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw HubTestError.timedOut(description) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

func withTestbed(
    configuration: RemoteRuntimeHubConfiguration = RemoteRuntimeHubConfiguration(),
    launchEnvironment: (@Sendable () -> AgentLaunchEnvironment)? = nil,
    homeDirectory: String? = nil,
    _ body: (HubTestbed) async throws -> Void
) async throws {
    let testbed = try await HubTestbed(
        configuration: configuration, launchEnvironment: launchEnvironment, homeDirectory: homeDirectory
    )
    do {
        try await body(testbed)
    } catch {
        await testbed.close()
        throw error
    }
    await testbed.close()
}

extension LatchRemoteEventFrame {
    /// The text of an `agent_message_chunk`, if this is one.
    var chunkText: String? { text(of: "agent_message_chunk") }

    /// The `sessionUpdate` kind of a session update, and for a message chunk its text.
    var updateSummary: String? {
        guard case let .sessionUpdate(notification, _) = event, case let .object(update) = notification.update,
              case let .string(kind)? = update["sessionUpdate"] else { return nil }
        return text(of: kind).map { "\(kind): \($0)" } ?? kind
    }

    var isReplay: Bool {
        if case .sessionUpdate(_, replay: true) = event { return true }
        return false
    }

    private func text(of kind: String) -> String? {
        guard case let .sessionUpdate(notification, _) = event, case let .object(update) = notification.update,
              update["sessionUpdate"] == .string(kind),
              case let .object(content)? = update["content"], case let .string(text)? = content["text"] else { return nil }
        return text
    }

    var isTurnEnded: Bool {
        if case .turnEnded = event { return true }
        return false
    }
}

extension Collection where Element == LatchRemoteEventFrame {
    var chunkTexts: [String] { compactMap(\.chunkText) }
    var turnEnded: LatchRemoteEventFrame? { first(where: \.isTurnEnded) }
}
