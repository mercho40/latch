import Foundation
import LatchACP
import XCTest
@testable import LatchMacUI

/// Real, billable harness test. Uses existing local auth without reading/copying it.
/// Run from Apps/LatchMac with LATCH_LIVE_CODEX=1 swift test --filter LiveCodexIntegrationTests.
/// No fixture, shell wrapper, project workspace, or raw protocol/transcript logging.
final class LiveCodexIntegrationTests: XCTestCase {
    private let command = "npx --yes @agentclientprotocol/codex-acp@1.7.0"
    private enum Failure: Error { case timedOut(String), invalidState(String) }

    @MainActor func testLiveCodexSessionLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["LATCH_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Opt in with LATCH_LIVE_CODEX=1; requires npx, local Codex auth and network; uses model quota")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatchLiveCodex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { removeWorkspace(workspace) } // Runs even if failure-disconnect times out.
        let model = SessionModel()
        do {
            try await exercise(model, workspace: workspace)
        } catch {
            model.onChange = nil
            model.onTranscriptChange = nil
            try await bounded("failure disconnect", seconds: 15) { await model.disconnect() }
            print("Live Codex: failure disconnect complete")
            throw error
        }
        model.onChange = nil
        model.onTranscriptChange = nil
        try await bounded("final disconnect", seconds: 15) { await model.disconnect() }
        try require(model.phase == .disconnected, "final disconnect")
        try FileManager.default.removeItem(at: workspace)
        try require(!FileManager.default.fileExists(atPath: workspace.path), "workspace removed")
        print("Live Codex: disconnected; temporary workspace removed")
    }

    /// Real permission round trip: the agent asks before writing, Latch approves once, the file appears.
    /// A second write is rejected and must not appear.
    @MainActor func testLiveCodexPermissionApprovalAndRejection() async throws {
        guard ProcessInfo.processInfo.environment["LATCH_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Opt in with LATCH_LIVE_CODEX=1; requires npx, local Codex auth and network; uses model quota")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatchLiveCodexPermission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { removeWorkspace(workspace) }
        let model = SessionModel()
        defer { model.onChange = nil }
        do {
            try await exercisePermissions(model, workspace: workspace)
        } catch {
            model.onChange = nil
            try await bounded("failure disconnect", seconds: 15) { await model.disconnect() }
            throw error
        }
        try await bounded("final disconnect", seconds: 15) { await model.disconnect() }
    }

    @MainActor private func exercisePermissions(_ model: SessionModel, workspace: URL) async throws {
        var decisions: [String] = []
        var nextDecision = "allow_once"
        model.onChange = {
            guard let permission = model.permissions.current else { return }
            let choice = permission.options.first { $0.kind == nextDecision }
            decisions.append(choice?.kind ?? "cancel")
            model.permissions.resolve(id: permission.id, optionID: choice?.optionId)
        }
        try await bounded("connect", seconds: 120) {
            await model.connect(command: self.command, workspace: workspace)
        }
        try ready(model)

        let approved = workspace.appendingPathComponent("approved.txt")
        try await bounded("approved write", seconds: 180) {
            await model.send("Create a file named approved.txt in the current directory containing exactly the word LATCH. Use a tool to write it. Do not read or modify anything else. Reply with DONE.")
        }
        try ready(model)
        try require(decisions.contains("allow_once"), "agent requested permission and Latch approved once")
        try require(FileManager.default.fileExists(atPath: approved.path), "approved file written")
        try require(model.messages.contains { $0.role == .tool }, "tool activity shown")
        print("Live Codex: permission approved; decisions=\(decisions)")

        nextDecision = "reject_once"
        decisions.removeAll()
        let rejected = workspace.appendingPathComponent("rejected.txt")
        try await bounded("rejected write", seconds: 180) {
            await model.send("Create a file named rejected.txt in the current directory containing the word NO. Use a tool to write it. If permission is denied, stop immediately and reply DENIED.")
        }
        try ready(model)
        try require(decisions.contains("reject_once"), "agent requested permission and Latch rejected once")
        try require(!FileManager.default.fileExists(atPath: rejected.path), "rejected file not written")
        try require(model.permissions.current == nil, "no pending permission after prompt")
        print("Live Codex: permission rejected; decisions=\(decisions)")
    }

    @MainActor private func exercise(_ model: SessionModel, workspace: URL) async throws {
        var deniedPermissions = 0
        var streamingUpdates = 0
        var lastAssistantText = ""
        model.onChange = {
            if let permission = model.permissions.current {
                deniedPermissions += 1
                let rejection = permission.options.first { $0.kind == "reject_once" }
                model.permissions.resolve(id: permission.id, optionID: rejection?.optionId)
            }
            let text = model.messages.filter { $0.role == .assistant }.map(\.text).joined()
            if model.phase == .prompting, !text.isEmpty, text != lastAssistantText {
                streamingUpdates += 1
            }
            lastAssistantText = text
        }
        model.onTranscriptChange = model.onChange
        try await bounded("connect", seconds: 120) {
            await model.connect(command: self.command, workspace: workspace)
        }
        try ready(model)
        try require(model.messages.isEmpty, "configuration precedes first prompt")
        for kind in [SessionPicker.Kind.model, .effort] {
            guard let picker = model.configuration[kind] else {
                throw Failure.invalidState("missing pre-prompt picker")
            }
            try require(picker.choices.contains { $0.value == picker.currentValue }, "offered current selection")
            guard let alternative = picker.choices.first(where: { $0.value != picker.currentValue }) else {
                throw Failure.invalidState("no alternative offered for configuration change")
            }
            try await bounded("change picker", seconds: 30) { await model.select(kind, value: alternative.value) }
            try ready(model)
            try require(model.configuration[kind]?.currentValue == alternative.value, "agent-confirmed selection")
            try require(model.configuration[kind]?.choices.contains { $0.value == picker.currentValue } == true,
                        "original selection still offered")
            try await bounded("restore picker", seconds: 30) { await model.select(kind, value: picker.currentValue) }
            try ready(model)
            try require(model.configuration[kind]?.currentValue == picker.currentValue, "restored selection")
        }
        print("Live Codex: pre-prompt model and effort changes confirmed and restored")
        try await bounded("tiny prompt", seconds: 90) {
            await model.send("Do not use tools, inspect files, or run commands. Reply with exactly LATCH_CODEX_OK and nothing else.")
        }
        try ready(model)
        try require(streamingUpdates > 0, "assistant text delivered while prompting")
        try require(model.messages.contains { $0.role == .assistant && $0.text.contains("LATCH_CODEX_OK") }, "tiny reply")
        try require(!model.messages.contains { $0.role == .tool } && deniedPermissions == 0, "no tools or permissions")
        print("Live Codex: tiny no-tools reply streamed (\(streamingUpdates) text updates)")

        // At most one additional short response. Cancel after actual output, not merely
        // after the local phase flips (which could race prompt transmission).
        let previousUpdates = streamingUpdates
        var returned = false
        let prompt = Task { @MainActor in
            await model.send("Do not use tools, inspect files, or run commands. Count from 1 to 200, one number per line, with no commentary.")
            returned = true
        }
        defer { prompt.cancel() }
        let deadline = ContinuousClock.now + .seconds(30)
        while !returned, streamingUpdates == previousUpdates, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !returned, model.phase == .prompting {
            try await bounded("cancel", seconds: 15) { await model.cancel() }
            try await wait("cancelled prompt completion", seconds: 30) { returned }
            try ready(model)
            try require(model.status == "Cancelled", "agent acknowledged cancellation")
            print("Live Codex: cancellation acknowledged")
        } else {
            try ready(model)
            print("Live Codex GAP: response completed before cancellation could be exercised")
        }
        try require(!model.messages.contains { $0.role == .tool } && deniedPermissions == 0, "no tools in cancellation prompt")
        try await bounded("disconnect", seconds: 15) { await model.disconnect() }
        try require(model.phase == .disconnected && model.configuration == SessionConfiguration(), "disconnect clears configuration")
        try require(model.permissions.current == nil && !model.cancellationRequested, "disconnect clears pending state")
        // Explicitly discard the saved agent context: an ordinary reconnect would resume it.
        try await bounded("reconnect", seconds: 120) {
            await model.connect(command: self.command, workspace: workspace, startNewSession: true)
        }
        try ready(model)
        try require(model.messages.isEmpty && model.configuration.model != nil && model.configuration.effort != nil,
                    "fresh reconnected session")
        print("Live Codex: disconnect/new-session reconnect produced fresh configuration and empty history")
    }

    // Poll owned unstructured tasks so a lost RPC cannot trap a task-group scope.
    // The caller disconnects the production runtime on failure to release pending RPCs.
    @MainActor private func bounded(_ name: String, seconds: Int,
                                    _ operation: @escaping @MainActor () async -> Void) async throws {
        var returned = false
        let task = Task { @MainActor in await operation(); returned = true }
        defer { task.cancel() }
        try await wait(name, seconds: seconds) { returned }
    }

    @MainActor private func wait(_ name: String, seconds: Int, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else { throw Failure.timedOut(name) }
    }

    @MainActor private func ready(_ model: SessionModel) throws {
        // Do not include potentially sensitive agent errors in XCTest failure output.
        try require(model.errorMessage == nil, "agent reported an error (details intentionally suppressed)")
        try require(model.phase == .ready && !model.isChangingConfiguration, "session ready and unlocked")
    }

    private func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.invalidState(label) }
    }

    /// Best-effort cleanup of the temporary workspace; safe to call after a successful removal.
    private func removeWorkspace(_ workspace: URL) {
        guard FileManager.default.fileExists(atPath: workspace.path) else { return }
        try? FileManager.default.removeItem(at: workspace)
    }
}
