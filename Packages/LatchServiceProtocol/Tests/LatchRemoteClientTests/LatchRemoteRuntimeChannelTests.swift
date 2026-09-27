#if canImport(Network)
import Foundation
import LatchACP
@testable import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest

final class LatchRemoteRuntimeChannelTests: XCTestCase {
    private var server: FakeServer!
    private var channel: LatchRemoteRuntimeChannel!
    private var observer: ChannelObserver!

    override func setUp() async throws {
        server = try await FakeServer.start()
        channel = LatchRemoteRuntimeChannel(options: server.channelOptions())
        observer = ChannelObserver(channel)
    }

    override func tearDown() async throws {
        channel.close()
        server.stop()
    }

    /// Attaches from `after` on a fresh connection and returns that connection.
    private func attached(after: UInt64 = 0, record: LatchRemoteRuntimeRecord? = nil) async throws -> FakeConnection {
        let channel = channel!
        let record = record ?? Fixture.record(lastSequence: after)
        async let attachment = withTimeout { try await channel.attach(after: after) }
        let peer = try await server.nextConnection()
        try await peer.acceptAttach(after: after, record: record)
        let result = try await attachment
        XCTAssertEqual(result, LatchRemoteAttachment(record: record, backlogFrom: after + 1, truncated: false))
        return peer
    }

    private func waitUntilReconnecting() async throws {
        _ = try await observer.waitForLink { if case .reconnecting = $0 { true } else { false } }
    }

    func testReconnectingMidTurnReattachesFromTheCursorAndCompletesThePrompt() async throws {
        let channel = channel!
        let turnID = UUID()
        let requestID = UUID()

        async let initialization = withTimeout {
            try await channel.launch(agent: .preset("claudeCode"), workspace: "/home/me/project")
        }
        let first = try await server.nextConnection()
        try await first.acceptHello()
        let launch = try await first.nextRequest()
        XCTAssertEqual(launch.command, .launchAgent(runtimeID: Fixture.runtimeID, agent: .preset("claudeCode"), workspace: "/home/me/project"))
        first.reply(launch.id, .launched(initialization: Fixture.initialization))
        let attach = try await first.nextRequest()
        XCTAssertEqual(attach.command, .attach(runtimeID: Fixture.runtimeID, after: 0))
        first.reply(attach.id, .attached(record: Fixture.record(), backlogFrom: 1, truncated: false))
        let launched = try await initialization
        XCTAssertEqual(launched, Fixture.initialization)

        async let outcome = withTimeout(10) { try await channel.prompt(turnID: turnID, blocks: [.text("hello")]) }
        let prompt = try await first.nextRequest()
        XCTAssertEqual(prompt.command, .prompt(runtimeID: Fixture.runtimeID, turnID: turnID, blocks: [.text("hello")]))
        first.reply(prompt.id, .promptAccepted(turnID: turnID))
        first.event(1, .turnStarted(turnID: turnID, text: "hello", attachments: []))
        first.event(2, .permissionClosed(requestID: requestID))
        assertEqual(try await observer.nextEvent(), .event(sequence: 1, .turnStarted(turnID: turnID, text: "hello", attachments: [])))
        assertEqual(try await observer.nextEvent(), .event(sequence: 2, .permissionClosed(requestID: requestID)))

        first.drop()
        try await waitUntilReconnecting()
        let second = try await server.nextConnection()
        let record = Fixture.record(activeTurnID: turnID, turns: [LatchRemoteTurnRecord(turnID: turnID, state: .running)], lastSequence: 2)
        try await second.acceptAttach(after: 2, record: record)
        second.event(2, .permissionClosed(requestID: requestID)) // Already delivered.
        second.event(3, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil))

        let result = try await outcome
        XCTAssertEqual(result, LatchRemoteTurnOutcome(turnID: turnID, stopReason: "end_turn", error: nil))
        assertEqual(try await observer.events.next(), .reattached(LatchRemoteAttachment(record: record, backlogFrom: 3, truncated: false)))
        assertEqual(try await observer.events.next(), .event(sequence: 3, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil)))
        _ = try await observer.waitForLink { $0 == .connected }
        XCTAssertEqual(channel.lastDeliveredSequence, 3)
        // The prompt was accepted before the drop, so it is not sent again.
        try await second.expectSilence(for: 0.3)
    }

    func testAPromptLostWithTheConnectionIsSentAgainWithTheSameTurnID() async throws {
        let channel = channel!
        let turnID = UUID()
        let first = try await attached()

        async let outcome = withTimeout(10) { try await channel.prompt(turnID: turnID, blocks: [.text("again")]) }
        let lost = try await first.nextRequest()
        first.drop()

        let second = try await server.nextConnection()
        try await second.acceptAttach(after: 0)
        let resent = try await second.nextRequest()
        XCTAssertEqual(resent.command, lost.command)
        XCTAssertEqual(resent.command, .prompt(runtimeID: Fixture.runtimeID, turnID: turnID, blocks: [.text("again")]))
        second.reply(resent.id, .promptAccepted(turnID: turnID))
        let failure = LatchRemoteError(code: .commandFailed, message: "The agent failed.")
        second.event(1, .turnStarted(turnID: turnID, text: "again", attachments: []))
        second.event(2, .turnEnded(turnID: turnID, stopReason: nil, error: failure))

        let result = try await outcome
        XCTAssertEqual(result, LatchRemoteTurnOutcome(turnID: turnID, stopReason: nil, error: failure))
    }

    func testAnyCommandLostWithTheConnectionIsSentAgain() async throws {
        let channel = channel!
        async let response = withTimeout { try await channel.send(.setMode(runtimeID: Fixture.runtimeID, modeID: "code")) }
        let first = try await server.nextConnection()
        try await first.acceptHello()
        assertEqual(try await first.nextRequest().command, .setMode(runtimeID: Fixture.runtimeID, modeID: "code"))
        first.drop()

        // Not attached, so the command goes straight out on the new connection.
        let second = try await server.nextConnection()
        try await second.acceptHello()
        let resent = try await second.nextRequest()
        XCTAssertEqual(resent.command, .setMode(runtimeID: Fixture.runtimeID, modeID: "code"))
        second.reply(resent.id, .modeSet(sequence: 4))
        let result = try await response
        XCTAssertEqual(result, .modeSet(sequence: 4))
    }

    func testRuntimeNotFoundOnReattachIsPermanent() async throws {
        let channel = channel!
        let first = try await attached(after: 5)
        first.drop()
        try await waitUntilReconnecting()

        async let pending = withTimeout { try await channel.send(.setModel(runtimeID: Fixture.runtimeID, modelID: "m")) }
        let second = try await server.nextConnection()
        try await second.acceptHello()
        let reattach = try await second.nextRequest()
        XCTAssertEqual(reattach.command, .attach(runtimeID: Fixture.runtimeID, after: 5))
        second.reply(reattach.id, failure: .runtimeNotFound)

        let expected = LatchRemoteClientError.runtimeNotFound(message: "Fake runtimeNotFound")
        do {
            _ = try await pending
            XCTFail("Expected runtimeNotFound")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, expected)
        }
        _ = try await observer.waitForLink { $0 == .failed(expected) }
        XCTAssertEqual(channel.linkState, .failed(expected))
        do {
            _ = try await observer.events.next()
            XCTFail("The event stream should finish")
        } catch is InboxFinished {
        }
        do {
            _ = try await channel.send(.listRuntimes)
            XCTFail("Expected the permanent failure")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, expected)
        }
        try await second.waitForClose()
        try await server.connections.expectNothing(for: 0.4)
    }

    func testAnExplicitAttachToAMissingRuntimeOnlyFailsThatCall() async throws {
        let channel = channel!
        async let attachment = withTimeout { try await channel.attach(after: 3) }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        peer.reply(try await peer.nextRequest().id, failure: .runtimeNotFound)
        do {
            _ = try await attachment
            XCTFail("Expected runtimeNotFound")
        } catch {
            XCTAssertEqual((error as? LatchRemoteError)?.code, .runtimeNotFound)
        }
        XCTAssertEqual(channel.linkState, .connected)
    }

    func testEventsAreDeliveredOnceInOrderAndGapsAreReported() async throws {
        let peer = try await attached()
        let events: [LatchRemoteEvent] = (0..<7).map { _ in .permissionClosed(requestID: UUID()) }
        peer.event(1, events[1])
        peer.event(2, events[2])
        peer.event(2, events[3])
        peer.event(1, events[4])
        peer.event(6, events[5], runtimeID: AgentRuntimeID("someone-else"))
        peer.event(5, events[5], gap: true)
        peer.event(6, events[6])

        assertEqual(try await observer.nextEvent(), .event(sequence: 1, events[1]))
        assertEqual(try await observer.nextEvent(), .event(sequence: 2, events[2]))
        assertEqual(try await observer.nextEvent(), .gap)
        assertEqual(try await observer.nextEvent(), .event(sequence: 5, events[5]))
        assertEqual(try await observer.nextEvent(), .event(sequence: 6, events[6]))
        try await observer.events.expectNothing(for: 0.2)
        XCTAssertEqual(channel.lastDeliveredSequence, 6)
    }

    func testATruncatedReattachReportsAGapAndEndsTurnsFromTheRecord() async throws {
        let channel = channel!
        let turnID = UUID()
        let first = try await attached(after: 4, record: Fixture.record(activeTurnID: turnID, lastSequence: 4))
        async let outcome = withTimeout { try await channel.awaitTurn(turnID) }
        try await Task.sleep(for: .milliseconds(50))
        first.drop()

        let second = try await server.nextConnection()
        let ended = LatchRemoteTurnRecord(turnID: turnID, state: .ended, stopReason: "cancelled")
        let record = Fixture.record(turns: [ended], lastSequence: 81)
        try await second.acceptAttach(after: 4, record: record, truncated: true)
        // As the server's journal does, the first frame after the eviction carries the gap.
        second.event(80, .permissionClosed(requestID: turnID), gap: true)
        let later = UUID()
        second.event(81, .permissionClosed(requestID: later))

        let result = try await outcome
        XCTAssertEqual(result, LatchRemoteTurnOutcome(turnID: turnID, stopReason: "cancelled", error: nil))
        assertEqual(try await observer.events.next(), .reattached(LatchRemoteAttachment(record: record, backlogFrom: 5, truncated: true)))
        assertEqual(try await observer.events.next(), .gap)
        assertEqual(try await observer.events.next(), .event(sequence: 80, .permissionClosed(requestID: turnID)))
        assertEqual(try await observer.events.next(), .event(sequence: 81, .permissionClosed(requestID: later)))
        // One gap, not one from the attachment and another from the frame.
        try await observer.events.expectNothing(for: 0.2)
    }

    func testATurnEndedInTheBacklogResolvesOnlyAfterItsEvents() async throws {
        let channel = channel!
        let turnID = UUID()
        let first = try await attached()
        async let outcome = withTimeout(10) {
            let outcome = try await channel.prompt(turnID: turnID, blocks: [.text("hi")])
            return (outcome, channel.lastDeliveredSequence)
        }
        let prompt = try await first.nextRequest()
        first.reply(prompt.id, .promptAccepted(turnID: turnID))
        first.event(1, .turnStarted(turnID: turnID, text: "hi", attachments: []))
        assertEqual(try await observer.nextEvent(), .event(sequence: 1, .turnStarted(turnID: turnID, text: "hi", attachments: [])))
        first.drop()

        // The turn streamed and ended while the link was down; the record already says so.
        let second = try await server.nextConnection()
        let ended = LatchRemoteTurnRecord(turnID: turnID, state: .ended, stopReason: "end_turn")
        try await second.acceptAttach(after: 1, record: Fixture.record(turns: [ended], lastSequence: 3))
        try await Task.sleep(for: .milliseconds(200))
        let permission = UUID()
        second.event(2, .permissionClosed(requestID: permission))
        assertEqual(try await observer.nextEvent(), .event(sequence: 2, .permissionClosed(requestID: permission)))
        try await Task.sleep(for: .milliseconds(100))
        second.event(3, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil))

        let (result, deliveredWhenReturned) = try await outcome
        XCTAssertEqual(result, LatchRemoteTurnOutcome(turnID: turnID, stopReason: "end_turn", error: nil))
        // The turn's events, its end included, were delivered before prompt() returned.
        XCTAssertEqual(deliveredWhenReturned, 3)
    }

    func testARecordShowingAnExitEndsTurnsItDoesNotList() async throws {
        let channel = channel!
        let turnID = UUID()
        let first = try await attached(after: 2, record: Fixture.record(activeTurnID: turnID, lastSequence: 2))
        async let outcome = withTimeout { try await channel.awaitTurn(turnID) }
        try await Task.sleep(for: .milliseconds(50))
        first.drop()

        let second = try await server.nextConnection()
        var record = Fixture.record(lastSequence: 2)
        record.lifecycle = .exited
        try await second.acceptAttach(after: 2, record: record)
        let result = try await outcome
        XCTAssertEqual(result.error?.code, .runtimeExited)
    }

    func testAnExitEndsTurnsStillBeingAwaited() async throws {
        let channel = channel!
        let turnID = UUID()
        let peer = try await attached(record: Fixture.record(activeTurnID: turnID))
        async let outcome = withTimeout { try await channel.awaitTurn(turnID) }
        try await Task.sleep(for: .milliseconds(50))
        peer.event(1, .exited(LatchRemoteExit(status: 1, stopped: false)))

        let result = try await outcome
        XCTAssertEqual(result.error?.code, .runtimeExited)
        let later = try await withTimeout { try await channel.awaitTurn(UUID()) }
        XCTAssertEqual(later.error?.code, .runtimeExited)
    }

    func testFollowingATurnNeedsAnAttachment() async throws {
        do {
            _ = try await channel.awaitTurn(UUID())
            XCTFail("Expected notAttached")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .notAttached)
        }
        do {
            _ = try await channel.prompt(turnID: UUID(), blocks: [.text("x")])
            XCTFail("Expected notAttached")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .notAttached)
        }
    }

    func testUnauthorizedIsPermanentAndNeverRetried() async throws {
        let channel = channel!
        async let pending = withTimeout { try await channel.send(.listRuntimes) }
        let peer = try await server.nextConnection()
        _ = try await peer.nextFrame()
        peer.send(.rejected(LatchRemoteRejected(reason: .unauthorized, message: "Bad token")))

        do {
            _ = try await pending
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .unauthorized(message: "Bad token"))
        }
        _ = try await observer.waitForLink { $0 == .failed(.unauthorized(message: "Bad token")) }
        try await server.connections.expectNothing(for: 0.5)
    }

    func testABusyServerIsRetried() async throws {
        let channel = channel!
        async let pending = withTimeout { try await channel.send(.listRuntimes) }
        let first = try await server.nextConnection()
        _ = try await first.nextFrame()
        first.send(.rejected(LatchRemoteRejected(reason: .busy, message: "Too many connections")))

        let second = try await server.nextConnection()
        try await second.acceptHello()
        second.reply(try await second.nextRequest().id, .runtimes([]))
        let result = try await pending
        XCTAssertEqual(result, .runtimes([]))
    }

    func testRetriedCommandsTreatWorkAlreadyDoneAsSuccess() async throws {
        let channel = channel!
        async let resolved = withTimeout {
            try await channel.send(.resolvePermission(runtimeID: Fixture.runtimeID, requestID: UUID(), outcome: .cancelled))
        }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        peer.reply(try await peer.nextRequest().id, failure: .permissionRequestNotFound)
        let resolvedResponse = try await resolved
        XCTAssertEqual(resolvedResponse, .permissionResolved)

        async let stopped = withTimeout { try await channel.send(.stopRuntime(runtimeID: Fixture.runtimeID)) }
        peer.reply(try await peer.nextRequest().id, failure: .runtimeNotFound)
        let stoppedResponse = try await stopped
        XCTAssertEqual(stoppedResponse, .stopped)

        async let other = withTimeout { try await channel.send(.newSession(runtimeID: Fixture.runtimeID)) }
        peer.reply(try await peer.nextRequest().id, failure: .runtimeNotFound)
        do {
            _ = try await other
            XCTFail("Expected runtimeNotFound")
        } catch {
            XCTAssertEqual((error as? LatchRemoteError)?.code, .runtimeNotFound)
        }
    }

    func testAStoppedRuntimeIsNotReattached() async throws {
        let channel = channel!
        let first = try await attached()
        async let stopped = withTimeout { try await channel.send(.stopRuntime(runtimeID: Fixture.runtimeID)) }
        first.reply(try await first.nextRequest().id, failure: .runtimeNotFound)
        let stoppedResponse = try await stopped
        XCTAssertEqual(stoppedResponse, .stopped)

        first.drop()
        async let pending = withTimeout { try await channel.send(.listRuntimes) }
        let second = try await server.nextConnection()
        try await second.acceptHello()
        let next = try await second.nextRequest()
        XCTAssertEqual(next.command, .listRuntimes)
        second.reply(next.id, .runtimes([]))
        _ = try await pending
    }

    func testAProbeThatGoesUnansweredReconnectsAtOnce() async throws {
        let channel = channel!
        let first = try await attached(after: 2)
        let probe = Task { await channel.probe() }
        assertEqual(try await first.nextFrame(), .ping)
        await probe.value

        let second = try await server.nextConnection(timeout: 1)
        try await second.acceptAttach(after: 2)
        _ = try await observer.waitForLink { $0 == .connected }
    }

    func testCloseFailsEverythingPendingAndFinishesTheStreams() async throws {
        let channel = channel!
        let turnID = UUID()
        let peer = try await attached()
        async let prompt = withTimeout { try await channel.prompt(turnID: turnID, blocks: [.text("x")]) }
        let request = try await peer.nextRequest()
        peer.reply(request.id, .promptAccepted(turnID: turnID))
        try await Task.sleep(for: .milliseconds(50))

        channel.close()
        channel.close()
        do {
            _ = try await prompt
            XCTFail("Expected closed")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .closed)
        }
        _ = try await observer.waitForLink { $0 == .failed(.closed) }
        do {
            _ = try await observer.links.next()
            XCTFail("The link stream should finish")
        } catch is InboxFinished {
        }
        try await peer.waitForClose()
    }

    func testDetachIsSentOnceAndStopsReattaching() async throws {
        let channel = channel!
        let first = try await attached()
        async let detached: Void = withTimeout { await channel.detach() }
        let request = try await first.nextRequest()
        XCTAssertEqual(request.command, .detach(runtimeID: Fixture.runtimeID))
        first.reply(request.id, .detached)
        try await detached

        first.drop()
        async let pending = withTimeout { try await channel.send(.listRuntimes) }
        let second = try await server.nextConnection()
        try await second.acceptHello()
        let next = try await second.nextRequest()
        XCTAssertEqual(next.command, .listRuntimes)
        second.reply(next.id, .runtimes([]))
        _ = try await pending
    }

    func testLaunchingAfterAFailedAttachStartsFromTheFirstEvent() async throws {
        let channel = channel!
        let turnID = UUID()
        async let attachment = withTimeout { try await channel.attach(after: 57) }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        let attach = try await peer.nextRequest()
        XCTAssertEqual(attach.command, .attach(runtimeID: Fixture.runtimeID, after: 57))
        peer.reply(attach.id, failure: .runtimeNotFound)
        do {
            _ = try await attachment
            XCTFail("Expected runtimeNotFound")
        } catch {}
        XCTAssertEqual(channel.lastDeliveredSequence, 0)

        async let initialization = withTimeout { try await channel.launch(agent: .preset("claudeCode"), workspace: "/home/me/project") }
        let launch = try await peer.nextRequest()
        peer.reply(launch.id, .launched(initialization: Fixture.initialization))
        let relaunchAttach = try await peer.nextRequest()
        XCTAssertEqual(relaunchAttach.command, .attach(runtimeID: Fixture.runtimeID, after: 0))
        peer.reply(relaunchAttach.id, .attached(record: Fixture.record(), backlogFrom: 1, truncated: false))
        _ = try await initialization

        async let outcome = withTimeout { try await channel.prompt(turnID: turnID, blocks: [.text("x")]) }
        let prompt = try await peer.nextRequest()
        peer.reply(prompt.id, .promptAccepted(turnID: turnID))
        peer.event(1, .turnStarted(turnID: turnID, text: "x", attachments: []))
        peer.event(2, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil))
        let result = try await outcome
        XCTAssertEqual(result.stopReason, "end_turn")
        assertEqual(try await observer.nextEvent(), .event(sequence: 1, .turnStarted(turnID: turnID, text: "x", attachments: [])))
        XCTAssertEqual(channel.lastDeliveredSequence, 2)
    }

    func testATurnThatEndsBeforeItsResentPromptIsAcceptedStillCompletes() async throws {
        let channel = channel!
        let turnID = UUID()
        let first = try await attached()
        async let outcome = withTimeout(10) { try await channel.prompt(turnID: turnID, blocks: [.text("again")]) }
        _ = try await first.nextRequest()
        first.drop()

        let second = try await server.nextConnection()
        try await second.acceptAttach(after: 0)
        let resent = try await second.nextRequest()
        // The server's writer can put the backlog ahead of the reply.
        second.event(1, .turnStarted(turnID: turnID, text: "again", attachments: []))
        second.event(2, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil))
        assertEqual(try await observer.nextEvent(), .event(sequence: 1, .turnStarted(turnID: turnID, text: "again", attachments: [])))
        assertEqual(try await observer.nextEvent(), .event(sequence: 2, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil)))
        try await Task.sleep(for: .milliseconds(100))
        second.reply(resent.id, .promptAccepted(turnID: turnID))

        let result = try await outcome
        XCTAssertEqual(result, LatchRemoteTurnOutcome(turnID: turnID, stopReason: "end_turn", error: nil))
    }

    func testCommandsWaitForTheReattachReply() async throws {
        let channel = channel!
        let first = try await attached(after: 3)
        first.drop()
        try await waitUntilReconnecting()
        async let response = withTimeout { try await channel.send(.setMode(runtimeID: Fixture.runtimeID, modeID: "plan")) }

        let second = try await server.nextConnection()
        try await second.acceptHello()
        let reattach = try await second.nextRequest()
        XCTAssertEqual(reattach.command, .attach(runtimeID: Fixture.runtimeID, after: 3))
        try await second.expectSilence(for: 0.3)
        guard case .reconnecting = channel.linkState else { return XCTFail("\(channel.linkState)") }

        second.reply(reattach.id, .attached(record: Fixture.record(lastSequence: 3), backlogFrom: 4, truncated: false))
        let command = try await second.nextRequest()
        XCTAssertEqual(command.command, .setMode(runtimeID: Fixture.runtimeID, modeID: "plan"))
        XCTAssertEqual(channel.linkState, .connected)
        second.reply(command.id, .modeSet(sequence: 4))
        _ = try await response
    }

    func testOnlyACompletedHandshakeCountsAsConnected() async throws {
        let channel = channel!
        channel.start()
        let peer = try await server.nextConnection()
        XCTAssertFalse(channel.hasConnected)
        _ = try await peer.acceptHello()
        _ = try await observer.waitForLink { $0 == .connected }
        XCTAssertTrue(channel.hasConnected)
        channel.close()
        XCTAssertTrue(channel.hasConnected, "Closing does not forget what may have been sent")
    }

    func testAProbeReconnectsWithoutWaitingOutTheBackoff() async throws {
        var options = server.channelOptions()
        options.backoff = LatchRemoteBackoff(initial: .seconds(10), maximum: .seconds(30))
        let channel = LatchRemoteRuntimeChannel(options: options)
        defer { channel.close() }
        async let attachment = withTimeout { try await channel.attach(after: 0) }
        let first = try await server.nextConnection()
        try await first.acceptAttach(after: 0)
        _ = try await attachment

        await channel.probe()
        let second = try await server.nextConnection(timeout: 1)
        try await second.acceptAttach(after: 0)
    }

    func testBackoffGrowsWhileReattachFailsAndResetsOnceConnected() async throws {
        var options = server.channelOptions()
        options.backoff = LatchRemoteBackoff(initial: .milliseconds(200), maximum: .seconds(30))
        let channel = LatchRemoteRuntimeChannel(options: options)
        defer { channel.close() }
        async let attachment = withTimeout { try await channel.attach(after: 0) }
        var peer = try await server.nextConnection()
        try await peer.acceptAttach(after: 0)
        _ = try await attachment

        // Each connection completes the handshake, then the re-attach fails.
        peer.drop()
        var arrivals: [ContinuousClock.Instant] = []
        for _ in 0..<2 {
            peer = try await server.nextConnection()
            arrivals.append(.now)
            try await peer.acceptHello()
            peer.reply(try await peer.nextRequest().id, failure: .commandFailed)
        }
        peer = try await server.nextConnection()
        arrivals.append(.now)
        try await peer.acceptAttach(after: 0)
        // 200 ms, then 400 and 800: a handshake alone does not reset the backoff.
        XCTAssertGreaterThanOrEqual(arrivals[1] - arrivals[0], .milliseconds(350))
        XCTAssertGreaterThanOrEqual(arrivals[2] - arrivals[1], .milliseconds(700))

        try await Task.sleep(for: .milliseconds(100))
        peer.drop()
        let dropped = ContinuousClock.now
        try await server.nextConnection().acceptAttach(after: 0)
        XCTAssertLessThan(ContinuousClock.now - dropped, .milliseconds(600))
    }

    func testDetachingWhileAnAttachIsPendingFailsItAndStopsFollowing() async throws {
        let channel = channel!
        let turnID = UUID()
        let first = try await attached(record: Fixture.record(activeTurnID: turnID))
        async let turn = withTimeout { try await channel.awaitTurn(turnID) }
        try await Task.sleep(for: .milliseconds(50))
        first.drop()
        try await waitUntilReconnecting()
        async let attachment = withTimeout { try await channel.attach(after: 0) }
        try await Task.sleep(for: .milliseconds(20))

        await channel.detach()
        do {
            _ = try await attachment
            XCTFail("Expected notAttached")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .notAttached)
        }
        do {
            _ = try await turn
            XCTFail("Expected notAttached")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .notAttached)
        }

        async let pending = withTimeout { try await channel.send(.listRuntimes) }
        let second = try await server.nextConnection()
        try await second.acceptHello()
        let next = try await second.nextRequest()
        XCTAssertEqual(next.command, .listRuntimes)
        second.reply(next.id, .runtimes([]))
        _ = try await pending
    }

    func testACancelHeldThroughAnOutageIsDroppedWhenItsTurnHasEnded() async throws {
        let channel = channel!
        let turnID = UUID()
        let first = try await attached()
        first.event(1, .turnStarted(turnID: turnID, text: "x", attachments: []))
        _ = try await observer.nextEvent()
        first.drop()
        try await waitUntilReconnecting()
        async let cancelled = withTimeout { try await channel.send(.cancelPrompt(runtimeID: Fixture.runtimeID)) }
        try await Task.sleep(for: .milliseconds(20))

        let second = try await server.nextConnection()
        let ended = LatchRemoteTurnRecord(turnID: turnID, state: .ended, stopReason: "end_turn")
        try await second.acceptAttach(after: 1, record: Fixture.record(turns: [ended], lastSequence: 2))
        let response = try await cancelled
        XCTAssertEqual(response, .cancelRequested)
        try await second.expectSilence(for: 0.3)
    }

    func testACancelForTheRunningTurnIsSentAfterAnOutage() async throws {
        let channel = channel!
        let turnID = UUID()
        let first = try await attached()
        first.event(1, .turnStarted(turnID: turnID, text: "x", attachments: []))
        _ = try await observer.nextEvent()
        first.drop()
        try await waitUntilReconnecting()
        async let cancelled = withTimeout { try await channel.send(.cancelPrompt(runtimeID: Fixture.runtimeID)) }
        try await Task.sleep(for: .milliseconds(20))

        let second = try await server.nextConnection()
        let running = LatchRemoteTurnRecord(turnID: turnID, state: .running)
        try await second.acceptAttach(after: 1, record: Fixture.record(activeTurnID: turnID, turns: [running], lastSequence: 1))
        let request = try await second.nextRequest()
        XCTAssertEqual(request.command, .cancelPrompt(runtimeID: Fixture.runtimeID))
        second.reply(request.id, .cancelRequested)
        _ = try await cancelled
    }

    func testAPromptWhoseReplyDidNotDecodeIsAskedAgainByTurnID() async throws {
        let channel = channel!
        let turnID = UUID()
        let peer = try await attached()
        async let outcome = withTimeout { try await channel.prompt(turnID: turnID, blocks: [.text("x")]) }
        let first = try await peer.nextRequest()
        peer.sendLine(Data(#"{"type":"reply","id":"\#(first.id.uuidString)","result":{"ok":"garbled"}}"#.utf8 + [0x0A]))
        let second = try await peer.nextRequest()
        XCTAssertEqual(second.command, first.command)
        peer.reply(second.id, .promptAccepted(turnID: turnID))
        peer.event(1, .turnEnded(turnID: turnID, stopReason: "end_turn", error: nil))
        let result = try await outcome
        XCTAssertEqual(result.stopReason, "end_turn")
    }
}
#endif
