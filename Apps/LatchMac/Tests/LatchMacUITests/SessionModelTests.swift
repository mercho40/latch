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
        model.onChange = {
            if model.transcript.contains("working") {
                working.fulfill()
                model.onChange = nil
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
        await model.connect(command: command, workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.transcript.isEmpty)
        await model.disconnect()
    }

    @MainActor func testDisconnectsWhileAgentNeverFinishesInitialization() async {
        let model = SessionModel()
        let waiting = expectation(description: "Agent started but is not answering initialize")
        let finished = expectation(description: "Interrupted connect returns")
        model.onChange = {
            if model.transcript.contains("waiting") {
                waiting.fulfill()
                model.onChange = nil
            }
        }
        let attempt = Task {
            await model.connect(
                command: "/bin/sh -c 'printf waiting >&2; while IFS= read -r line; do :; done'",
                workspace: URL(fileURLWithPath: "/tmp")
            )
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(model.phase, .connecting)
        await model.disconnect()
        await fulfillment(of: [finished], timeout: 5)
        attempt.cancel()
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertNil(model.errorMessage)
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
