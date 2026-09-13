import Foundation
import XCTest
import LatchACP
import LatchServiceProtocol
@testable import LatchAgentCore

final class LoadSessionServiceTests: XCTestCase {
    func testPersistedSessionLoadsInFreshRuntimeAndContinues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LatchAgentService()
        let id = AgentRuntimeID("resume")
        let profile = ACPCommandProfile(executablePath: "/bin/sh", arguments: ["-c", Self.server], workingDirectoryPath: directory.path)
        do {
            _ = try await service.execute(.startRuntime(id: id, profile: profile))
            let created = try await service.execute(.newSession(runtimeID: id, cwd: directory.path))
            guard case let .sessionCreated(_, session) = created else { throw TestError.unexpectedReply }
            XCTAssertEqual(session.sessionId, "saved")
            _ = try await service.execute(.stopRuntime(id: id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("saved-session").path))
            _ = try await service.execute(.startRuntime(id: id, profile: profile))
            let request = LatchAgentRequest(command: .loadSession(runtimeID: id, sessionID: session.sessionId, cwd: directory.path))
            // Exercise the serialized transport-neutral boundary, not just direct registry calls.
            let decoded = try JSONDecoder().decode(LatchAgentRequest.self, from: JSONEncoder().encode(request))
            let reply = await service.handle(decoded)
            let roundTrip = try JSONDecoder().decode(LatchAgentReply.self, from: JSONEncoder().encode(reply))
            guard case let .success(.sessionLoaded(runtimeID, response)) = roundTrip.result else { throw TestError.unexpectedReply }
            XCTAssertEqual(runtimeID, id)
            XCTAssertEqual(response.localSequence, 3)
            XCTAssertEqual(response.configOptions, [])
            XCTAssertEqual(response.models, .object(["currentModelId": .string("model-b")]))
            XCTAssertEqual(response.modes, .object(["currentModeId": .string("ask")]))
            var events = service.events.makeAsyncIterator()
            let event = await events.next()
            guard case let .sessionUpdate(eventID, notification)? = event else { throw TestError.unexpectedReply }
            XCTAssertEqual(eventID, id)
            XCTAssertEqual(notification.sessionId, "saved")
            XCTAssertEqual(notification.localSequence, 2)
            let continued = try await service.execute(.prompt(runtimeID: id, text: "continue mock session"))
            XCTAssertEqual(continued, .promptCompleted(runtimeID: id, response: ACPPromptResponse(stopReason: "end_turn")))
            await service.shutdown()
        } catch {
            await service.shutdown()
            throw error
        }
    }

    func testUnsupportedLoadAndMissingRuntimeReturnFailures() async throws {
        let service = LatchAgentService()
        let id = AgentRuntimeID("unsupported")
        let missing = await service.handle(LatchAgentRequest(command: .loadSession(runtimeID: id, sessionID: "saved", cwd: "/tmp")))
        guard case .failure = missing.result else { return XCTFail("Expected missing runtime failure") }
        let script = Self.server.replacingOccurrences(of: "\"loadSession\":true", with: "\"loadSession\":false")
        _ = try await service.execute(.startRuntime(id: id, profile: ACPCommandProfile(
            executablePath: "/bin/sh", arguments: ["-c", script], workingDirectoryPath: "/tmp"
        )))
        let reply = await service.handle(LatchAgentRequest(command: .loadSession(runtimeID: id, sessionID: "saved", cwd: "/tmp")))
        await service.shutdown()
        guard case let .failure(failure) = reply.result else { return XCTFail("Expected unsupported load failure") }
        XCTAssertEqual(failure.code, .commandFailed)
    }

    private enum TestError: Error { case unexpectedReply }

    // No live agent, timing delays, or network. Each request determines the next frame.
    // The file models agent-owned persistence across subprocess replacement.
    private static let server = #"""
    while IFS= read -r line; do
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}' ;;
        *\"method\":\"session*new\"*)
          printf '%s\n' 'history' > saved-session
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"saved"}}' ;;
        *\"method\":\"session*load\"*)
          if [ -f saved-session ]; then
            printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"saved","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"history"}}}}'
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"configOptions":[],"models":{"currentModelId":"model-b"},"modes":{"currentModeId":"ask"},"localSequence":"forged"}}'
          else
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Session missing"}}'
          fi ;;
        *\"method\":\"session*prompt\"*)
          case "$line" in
            *\"sessionId\":\"saved\"*) printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}' ;;
            *) printf '%s\n' '{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Wrong session"}}' ;;
          esac ;;
      esac
    done
    """#
}
