import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest
@testable import LatchAgentServer

final class RemoteRuntimeHubTests: XCTestCase {
    func testLaunchAttachPromptStreamsTheTurnInOrder() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("stream")
            let initialization = try await bed.launch(id)
            XCTAssertEqual(initialization.agentInfo?.name, "mock-agent")
            try await bed.ok(.newSession(runtimeID: id))

            let viewer = bed.viewer()
            let attached = try await viewer.attach(id)
            XCTAssertEqual(attached.record.agentTitle, "sh")
            XCTAssertEqual(attached.record.workspace, bed.workspace.path)
            XCTAssertEqual(attached.record.lifecycle, .ready)
            XCTAssertEqual(attached.record.sessionID, "session-1")
            XCTAssertEqual(attached.backlogFrom, 1)
            XCTAssertFalse(attached.truncated)

            let turnID = UUID()
            let accepted = try await bed.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [
                .text("hello"), .image(data: Data(repeating: 7, count: 12), mimeType: "image/png"),
            ]))
            XCTAssertEqual(accepted, .promptAccepted(turnID: turnID))

            let frames = try await viewer.pull(until: "the whole turn") { $0.turnEnded != nil && $0.chunkTexts.count == 3 }
            XCTAssertEqual(frames.map(\.sequence), Array(1...UInt64(frames.count)))
            XCTAssertTrue(frames.allSatisfy { $0.runtimeID == id && !$0.gap })
            XCTAssertEqual(frames.first?.event, .turnStarted(turnID: turnID, text: "hello", attachments: [
                LatchRemoteAttachmentSummary(kind: "image", mimeType: "image/png", byteCount: 12),
            ]))
            XCTAssertEqual(frames.chunkTexts, ["one", "two", "three"])
            XCTAssertEqual(frames.turnEnded?.event, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil))
            XCTAssertGreaterThan(viewer.wakes.value, 0)

            let record = try await bed.record(id)
            XCTAssertNil(record.activeTurnID)
            XCTAssertEqual(record.turns, [LatchRemoteTurnRecord(turnID: turnID, state: .ended, stopReason: "end_turn")])
            XCTAssertEqual(record.lastSequence, UInt64(frames.count))
        }
    }

    func testPulledLinesAreTheFramesEncodingWouldProduce() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("bytes")
            try await bed.launchWithSession(id)
            try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]))
            try await bed.waitForIdle(id, through: 5)
            let viewer = bed.viewer()
            try await viewer.attach(id)
            let lines = bed.hub.pullEventLines(for: viewer.connection, byteBudget: 1 << 20)
            XCTAssertEqual(lines.count, 5)
            for line in lines {
                let frame = try LatchRemoteCoding.decode(LatchRemoteServerFrame.self, fromLine: line.dropLast())
                XCTAssertEqual(try LatchRemoteCoding.encodeLine(frame), line)
            }
        }
    }

    func testPermissionRoundTripRejectsOptionsItDidNotOffer() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("permission")
            try await bed.launchWithSession(id)
            let viewer = bed.viewer()
            try await viewer.attach(id)
            let turnID = UUID()
            try await bed.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("permission please")]))

            let asked = try await viewer.pull(until: "a permission request") { frames in
                frames.contains { if case .permissionRequested = $0.event { true } else { false } }
            }
            // The registry may journal the request before the chunk that preceded it.
            guard case let .permissionRequested(requestID, request)? = asked.first(where: {
                if case .permissionRequested = $0.event { true } else { false }
            })?.event else { return XCTFail("Expected the permission request: \(asked)") }
            XCTAssertEqual(request.options.map(\.optionId), ["allow-once", "reject-once"])
            let pending = try await bed.summary(id)
            XCTAssertEqual(pending.pendingPermissionCount, 1)
            XCTAssertEqual(pending.activeTurnID, turnID)
            let recordWhilePending = try await bed.record(id)
            XCTAssertEqual(recordWhilePending.pendingPermissions, [LatchRemotePendingPermission(requestID: requestID, request: request)])

            let invalid = try await bed.failure(.resolvePermission(runtimeID: id, requestID: requestID, outcome: .selected(optionID: "bogus")))
            XCTAssertEqual(invalid.code, .invalidPermissionOption)
            let resolved = try await bed.ok(.resolvePermission(runtimeID: id, requestID: requestID, outcome: .selected(optionID: "allow-once")))
            XCTAssertEqual(resolved, .permissionResolved)

            let frames = try await viewer.pull(until: "the turn's end") { $0.turnEnded != nil && $0.chunkTexts.contains("allowed") }
            XCTAssertTrue(frames.contains { $0.event == .permissionClosed(requestID: requestID) })
            XCTAssertEqual(frames.turnEnded?.event, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil))
            let again = try await bed.failure(.resolvePermission(runtimeID: id, requestID: requestID, outcome: .cancelled))
            XCTAssertEqual(again.code, .permissionRequestNotFound)
            let record = try await bed.record(id)
            XCTAssertEqual(record.pendingPermissions, [])
        }
    }

    func testClosingAConnectionMidTurnLosesNothing() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("reconnect")
            try await bed.launchWithSession(id)
            let first = bed.viewer()
            try await first.attach(id)
            let turnID = UUID()
            try await bed.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("slow")]), from: first.connection)
            let seen = try await first.pull(until: "the turn's start") { !$0.isEmpty }
            let cursor = try XCTUnwrap(seen.last?.sequence)
            first.close()

            // Nobody is attached while the agent finishes.
            try await bed.waitForIdle(id, through: cursor + 4)
            XCTAssertEqual(first.frames.count, seen.count)

            let second = bed.viewer()
            let attached = try await second.attach(id, after: cursor)
            XCTAssertEqual(attached.backlogFrom, cursor + 1)
            XCTAssertFalse(attached.truncated)
            let missed = try await second.pull(until: "the missed events") { $0.turnEnded != nil && $0.chunkTexts.count == 3 }
            XCTAssertEqual(missed.map(\.sequence), Array((cursor + 1)...attached.record.lastSequence))
            XCTAssertTrue(missed.allSatisfy { !$0.gap })
            XCTAssertEqual(try second.pull(), [])

            // The client never saw `promptAccepted`, so it resends; the agent is not asked twice.
            let resent = try await bed.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("slow")]), from: second.connection)
            XCTAssertEqual(resent, .promptAccepted(turnID: turnID))
            XCTAssertEqual(bed.lines(in: "prompts.log"), 1)
            XCTAssertEqual(try second.pull(), [])
        }
    }

    func testResendingAPromptDoesNotRunItTwice() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("resend")
            try await bed.launchWithSession(id)
            let turnID = UUID()
            let prompt = LatchRemoteCommand.prompt(runtimeID: id, turnID: turnID, blocks: [.text("permission")])
            let (hub, control) = (bed.hub, bed.control)
            async let firstReply = hub.handle(prompt, from: control)
            async let secondReply = hub.handle(prompt, from: control)
            let replies = await [firstReply, secondReply]
            XCTAssertEqual(replies, [.success(.promptAccepted(turnID: turnID)), .success(.promptAccepted(turnID: turnID))])

            try await eventually("the permission request") { try await bed.summary(id).pendingPermissionCount == 1 }
            try await bed.ok(.cancelPrompt(runtimeID: id))
            try await bed.waitForIdle(id, through: 4)
            try await bed.expect(prompt, returns: .promptAccepted(turnID: turnID))
            XCTAssertEqual(bed.lines(in: "prompts.log"), 1)
            let record = try await bed.record(id)
            XCTAssertEqual(record.turns, [LatchRemoteTurnRecord(turnID: turnID, state: .ended, stopReason: "cancelled")])
        }
    }

    func testPromptNeedsASessionAndOneTurnAtATime() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("busy")
            try await bed.launch(id)
            let early = try await bed.failure(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("hi")]))
            XCTAssertEqual(early.code, .noSession)
            let missing = try await bed.failure(.prompt(runtimeID: AgentRuntimeID("missing"), turnID: UUID(), blocks: [.text("hi")]))
            XCTAssertEqual(missing.code, .runtimeNotFound)

            try await bed.ok(.newSession(runtimeID: id))
            let first = UUID()
            try await bed.ok(.prompt(runtimeID: id, turnID: first, blocks: [.text("permission")]))
            let second = UUID()
            let busy = try await bed.failure(.prompt(runtimeID: id, turnID: second, blocks: [.text("hi")]))
            XCTAssertEqual(busy.code, .busy)

            try await eventually("the permission request") { try await bed.summary(id).pendingPermissionCount == 1 }
            try await bed.expect(.cancelPrompt(runtimeID: id), returns: .cancelRequested)
            try await bed.waitForIdle(id, through: 4)
            try await bed.expect(.prompt(runtimeID: id, turnID: second, blocks: [.text("hi")]), returns: .promptAccepted(turnID: second))
            try await bed.waitForIdle(id, through: 9)
            XCTAssertEqual(bed.lines(in: "prompts.log"), 2)
        }
    }

    func testRetriedCommandsAreIdempotent() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("retry")
            // Concurrent launches of one runtime share one agent process.
            let (hub, control) = (bed.hub, bed.control)
            let launch = LatchRemoteCommand.launchAgent(runtimeID: id, agent: bed.mockAgent, workspace: bed.workspace.path)
            async let firstLaunch = hub.handle(launch, from: control)
            async let secondLaunch = hub.handle(launch, from: control)
            let launches = await [firstLaunch, secondLaunch]
            guard case let .success(.launched(initialization)) = launches[0] else { return XCTFail("\(launches)") }
            XCTAssertEqual(launches[1], launches[0])
            let relaunched = try await bed.launch(id)
            XCTAssertEqual(relaunched, initialization)
            let processes = try await bed.service.execute(.listRuntimes)
            XCTAssertEqual(processes, .runtimeList([AgentRuntimeSnapshot(id: id, state: .ready)]))

            let otherWorkspace = try await bed.failure(.launchAgent(runtimeID: id, agent: bed.mockAgent, workspace: "/"))
            XCTAssertEqual(otherWorkspace.code, .duplicateRuntime)
            let otherAgent = try await bed.failure(.launchAgent(runtimeID: id, agent: .preset("fx"), workspace: bed.workspace.path))
            XCTAssertEqual(otherAgent.code, .duplicateRuntime)

            let created = try await bed.ok(.newSession(runtimeID: id))
            try await bed.expect(.newSession(runtimeID: id), returns: created)
            XCTAssertEqual(bed.lines(in: "sessions.log"), 1)
            let load = try await bed.failure(.loadSession(runtimeID: id, sessionID: "session-1"))
            XCTAssertEqual(load.code, .sessionAlreadyBound)

            try await bed.expect(.cancelPrompt(runtimeID: id), returns: .cancelRequested)
            let unknownRequest = try await bed.failure(.resolvePermission(runtimeID: id, requestID: UUID(), outcome: .cancelled))
            XCTAssertEqual(unknownRequest.code, .permissionRequestNotFound)
            try await bed.expect(.detach(runtimeID: id), returns: .detached)
            try await bed.expect(.stopRuntime(runtimeID: AgentRuntimeID("never-launched")), returns: .stopped)
            try await bed.expect(.stopRuntime(runtimeID: id), returns: .stopped)
            try await bed.expect(.stopRuntime(runtimeID: id), returns: .stopped)
            let attachUnknown = try await bed.failure(.attach(runtimeID: AgentRuntimeID("never-launched"), after: 0))
            XCTAssertEqual(attachUnknown.code, .runtimeNotFound)
            let unsupported = try await bed.failure(.unknown(kind: "teleport"))
            XCTAssertEqual(unsupported.code, .unsupportedCommand)
        }
    }

    func testLoadSessionIsIdempotentAndDropsReplayedHistory() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("load")
            try await bed.launch(id)
            let loaded = try await bed.ok(.loadSession(runtimeID: id, sessionID: "saved-1"))
            guard case let .sessionLoaded(response) = loaded else { return XCTFail("\(loaded)") }
            let loadedThrough = try XCTUnwrap(response.localSequence)
            try await bed.expect(.loadSession(runtimeID: id, sessionID: "saved-1"), returns: loaded)
            XCTAssertEqual(bed.lines(in: "sessions.log"), 1)
            try await bed.expect(.loadSession(runtimeID: id, sessionID: "other"), fails: .sessionAlreadyBound)
            try await bed.expect(.newSession(runtimeID: id), fails: .sessionAlreadyBound)

            // History that arrives after the reply is dropped as well as what was journaled.
            try await Task.sleep(for: .milliseconds(300))
            let turnID = UUID()
            try await bed.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("go on")]))
            let viewer = bed.viewer()
            let attached = try await viewer.attach(id)
            XCTAssertFalse(attached.truncated)
            XCTAssertEqual(attached.record.sessionID, "saved-1")
            XCTAssertEqual(attached.record.session, .load(response))
            XCTAssertEqual(attached.record.loadedThrough, loadedThrough)
            let frames = try await viewer.pull(until: "the turn") { $0.turnEnded != nil && $0.chunkTexts.count == 3 }
            XCTAssertEqual(frames.chunkTexts, ["one", "two", "three"])
            XCTAssertFalse(frames.contains(where: \.gap))
            if case .turnStarted = frames.first?.event {} else { XCTFail("Expected the turn first, not history: \(frames)") }
            XCTAssertEqual(frames.first?.sequence, attached.backlogFrom)
        }
    }

    func testSetCommandsPublishWhatTheySet() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("configure")
            try await bed.launch(id)
            try await bed.expect(.setModel(runtimeID: id, modelID: "model-b"), fails: .noSession)
            try await bed.ok(.newSession(runtimeID: id))
            let viewer = bed.viewer()
            try await viewer.attach(id)

            let config = try await bed.ok(.setConfigOption(runtimeID: id, configID: "effort", value: "high"))
            guard case let .configOptionSet(configResponse) = config else { return XCTFail("\(config)") }
            let model = try await bed.ok(.setModel(runtimeID: id, modelID: "model-b"))
            guard case let .modelSet(modelSequence) = model else { return XCTFail("\(model)") }
            let mode = try await bed.ok(.setMode(runtimeID: id, modeID: "code"))
            guard case let .modeSet(modeSequence) = mode else { return XCTFail("\(mode)") }

            let expected = [
                LatchRemoteConfigurationSet(
                    route: .config, configID: "effort", value: "high",
                    acpSequence: configResponse.localSequence, configOptions: configResponse.configOptions
                ),
                LatchRemoteConfigurationSet(route: .mode, value: "code", acpSequence: modeSequence),
                LatchRemoteConfigurationSet(route: .model, value: "model-b", acpSequence: modelSequence),
            ]
            let frames = try await viewer.pull(until: "three sets and the mode update") { frames in
                frames.filter { if case .configurationSet = $0.event { true } else { false } }.count == 3
                    && frames.contains { if case .sessionUpdate = $0.event { true } else { false } }
            }
            let published = frames.compactMap { frame -> LatchRemoteConfigurationSet? in
                if case let .configurationSet(set) = frame.event { set } else { nil }
            }
            XCTAssertEqual(published.map(\.route), [.config, .model, .mode])
            XCTAssertEqual(Set(published.map(\.value)), ["high", "model-b", "code"])

            let record = try await bed.record(id)
            XCTAssertEqual(record.configurationSets, expected)
            XCTAssertEqual(record.state.count, 1)
            guard case let .object(update)? = record.state.first?.update else { return XCTFail("Expected the mode update") }
            XCTAssertEqual(update["currentModeId"], .string("code"))
        }
    }

    func testEvictionShowsAsAGap() async throws {
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.runtimeJournalBudget = 600
        try await withTestbed(configuration: configuration) { bed in
            let id = AgentRuntimeID("evict")
            try await bed.launchWithSession(id)
            let behind = bed.viewer()
            try await behind.attach(id)
            try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]))
            try await bed.waitForIdle(id, through: 5)

            let frames = try behind.pull()
            XCTAssertTrue(try XCTUnwrap(frames.first).gap)
            XCTAssertGreaterThan(try XCTUnwrap(frames.first).sequence, 1)
            XCTAssertTrue(frames.dropFirst().allSatisfy { !$0.gap })
            XCTAssertEqual(frames.last?.sequence, 5)

            let late = bed.viewer()
            let attached = try await late.attach(id)
            XCTAssertTrue(attached.truncated)
            XCTAssertEqual(attached.backlogFrom, frames.first?.sequence)
            let lateFrames = try late.pull()
            XCTAssertEqual(lateFrames.map(\.sequence), frames.map(\.sequence))
            // The reply reported the loss; the frames do not report it again.
            XCTAssertTrue(lateFrames.allSatisfy { !$0.gap })

            // A cursor already past the eviction sees no gap.
            let current = bed.viewer()
            let caughtUp = try await current.attach(id, after: 4)
            XCTAssertFalse(caughtUp.truncated)
            XCTAssertEqual(try current.pull().map(\.gap), [false])
        }
    }

    func testOversizeEventIsJournaledAsOmitted() async throws {
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.maxEncodedEventBytes = 2048
        try await withTestbed(configuration: configuration) { bed in
            let id = AgentRuntimeID("oversize")
            try await bed.launchWithSession(id)
            let viewer = bed.viewer()
            try await viewer.attach(id)
            try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("oversize")]))
            let frames = try await viewer.pull(until: "the omitted chunk") { frames in
                frames.turnEnded != nil && frames.contains { if case .omitted = $0.event { true } else { false } }
            }
            guard case let .omitted(originalKind, byteCount)? = frames.first(where: { if case .omitted = $0.event { true } else { false } })?.event else {
                return XCTFail("Expected an omitted event")
            }
            XCTAssertEqual(originalKind, "sessionUpdate")
            XCTAssertGreaterThan(byteCount, 4000)
            XCTAssertEqual(frames.map(\.sequence), Array(1...UInt64(frames.count)))
        }
    }

    func testCrashEndsTheTurnAndExitsLast() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("crash")
            try await bed.launchWithSession(id)
            let viewer = bed.viewer()
            try await viewer.attach(id)
            let turnID = UUID()
            try await bed.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("crash")]))
            let frames = try await viewer.pull(until: "the exit") { frames in
                frames.contains { if case .exited = $0.event { true } else { false } }
            }
            // Nothing follows `exited`, however late.
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(try viewer.pull(), [])

            // The registry closes the request as the process goes, so only `exited` has a fixed place.
            XCTAssertEqual(frames.last?.event, .exited(LatchRemoteExit(status: 3, stopped: false)))
            XCTAssertEqual(frames.filter { if case .exited = $0.event { true } else { false } }.count, 1)
            XCTAssertEqual(frames.filter(\.isTurnEnded).count, 1)
            XCTAssertEqual(frames.turnEnded?.event, .turnEnded(turnID: turnID, stopReason: nil, error: .runtimeExited))
            guard case let .permissionRequested(requestID, _)? = frames.first(where: {
                if case .permissionRequested = $0.event { true } else { false }
            })?.event else { return XCTFail("Expected the permission request: \(frames)") }
            XCTAssertTrue(frames.contains { $0.event == .permissionClosed(requestID: requestID) })
            XCTAssertEqual(frames.map(\.sequence), Array(1...UInt64(frames.count)))

            // The record and the whole journal stay attachable; the ID stays taken.
            let late = bed.viewer()
            let attached = try await late.attach(id)
            XCTAssertEqual(attached.record.lifecycle, .exited)
            XCTAssertEqual(attached.record.exit, LatchRemoteExit(status: 3, stopped: false))
            XCTAssertEqual(attached.record.turns.last?.error, .runtimeExited)
            XCTAssertEqual(attached.record.pendingPermissions, [])
            XCTAssertFalse(attached.truncated)
            XCTAssertEqual(try late.pull().map(\.event), frames.map(\.event))
            try await bed.expect(.launchAgent(runtimeID: id, agent: bed.mockAgent, workspace: bed.workspace.path), fails: .duplicateRuntime)
            try await bed.expect(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("hi")]), fails: .runtimeNotFound)
            try await bed.expect(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("crash")]), returns: .promptAccepted(turnID: turnID))
            try await bed.expect(id, lifecycle: .exited)
        }
    }

    func testStopEndsTheTurnAndKeepsOnlyItsClosingEvents() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("stop")
            try await bed.launchWithSession(id)
            let viewer = bed.viewer()
            try await viewer.attach(id)
            let turnID = UUID()
            try await bed.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("permission")]))
            let asked = try await viewer.pull(until: "the permission request") { frames in
                frames.contains { if case .permissionRequested = $0.event { true } else { false } }
            }
            guard case let .permissionRequested(requestID, _)? = asked.first(where: {
                if case .permissionRequested = $0.event { true } else { false }
            })?.event else { return XCTFail("\(asked)") }

            try await bed.expect(.stopRuntime(runtimeID: id), returns: .stopped)
            let frames = try await viewer.pull(until: "the exit") { frames in
                frames.contains { if case .exited = $0.event { true } else { false } }
            }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(try viewer.pull(), [])
            XCTAssertEqual(Array(frames.suffix(3).map(\.event)), [
                .turnEnded(turnID: turnID, stopReason: nil, error: .runtimeExited),
                .permissionClosed(requestID: requestID),
                .exited(LatchRemoteExit(status: nil, stopped: true)),
            ])
            let processes = try await bed.service.execute(.listRuntimes)
            XCTAssertEqual(processes, .runtimeList([]))

            let late = bed.viewer()
            let attached = try await late.attach(id)
            XCTAssertTrue(attached.truncated)
            XCTAssertEqual(attached.record.exit, LatchRemoteExit(status: nil, stopped: true))
            let lateFrames = try late.pull()
            XCTAssertEqual(lateFrames.map(\.event), Array(frames.suffix(3).map(\.event)))
            XCTAssertEqual(lateFrames.map(\.gap), [false, false, false])
            try await bed.expect(.launchAgent(runtimeID: id, agent: bed.mockAgent, workspace: bed.workspace.path), fails: .duplicateRuntime)
        }
    }

    func testOnlyTheMostRecentExitedRuntimesAreKept() async throws {
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.retainedExitedRuntimes = 2
        try await withTestbed(configuration: configuration) { bed in
            let ids = ["gone-1", "gone-2", "gone-3"].map(AgentRuntimeID.init)
            for id in ids {
                try await bed.launch(id)
                try await bed.ok(.stopRuntime(runtimeID: id))
            }
            let listed = try await bed.ok(.listRuntimes)
            XCTAssertEqual(listed, .runtimes(ids.dropFirst().map {
                LatchRemoteRuntimeSummary(runtimeID: $0, agentTitle: "sh", workspace: bed.workspace.path, lifecycle: .exited, lastSequence: 1)
            }))
            // The oldest ID is free again.
            try await bed.launch(ids[0])
        }
    }

    func testAttachedCursorWaitsForActivation() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("activate")
            try await bed.launchWithSession(id)
            let viewer = bed.viewer()
            let attached = try await viewer.attachInactive(id)
            XCTAssertEqual(attached.backlogFrom, 1)
            try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]))
            try await bed.waitForIdle(id, through: 5)

            // Events published between the reply and its activation wait in the journal.
            XCTAssertEqual(try viewer.pull(), [])
            XCTAssertEqual(viewer.wakes.value, 0)
            bed.hub.activateAttachment(of: id, for: viewer.connection)
            XCTAssertEqual(viewer.wakes.value, 1)
            XCTAssertEqual(try viewer.pull().map(\.sequence), [1, 2, 3, 4, 5])

            // Two attaches in flight need two activations.
            try await viewer.attachInactive(id)
            try await viewer.attachInactive(id)
            bed.hub.activateAttachment(of: id, for: viewer.connection)
            try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]))
            try await bed.waitForIdle(id, through: 10)
            XCTAssertEqual(try viewer.pull(), [])
            bed.hub.activateAttachment(of: id, for: viewer.connection)
            XCTAssertEqual(try viewer.pull().map(\.sequence), Array(1...10))
        }
    }

    func testPullHonorsTheByteBudgetAndRotatesAcrossRuntimes() async throws {
        try await withTestbed { bed in
            let first = AgentRuntimeID("first")
            let second = AgentRuntimeID("second")
            for id in [first, second] {
                try await bed.launchWithSession(id)
                try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]))
                try await bed.waitForIdle(id, through: 5)
            }
            let viewer = bed.viewer()
            try await viewer.attach(first)
            try await viewer.attach(second)
            // Too small for any frame: still one, so the writer always makes progress.
            XCTAssertEqual(try viewer.pull(byteBudget: 1).count, 1)
            let rest = try viewer.pull()
            XCTAssertEqual(rest.count, 9)
            XCTAssertEqual(Array(viewer.frames.prefix(4).map(\.runtimeID)), [first, second, first, second])
            for id in [first, second] {
                XCTAssertEqual(viewer.frames.filter { $0.runtimeID == id }.map(\.sequence), [1, 2, 3, 4, 5])
            }
        }
    }

    func testStoppingWaitsForAViewerThatIsBehind() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("behind")
            try await bed.launchWithSession(id)
            let viewer = bed.viewer()
            try await viewer.attach(id)
            try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]))
            try await bed.waitForIdle(id, through: 5)
            try await bed.expect(.stopRuntime(runtimeID: id), returns: .stopped)

            // Nothing it had yet to send was evicted by the stop.
            let frames = try viewer.pull()
            XCTAssertEqual(frames.map(\.sequence), [1, 2, 3, 4, 5, 6])
            XCTAssertTrue(frames.allSatisfy { !$0.gap })
            XCTAssertEqual(frames.last?.event, .exited(LatchRemoteExit(status: nil, stopped: true)))

            // Once it has, the rest go.
            let late = bed.viewer()
            let attached = try await late.attach(id)
            XCTAssertTrue(attached.truncated)
            XCTAssertEqual(attached.backlogFrom, 6)
            XCTAssertEqual(try late.pull().map(\.gap), [false])
        }
    }

    func testNothingFollowsExitedWhileTheAgentIsStillStreaming() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("flood")
            try await bed.launchWithSession(id)
            let viewer = bed.viewer()
            try await viewer.attach(id)
            try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("flood")]))
            try await viewer.pull(until: "the first chunk") { !$0.chunkTexts.isEmpty }
            try await bed.expect(.stopRuntime(runtimeID: id), returns: .stopped)
            try await Task.sleep(for: .milliseconds(300))
            let frames = try await viewer.pull(until: "the exit") { frames in
                frames.contains { if case .exited = $0.event { true } else { false } }
            }
            XCTAssertEqual(try viewer.pull(), [])
            XCTAssertEqual(frames.last?.event, .exited(LatchRemoteExit(status: nil, stopped: true)))
            XCTAssertEqual(frames.map(\.sequence), Array(1...UInt64(frames.count)))
        }
    }

    func testAnAgentThatExitsWhileStartingDoesNotStayReady() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("brief")
            // The launch may fail or succeed, depending on which side of the exit it lands.
            _ = await bed.send(.launchAgent(runtimeID: id, agent: bed.script("exit-after-initialize.sh"), workspace: bed.workspace.path))
            try await eventually("the runtime exited or gone") {
                guard case let .runtimes(summaries) = try await bed.ok(.listRuntimes) else { return false }
                return summaries.first { $0.runtimeID == id }.map { $0.lifecycle == .exited } ?? true
            }
        }
    }

    func testCancellingARequestNeverCancelsItsWork() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("cancelled")
            let (hub, control, workspace, agent) = (bed.hub, bed.control, bed.workspace.path, bed.mockAgent)
            let launch = Task { await hub.handle(.launchAgent(runtimeID: id, agent: agent, workspace: workspace), from: control) }
            launch.cancel()
            _ = await launch.value
            try await bed.launch(id)
            try await bed.expect(id, lifecycle: .ready)

            let session = Task { await hub.handle(.newSession(runtimeID: id), from: control) }
            session.cancel()
            _ = await session.value
            let created = try await bed.ok(.newSession(runtimeID: id))
            guard case .sessionCreated = created else { return XCTFail("\(created)") }
            XCTAssertEqual(bed.lines(in: "sessions.log"), 1)
        }
    }

    func testHistoryReplayedByALoadNeverReachesAnAttachedViewer() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("replay")
            try await bed.launch(id)
            let viewer = bed.viewer()
            try await viewer.attach(id)
            try await bed.ok(.loadSession(runtimeID: id, sessionID: "saved-1"))
            try await bed.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go on")]))
            let frames = try await viewer.pull(until: "the turn") { $0.turnEnded != nil && $0.chunkTexts.count == 3 }
            XCTAssertEqual(frames.chunkTexts, ["one", "two", "three"])
            if case .turnStarted = frames.first?.event {} else { XCTFail("Expected the turn first, not history: \(frames)") }
            XCTAssertEqual(frames.first?.sequence, 1)
        }
    }

    func testShutdownRefusesFurtherCommands() async throws {
        try await withTestbed { bed in
            let id = AgentRuntimeID("late")
            await bed.hub.shutdown()
            let error = try await bed.failure(.launchAgent(runtimeID: id, agent: bed.mockAgent, workspace: bed.workspace.path))
            XCTAssertEqual(error.code, .commandFailed)
            let processes = try await bed.service.execute(.listRuntimes)
            XCTAssertEqual(processes, .runtimeList([]))
        }
    }

    func testReaperStopsOnlyIdleRuntimesNobodyCameBackFor() async throws {
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.detachedTimeout = .seconds(60)
        configuration.reaperInterval = .seconds(3600)
        try await withTestbed(configuration: configuration) { bed in
            let idle = AgentRuntimeID("idle")
            let watched = AgentRuntimeID("watched")
            let working = AgentRuntimeID("working")
            let thinking = AgentRuntimeID("thinking")
            for id in [idle, watched, working, thinking] { try await bed.launchWithSession(id) }
            let viewer = bed.viewer()
            try await viewer.attach(watched)
            try await bed.ok(.prompt(runtimeID: working, turnID: UUID(), blocks: [.text("permission")]))
            try await eventually("the permission request") { try await bed.summary(working).pendingPermissionCount == 1 }

            await bed.hub.reapDetachedRuntimes(now: bed.clock.base + .seconds(59))
            for id in [idle, watched, working, thinking] { try await bed.expect(id, lifecycle: .ready) }

            // A turn that asks nothing is still work in progress.
            try await bed.ok(.prompt(runtimeID: thinking, turnID: UUID(), blocks: [.text("slow")]))
            await bed.hub.reapDetachedRuntimes(now: bed.clock.base + .seconds(61))
            try await bed.expect(thinking, lifecycle: .ready)
            // Forgotten, not kept as exited: a returning client resumes the session instead.
            try await bed.expect(.attach(runtimeID: idle, after: 3), fails: .runtimeNotFound)
            try await bed.expect(watched, lifecycle: .ready)
            try await bed.expect(working, lifecycle: .ready)
            let processes = try await bed.service.execute(.listRuntimes)
            XCTAssertEqual(processes, .runtimeList([
                AgentRuntimeSnapshot(id: thinking, state: .ready),
                AgentRuntimeSnapshot(id: watched, state: .ready),
                AgentRuntimeSnapshot(id: working, state: .ready),
            ]))
            try await bed.launch(idle)

            // The timeout runs from when the last connection left.
            bed.clock.set(.seconds(100))
            viewer.close()
            await bed.hub.reapDetachedRuntimes(now: bed.clock.base + .seconds(159))
            try await bed.expect(watched, lifecycle: .ready)
            await bed.hub.reapDetachedRuntimes(now: bed.clock.base + .seconds(161))
            try await bed.expect(.attach(runtimeID: watched, after: 0), fails: .runtimeNotFound)
            try await bed.expect(working, lifecycle: .ready)
        }
    }

    func testDisabledReaperStopsNothing() async throws {
        var configuration = RemoteRuntimeHubConfiguration()
        configuration.detachedTimeout = .zero
        try await withTestbed(configuration: configuration) { bed in
            let id = AgentRuntimeID("kept")
            try await bed.launch(id)
            await bed.hub.reapDetachedRuntimes(now: bed.clock.base + .seconds(365 * 24 * 60 * 60))
            try await bed.expect(id, lifecycle: .ready)
        }
    }

    func testStandardErrorGoesOnlyToTheLogCallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("latch-hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("noisy.sh")
        try ("echo secret-noise >&2\n" + MockAgent.script).write(to: script, atomically: true, encoding: .utf8)
        let logged = WakeCounter()
        let hub = RemoteRuntimeHub(service: LatchAgentService(), standardError: { id, data in
            if id.rawValue == "noisy", String(decoding: data, as: UTF8.self).contains("secret-noise") { logged.increment() }
        })
        await hub.start()
        let connection = hub.openConnection(wake: {})
        let launched = await hub.handle(.launchAgent(
            runtimeID: AgentRuntimeID("noisy"), agent: .custom("/bin/sh " + AgentCommand.quotedArgument(script.path)), workspace: directory.path
        ), from: connection)
        guard case .success(.launched) = launched else { return XCTFail("\(launched)") }
        try await eventually("the stderr line") { logged.value > 0 }
        _ = await hub.handle(.attach(runtimeID: AgentRuntimeID("noisy"), after: 0), from: connection)
        hub.activateAttachment(of: AgentRuntimeID("noisy"), for: connection)
        XCTAssertEqual(hub.pullEventLines(for: connection, byteBudget: 1 << 20), [])
        await hub.shutdown()
    }
}
