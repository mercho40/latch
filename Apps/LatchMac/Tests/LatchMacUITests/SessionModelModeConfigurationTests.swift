import Foundation
import XCTest
@testable import LatchMacUI

final class SessionModelModeConfigurationTests: XCTestCase {
    @MainActor func testModernInitialModeAndEffort() async {
        let model = await connected()
        XCTAssertEqual(model.configuration.permissionMode?.route, .config("mode"))
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "fast")
        XCTAssertEqual(model.configuration.permissionMode?.choices.map(\.value), ["fast", "deep"])
        XCTAssertEqual(model.configuration.effort?.route, .config("effort"))
        XCTAssertEqual(model.configuration.effort?.currentValue, "low")
        XCTAssertEqual(model.configuration.effort?.choices.map(\.value), ["low", "high"])
        XCTAssertFalse(model.isChangingConfiguration)
        await finish(model)
    }

    @MainActor func testModeChangeReplacesFullEffortSnapshot() async {
        let model = await connected()
        await run { await model.select(.permissionMode, value: "deep") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        XCTAssertEqual(model.configuration.effort?.currentValue, "high")
        XCTAssertEqual(model.configuration.effort?.choices.map(\.value), ["high"])
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertNil(model.errorMessage)
        let confirmed = model.configuration
        await run { await model.select(.effort, value: "low") }
        XCTAssertEqual(model.configuration, confirmed)
        XCTAssertNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testEffortSuccessThenModeSuccessForUISmoke() async {
        let model = await connected()
        await run { await model.select(.effort, value: "high") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "fast")
        XCTAssertEqual(model.configuration.effort?.currentValue, "high")
        XCTAssertEqual(model.configuration.effort?.choices.map(\.value), ["low", "high"])
        XCTAssertNil(model.errorMessage)
        await run { await model.select(.permissionMode, value: "deep") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        XCTAssertEqual(model.configuration.effort?.choices.map(\.value), ["high"])
        XCTAssertNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testErrorKeepsConfirmedSelection() async {
        let model = await connected(.rejectEffort)
        let confirmed = model.configuration
        await run { await model.select(.effort, value: "high") }
        XCTAssertEqual(model.configuration, confirmed)
        XCTAssertEqual(model.errorMessage, "Effort rejected")
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertEqual(model.phase, .ready)
        // A failed change must not leave the configuration lock held.
        await run { await model.select(.permissionMode, value: "deep") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        XCTAssertNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testUnavailableUnofferedAndUnchangedSelectionsAreIgnored() async {
        let model = await connected(.legacy)
        let confirmed = model.configuration
        var changes = 0
        model.onChange = { changes += 1 }
        await run { await model.select(.effort, value: "high") }
        await run { await model.select(.permissionMode, value: "not-offered") }
        await run { await model.select(.permissionMode, value: "fast") }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.configuration, confirmed)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isChangingConfiguration)
        model.onChange = nil
        await finish(model)
        await run { await model.select(.permissionMode, value: "deep") }
        XCTAssertEqual(model.configuration, SessionConfiguration())
    }

    @MainActor func testUnsolicitedSnapshotAppliedAndWrongSessionIgnored() async {
        let model = await connected(.updates)
        // Notifications are not selection responses. The matching snapshot must survive
        // the following wrong-session empty snapshot, including while prompting.
        await run { await model.send("Deliver updates") }
        await waitUntil { model.transcript.contains("updates delivered") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        XCTAssertEqual(model.configuration.effort?.currentValue, "high")
        XCTAssertEqual(model.configuration.effort?.choices.map(\.value), ["high"])
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testLegacyModeSuccess() async {
        let model = await connected(.legacy)
        XCTAssertEqual(model.configuration.permissionMode?.route, .legacyMode)
        XCTAssertNil(model.configuration.effort)
        await run { await model.select(.permissionMode, value: "deep") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        XCTAssertEqual(model.configuration.permissionMode?.route, .legacyMode)
        XCTAssertNil(model.configuration.effort)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isChangingConfiguration)
        await finish(model)
    }

    @MainActor func testNewSessionReplyDoesNotLoseImmediatelyFollowingConfigurationUpdate() async {
        let model = await connected(.updateAfterNewSession)
        // The burst may be processed while connect is suspended. Its message sentinel
        // is not buffered, so fence the event stream again after connect returns.
        await run { await model.send("Fence initial notifications") }
        await waitUntil { model.transcript.contains("new-session updates drained") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        XCTAssertEqual(model.configuration.effort?.currentValue, "high")
        XCTAssertEqual(model.configuration.effort?.choices.map(\.value), ["high"])
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testNewerConfigNotificationWinsOverEarlierSelectionReply() async {
        await assertNewestConfigSnapshot(.updateAfterConfigReply)
    }

    @MainActor func testNewerCanonicalSelectionReplyWinsOverEarlierConfigNotification() async {
        await assertNewestConfigSnapshot(.updateBeforeConfigReply)
    }

    @MainActor private func assertNewestConfigSnapshot(_ variant: ModeConfigurationTestAgent.Variant) async {
        let model = await connected(variant)
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "fast")
        // Both wire orders end at fast+low, despite requesting deep. Do not treat
        // the requested value as confirmation or let a later resumer roll state back.
        await run { await model.select(.permissionMode, value: "deep") }
        await waitUntil { model.transcript.contains("config ordering delivered") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "fast")
        XCTAssertEqual(model.configuration.effort?.currentValue, "low")
        XCTAssertEqual(model.configuration.effort?.choices.map(\.value), ["low", "high"])
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testNewerLegacyModeNotificationWinsOverSelectionAcknowledgement() async {
        let model = await connected(.updateAfterLegacyReply)
        await run { await model.select(.permissionMode, value: "deep") }
        await waitUntil { model.transcript.contains("legacy ordering delivered") }
        XCTAssertEqual(model.configuration.permissionMode?.route, .legacyMode)
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "fast")
        XCTAssertEqual(model.configuration.permissionMode?.choices.map(\.value), ["fast", "deep"])
        XCTAssertNil(model.configuration.effort)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testEffortOnlySnapshotPreservesIndependentLegacyModePicker() async {
        let model = await connected(.mixedLegacyEffort)
        let legacyPicker = model.configuration.permissionMode
        XCTAssertEqual(legacyPicker?.route, .legacyMode)
        XCTAssertEqual(legacyPicker?.currentValue, "fast")
        XCTAssertEqual(legacyPicker?.choices.map(\.value), ["fast", "deep"])
        XCTAssertEqual(model.configuration.effort?.route, .config("effort"))
        XCTAssertEqual(model.configuration.effort?.currentValue, "low")
        await run { await model.select(.effort, value: "high") }
        XCTAssertEqual(model.configuration.permissionMode, legacyPicker)
        XCTAssertEqual(model.configuration.effort?.currentValue, "high")
        XCTAssertEqual(model.configuration.effort?.choices.map(\.value), ["low", "high"])
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertNil(model.errorMessage)
        // The preserved picker still routes to session/set_mode, not modern config.
        await run { await model.select(.permissionMode, value: "deep") }
        XCTAssertEqual(model.configuration.permissionMode?.route, .legacyMode)
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        XCTAssertEqual(model.configuration.effort?.currentValue, "high")
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testSelectionBlockedDuringPrompt() async {
        let model = await connected()
        let confirmed = model.configuration
        let returned = expectation(description: "Prompt cancelled")
        let prompt = Task { await model.send("Keep working"); returned.fulfill() }
        await waitUntil { model.transcript.contains("working") }
        XCTAssertEqual(model.phase, .prompting)
        await run { await model.select(.permissionMode, value: "deep") }
        await run { await model.select(.effort, value: "high") }
        XCTAssertEqual(model.configuration, confirmed)
        XCTAssertFalse(model.isChangingConfiguration)
        await run { await model.cancel() }
        await fulfillment(of: [returned], timeout: 5)
        prompt.cancel()
        await finish(model)
    }

    @MainActor func testDisconnectWhileChangingAndOldReplyDoesNotResurrect() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let model = await connected(.replyOnTermination(markerPath: marker.path))
        let confirmed = model.configuration
        let returned = expectation(description: "Interrupted selection returns")
        let selection = Task { await model.select(.permissionMode, value: "deep"); returned.fulfill() }
        await waitUntil { model.transcript.contains("selection waiting") }
        XCTAssertTrue(model.isChangingConfiguration)
        XCTAssertEqual(model.configuration, confirmed, "No optimistic selection")
        let transcript = model.transcript
        await run { await model.send("Must not be sent") }
        await run { await model.select(.effort, value: "high") }
        XCTAssertEqual(model.transcript, transcript)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.configuration, confirmed)
        XCTAssertTrue(model.isChangingConfiguration)
        await finish(model)
        await fulfillment(of: [returned], timeout: 5)
        selection.cancel()
        // The owned subprocess attempts its pending numeric-ID reply during teardown.
        // Whether transport drops it or SessionModel sees completion, neither may revive state.
        await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertEqual(model.configuration, SessionConfiguration())
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertNil(model.errorMessage)
        // Intentionally start a new context with initial configuration, not resume (see SessionResumeTests).
        await connect(model, variant: .modern, startNewSession: true)
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "fast")
        XCTAssertEqual(model.configuration.effort?.currentValue, "low")
        XCTAssertFalse(model.isChangingConfiguration)
        await finish(model)
    }

    @MainActor func testAgentExitClearsConfigurationAndPendingChange() async {
        let model = await connected(.exitOnSelection)
        await run { await model.select(.permissionMode, value: "deep") }
        await waitUntil { model.phase == .disconnected }
        XCTAssertEqual(model.configuration, SessionConfiguration())
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertNotNil(model.errorMessage)
        await finish(model)
    }

    @MainActor func testLegacyModeUpdateImmediatelyAfterNewSessionSurvivesOtherSnapshots() async {
        let model = await connected(.legacyUpdateAfterNewSession)
        let prompt = Task { await model.send("Fence initial notifications") }
        await waitUntil { model.transcript.contains("working") }
        XCTAssertEqual(model.configuration.permissionMode?.route, .legacyMode)
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        XCTAssertEqual(model.configuration.permissionMode?.choices.map(\.value), ["fast", "deep"])
        await run { await model.cancel() }
        await run { await prompt.value }
        await finish(model)
    }

    @MainActor func testModernModeErrorKeepsConfirmation() async {
        let model = await connected(.rejectModernMode)
        let confirmed = model.configuration
        await run { await model.select(.permissionMode, value: "deep") }
        XCTAssertEqual(model.configuration, confirmed)
        XCTAssertEqual(model.errorMessage, "Mode rejected")
        XCTAssertFalse(model.isChangingConfiguration)
        await finish(model)
    }

    @MainActor func testLegacyModeErrorKeepsConfirmationAndUnlocks() async {
        let model = await connected(.rejectLegacyMode)
        let confirmed = model.configuration
        await run { await model.select(.permissionMode, value: "deep") }
        XCTAssertEqual(model.configuration, confirmed)
        XCTAssertEqual(model.errorMessage, "Mode rejected")
        XCTAssertFalse(model.isChangingConfiguration)
        XCTAssertEqual(model.phase, .ready)
        await finish(model)
    }

    @MainActor func testLegacyModeAcknowledgementWinsOverEarlierNotification() async {
        let model = await connected(.updateBeforeLegacyReply)
        await run { await model.select(.permissionMode, value: "deep") }
        // Fence the event stream, including a notification whose task may resume after the reply.
        let prompt = Task { await model.send("Fence") }
        await waitUntil { model.transcript.contains("working") }
        XCTAssertEqual(model.configuration.permissionMode?.currentValue, "deep")
        await run { await model.cancel() }
        await run { await prompt.value }
        await finish(model)
    }

    @MainActor private func connected(
        _ variant: ModeConfigurationTestAgent.Variant = .modern
    ) async -> SessionModel {
        let model = SessionModel()
        await connect(model, variant: variant)
        return model
    }

    @MainActor private func connect(
        _ model: SessionModel, variant: ModeConfigurationTestAgent.Variant, startNewSession: Bool = false
    ) async {
        let script = ModeConfigurationTestAgent.script(variant: variant)
        let command = "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        await run {
            await model.connect(
                command: command, workspace: URL(fileURLWithPath: "/tmp"), startNewSession: startNewSession
            )
        }
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor private func finish(_ model: SessionModel) async {
        model.onChange = nil
        await run { await model.disconnect() }
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.configuration, SessionConfiguration())
        XCTAssertFalse(model.isChangingConfiguration)
    }

    /// Do not await an unbounded task value if a mock/protocol regression loses a reply.
    @MainActor private func run(_ operation: @escaping @MainActor () async -> Void) async {
        let returned = expectation(description: "Operation returns")
        let task = Task { await operation(); returned.fulfill() }
        await fulfillment(of: [returned], timeout: 5)
        task.cancel()
    }

    @MainActor private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for fixture event", file: file, line: line)
    }
}
