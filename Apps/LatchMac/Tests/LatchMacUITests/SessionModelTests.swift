import Foundation
import XCTest
@testable import LatchMacUI

final class SessionModelTests: XCTestCase {
    @MainActor func testRejectsInvalidConfigurationWithoutStarting() async {
        let model = SessionModel()
        await model.connect(command: "relative-agent", workspace: nil)
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertNotNil(model.errorMessage)
        await model.connect(command: "/bin/sh", workspace: nil)
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.errorMessage, CommandError.workspaceRequired.localizedDescription)
        await model.disconnect()
    }

    @MainActor func testConnectPromptCancelDisconnectAndReconnect() async throws {
        let model = SessionModel()
        let command = "/bin/sh -c '" + SmokeAgent.script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.errorMessage)
        let working = expectation(description: "Streamed progress in model")
        model.onTranscriptChange = {
            if model.transcript.contains("working") {
                working.fulfill()
                model.onTranscriptChange = nil
            }
        }
        let prompt = Task { await model.send("Keep going") }
        await fulfillment(of: [working], timeout: 5)
        XCTAssertEqual(model.phase, .prompting)
        await model.cancel()
        await prompt.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.status, "Cancelled")
        XCTAssertTrue(model.transcript.contains("You\nKeep going"))
        XCTAssertTrue(model.transcript.contains("Agent\nworking"))
        await model.disconnect()
        XCTAssertEqual(model.phase, .disconnected)
        // Intentionally start an empty context; this fixture cannot resume (see SessionResumeTests).
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"), startNewSession: true)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.transcript.isEmpty)
        await model.disconnect()
    }

    @MainActor func testDisconnectsWhileAgentNeverFinishesInitialization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("received-initialize")
        let model = SessionModel()
        let finished = expectation(description: "Interrupted connect returns")
        // A private marker confirms the child has read initialize, without using chat diagnostics.
        let script = "IFS= read -r line; printf ready > " + AgentCommand.quotedArgument(marker.path)
            + "; while IFS= read -r line; do :; done"
        let attempt = Task {
            await model.connect(
                command: "/bin/sh -c " + AgentCommand.quotedArgument(script),
                workspace: directory
            )
            finished.fulfill()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Agent did not receive initialize")
        XCTAssertEqual(model.phase, .connecting)
        XCTAssertTrue(model.messages.isEmpty)
        await model.disconnect()
        await fulfillment(of: [finished], timeout: 5)
        await attempt.value
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testPermissionSelectionReachesAgent() async throws {
        let model = SessionModel()
        let prompt = try await beginPermissionPrompt(model)
        let pending = try XCTUnwrap(model.permissions.current)
        model.permissions.resolve(id: pending.id, optionID: "read-once")
        await prompt.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.permissions.current)
        // Events and prompt replies use independent tasks; wait for the echoed outcome.
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.transcript.contains("permission selected"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(model.transcript.contains("permission selected"))
        await model.disconnect()
    }

    @MainActor func testCancelAfterClickBeforeDecisionReturnsDoesNotApprove() async throws {
        let model = SessionModel()
        let prompt = try await beginPermissionPrompt(model)
        let pending = try XCTUnwrap(model.permissions.current)
        model.permissions.resolve(id: pending.id, optionID: "read-once")
        await model.cancel()
        await prompt.value
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.transcript.contains("permission cancelled"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(model.transcript.contains("permission cancelled"))
        XCTAssertFalse(model.transcript.contains("permission selected"))
        await model.disconnect()
    }

    @MainActor func testCancelAndDisconnectDrainPendingPermissions() async throws {
        for disconnect in [false, true] {
            let model = SessionModel()
            let prompt = try await beginPermissionPrompt(model)
            if disconnect { await model.disconnect() } else { await model.cancel() }
            await prompt.value
            XCTAssertNil(model.permissions.current)
            XCTAssertEqual(model.phase, disconnect ? .disconnected : .ready)
            await model.disconnect()
        }
    }

    @MainActor func testPromptCompletionDrainsPendingPermissionWithoutWaitingForDecision() async throws {
        try await exercisePendingPermissionLifecycle(agentExits: false)
    }

    @MainActor func testAgentExitDrainsPendingPermission() async throws {
        try await exercisePendingPermissionLifecycle(agentExits: true)
    }

    @MainActor private func exercisePendingPermissionLifecycle(agentExits: Bool) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let markerPath = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Insert the handshake immediately after the permission request, before reading any reply.
        // A finite shell deadline also prevents a failed pending assertion from stranding the agent.
        var lines = SmokeAgent.permissionScript.components(separatedBy: "\n")
        let requestLine = try XCTUnwrap(lines.firstIndex { $0.contains("session/request_permission") })
        lines.insert("""
          attempts=0
          while [ ! -f \(markerPath) ]; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 1000 ]; then exit 91; fi
            sleep 0.01
          done
          \(agentExits ? "exit 23" : "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}'")
        """, at: requestLine + 1)
        let model = SessionModel()
        let finished = expectation(description: "Prompt returns without a permission decision")
        let prompt = try await beginPermissionPrompt(
            model, script: lines.joined(separator: "\n"), finished: finished
        )
        guard model.permissions.current != nil else {
            await model.disconnect()
            prompt.cancel()
            return
        }
        XCTAssertEqual(model.phase, .prompting)
        // Only release the agent once the permission is visibly pending.
        do { try Data().write(to: marker) }
        catch {
            await model.disconnect()
            prompt.cancel()
            throw error
        }
        await fulfillment(of: [finished], timeout: 5)
        if agentExits {
            // Process termination and the failed prompt arrive on independent tasks.
            let deadline = ContinuousClock.now + .seconds(5)
            while model.phase != .disconnected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.phase, .disconnected)
            XCTAssertEqual(model.status, "Agent exited (23)")
            XCTAssertNotNil(model.errorMessage)
        } else {
            XCTAssertEqual(model.phase, .ready)
            XCTAssertEqual(model.status, "Ready · end_turn")
            XCTAssertNil(model.errorMessage)
        }
        XCTAssertNil(model.permissions.current)
        await model.disconnect()
        prompt.cancel()
    }

    @MainActor func testWrongSessionPermissionIsAutomaticallyCancelled() async throws {
        let model = SessionModel()
        let script = SmokeAgent.permissionScript
            .replacingOccurrences(
                of: "\"params\":{\"sessionId\":\"session-1\",\"toolCall\"",
                with: "\"params\":{\"sessionId\":\"wrong-session\",\"toolCall\""
            )
            .replacingOccurrences(
                of: "*) text='permission cancelled' ;;",
                with: "*\\\"outcome\\\":\\\"cancelled\\\"*) text='permission cancelled' ;;\n            *) text='unexpected permission response' ;;"
            )
        let command = "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .ready)
        var presentedPermission = false
        model.onChange = {
            presentedPermission = presentedPermission || model.permissions.current != nil
        }
        let finished = expectation(description: "Wrong-session permission does not block the prompt")
        let prompt = Task {
            await model.send("Read example.txt")
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.transcript.contains("permission cancelled"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.transcript.contains("permission cancelled"))
        XCTAssertFalse(presentedPermission)
        XCTAssertNil(model.permissions.current)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.status, "Ready · end_turn")
        XCTAssertNil(model.errorMessage)
        model.onChange = nil
        await model.disconnect()
        prompt.cancel()
    }

    @MainActor private func beginPermissionPrompt(
        _ model: SessionModel, script: String = SmokeAgent.permissionScript,
        finished: XCTestExpectation? = nil
    ) async throws -> Task<Void, Never> {
        let command = "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .ready)
        let pending = expectation(description: "Permission request received")
        model.onChange = {
            if model.permissions.current != nil {
                pending.fulfill()
                model.onChange = nil
            }
        }
        let prompt = Task {
            await model.send("Read example.txt")
            finished?.fulfill()
        }
        await fulfillment(of: [pending], timeout: 5)
        return prompt
    }

    @MainActor func testFailedInitializationAllowsRetry() async {
        let model = SessionModel()
        await model.connect(command: "/bin/false", workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertNotNil(model.errorMessage)
        let command = "/bin/sh -c '" + SmokeAgent.script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.errorMessage)
        await model.disconnect()
    }
}
