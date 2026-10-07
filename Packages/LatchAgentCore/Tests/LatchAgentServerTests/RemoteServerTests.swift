import Foundation
import LatchACP
import LatchAgentCore
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
import XCTest
@testable import LatchAgentServer

final class RemoteServerTests: XCTestCase {
    // MARK: Handshake

    func testAValidHelloIsWelcomed() async throws {
        try await withServer { testbed in
            let client = try testbed.connect()
            client.hello(token: testbed.token.rawValue)
            let frame = try await client.readFrame()
            XCTAssertEqual(frame, .welcome(LatchRemoteWelcome(
                protocolVersion: LatchRemoteProtocol.version,
                server: ServerTestbed.serverInfo,
                heartbeatSeconds: LatchRemoteProtocol.heartbeatSeconds,
                maxFrameBytes: LatchRemoteProtocol.maxFrameBytes
            )))
            let received = try await client.ok(.listRuntimes)
            XCTAssertEqual(received, .runtimes([]))
            try await testbed.waitForLog("authenticated")
        }
    }

    func testAWrongTokenIsRejectedBeforeTheVersionIsChecked() async throws {
        try await withServer { testbed in
            let client = try testbed.connect()
            // A version this server does not speak either; the token decides first.
            client.hello(token: LatchRemoteToken.generate().rawValue, range: LatchRemoteVersionRange(min: 90, max: 99))
            guard case let .rejected(rejected) = try await client.readFrame() else { return XCTFail("expected a rejection") }
            XCTAssertEqual(rejected.reason, .unauthorized)
            XCTAssertNil(rejected.supported)
            try await client.expectClosed()
            XCTAssertFalse(testbed.log.all.joined().contains(testbed.token.rawValue))
            try await testbed.waitForLog("failed to authenticate")
        }
    }

    func testAMismatchedVersionIsRejectedWithTheSupportedRange() async throws {
        try await withServer { testbed in
            let client = try testbed.connect()
            client.hello(token: testbed.token.rawValue, range: LatchRemoteVersionRange(min: 90, max: 99))
            guard case let .rejected(rejected) = try await client.readFrame() else { return XCTFail("expected a rejection") }
            XCTAssertEqual(rejected.reason, .protocolMismatch)
            XCTAssertEqual(rejected.supported, .supported)
            try await client.expectClosed()
        }
    }

    func testNothingButAHelloIsReadBeforeAuthentication() async throws {
        try await withServer { testbed in
            // A line over the pre-auth limit, with no newline yet.
            let long = try testbed.connect()
            long.send(Data(repeating: UInt8(ascii: "a"), count: LatchRemoteProtocol.preAuthMaxLineBytes + 1))
            try await long.expectClosed()

            // A request before the hello.
            let early = try testbed.connect()
            early.request(.listRuntimes)
            try await early.expectClosed()

            // A ping is not answered before authentication either.
            let ping = try testbed.connect()
            ping.send(.ping)
            try await ping.expectClosed()
        }
    }

    func testTheHandshakeDeadlineIsAbsolute() async throws {
        try await withServer({ $0.handshakeTimeout = .milliseconds(400) }) { testbed in
            let start = ContinuousClock.now
            let silent = try testbed.connect()
            // Trickling bytes does not extend it.
            let trickle = try testbed.connect()
            let trickling = Task.detached {
                for _ in 0..<40 {
                    guard trickle.send(Data("{".utf8)) else { return }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            try await silent.expectClosed(timeout: .seconds(5))
            try await trickle.expectClosed(timeout: .seconds(5))
            trickling.cancel()
            let elapsed = start.duration(to: .now)
            XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(350))
            XCTAssertLessThan(elapsed, .seconds(1.8))
        }
    }

    func testANewConnectionPastThePeerLimitClosesThatPeersOldest() async throws {
        try await withServer { testbed in
            var waiting: [TestSocketClient] = []
            for _ in 0..<8 { waiting.append(try testbed.connect()) }
            try await eventually("eight connections accepted") { testbed.server.connectionCount == 8 }

            // The ninth gets in; the first, which has sent nothing, makes room for it.
            let ninth = try testbed.connect()
            try await waiting[0].expectClosed(timeout: .seconds(3))
            try await testbed.waitForLog("too many connections have not authenticated")

            // The rest are still open and can authenticate, the ninth included.
            for client in waiting.dropFirst() + [ninth] {
                client.hello(token: testbed.token.rawValue)
                guard case .welcome = try await client.readFrame() else { return XCTFail("expected a welcome") }
            }
            _ = try await testbed.authenticated()
        }
    }

    /// Sockets that never send a hello, opened again as fast as the server closes them,
    /// cannot keep a client with the token out.
    func testIdleConnectionsCannotLockAClientOut() async throws {
        try await withServer({ $0.handshakeTimeout = .milliseconds(300) }) { testbed in
            let stop = Atomic(false)
            let port = testbed.port
            // As many as the server lets one peer hold, each opened again once it is closed.
            let squatter = Task.detached {
                var held: [TestSocketClient] = []
                while !stop.load(ordering: .relaxed) {
                    held.removeAll { !$0.isOpen }
                    while held.count < 8, let client = try? TestSocketClient(port: port) { held.append(client) }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                held.forEach { $0.disconnect() }
            }
            defer {
                stop.store(true, ordering: .relaxed)
                squatter.cancel()
            }
            try await eventually("the squatter holds every slot") { testbed.server.connectionCount >= 8 }
            for _ in 0..<10 {
                _ = try await testbed.authenticated()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func testEvictionTakesThePeersOwnOldestOrElseTheOldestOfAll() {
        let local: [UInt8] = [127, 0, 0, 1]
        let other: [UInt8] = [100, 64, 0, 7]
        let waiting: [UInt64: [UInt8]] = [3: other, 5: local, 9: local, 12: other]
        XCTAssertNil(RemoteServer.evictionVictim(among: waiting, for: local, perPeer: 3, total: 5))
        XCTAssertEqual(RemoteServer.evictionVictim(among: waiting, for: local, perPeer: 2, total: 5), 5)
        XCTAssertEqual(RemoteServer.evictionVictim(among: waiting, for: other, perPeer: 2, total: 5), 3)
        XCTAssertEqual(RemoteServer.evictionVictim(among: waiting, for: [10, 0, 0, 1], perPeer: 2, total: 4), 3)
        XCTAssertEqual(RemoteServer.evictionVictim(among: [:], for: local, perPeer: 1, total: 1), nil)
    }

    func testTheHandshakeDeadlineSparesAuthenticatedConnections() async throws {
        try await withServer({ $0.handshakeTimeout = .milliseconds(300) }) { testbed in
            let client = try await testbed.authenticated()
            try await Task.sleep(for: .seconds(1))
            client.send(.ping)
            let pong = try await client.readFrame()
            XCTAssertEqual(pong, .pong)
            let received = try await client.ok(.listRuntimes)
            XCTAssertEqual(received, .runtimes([]))
        }
    }

    func testConnectionsThatNeverAuthenticateCannotFloodTheLog() async throws {
        try await withServer { testbed in
            var waiting: [TestSocketClient] = []
            for _ in 0..<8 { waiting.append(try testbed.connect()) }
            try await eventually("eight connections accepted") { testbed.server.connectionCount == 8 }
            // Each pushes out the oldest that has not authenticated, and each of those is logged.
            for _ in 0..<60 {
                let newest = try testbed.connect()
                try await waiting.removeFirst().expectClosed(timeout: .seconds(3))
                waiting.append(newest)
            }
            testbed.server.log.flush()
            XCTAssertLessThanOrEqual(testbed.log.all.count, 30, "\(testbed.log.all)")

            // Authenticated connections are logged whatever the limit.
            waiting[0].hello(token: testbed.token.rawValue)
            guard case .welcome = try await waiting[0].readFrame() else { return XCTFail("expected a welcome") }
            try await testbed.waitForLog("authenticated")
        }
    }

    func testDeeplyNestedJSONIsReadWithoutExhaustingTheStack() async throws {
        try await withServer { testbed in
            // Not a hello, but all of it is parsed before the hello is checked.
            let deepHello = try testbed.connect()
            deepHello.send(line: #"{"type":"hello","x":"# + nestedJSON(depth: 510) + "}")
            try await deepHello.expectClosed()

            let client = try await testbed.authenticated()
            client.send(line: #"{"type":"ping","x":"# + nestedJSON(depth: 510) + "}")
            let pong = try await client.readFrame()
            XCTAssertEqual(pong, .pong)
            // Deeper than the decoder goes is not a frame.
            client.send(line: #"{"type":"ping","x":"# + nestedJSON(depth: 100_000) + "}")
            try await client.expectClosed()
            _ = try await testbed.authenticated()
        }
    }

    // MARK: Frames

    func testARequestGetsItsReply() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            let id = client.request(.stopRuntime(runtimeID: AgentRuntimeID("nothing")))
            let received = try await client.reply(to: id)
            XCTAssertEqual(received, .success(.stopped))
            let unknown = client.request(.unknown(kind: "fromTheFuture"))
            guard case let .failure(error) = try await client.reply(to: unknown) else { return XCTFail("expected a failure") }
            XCTAssertEqual(error.code, .unsupportedCommand)
        }
    }

    func testPingIsAnsweredWithPong() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            client.send(.ping)
            let received = try await client.readFrame()
            XCTAssertEqual(received, .pong)
        }
    }

    func testUnknownFramesAndInvalidRequests() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            let id = UUID()
            client.send(line: #"{"type":"fromTheFuture","id":"\#(id.uuidString)"}"#)
            guard case let .reply(reply) = try await client.readFrame(), case let .failure(error) = reply.result else {
                return XCTFail("expected an error reply")
            }
            XCTAssertEqual(reply.id, id)
            XCTAssertEqual(error.code, .unsupported)

            // Without an id it is ignored: the pong is the next frame.
            client.send(line: #"{"type":"fromTheFuture"}"#)
            client.send(.ping)
            let received = try await client.readFrame()
            XCTAssertEqual(received, .pong)

            let invalid = UUID()
            client.send(line: #"{"command":{"kind":"launchAgent"},"id":"\#(invalid.uuidString)","type":"request"}"#)
            guard case let .failure(invalidError) = try await client.reply(to: invalid) else { return XCTFail("expected a failure") }
            XCTAssertEqual(invalidError.code, .invalidRequest)
        }
    }

    func testFramesThatBreakTheProtocolClose() async throws {
        try await withServer { testbed in
            let array = try await testbed.authenticated()
            array.send(line: "[1,2,3]")
            try await array.expectClosed()

            let secondHello = try await testbed.authenticated()
            secondHello.hello(token: testbed.token.rawValue)
            try await secondHello.expectClosed()

            let empty = try await testbed.authenticated()
            empty.send(line: "")
            try await empty.expectClosed()
        }
    }

    func testAFrameOverTheSizeLimitCloses() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            // The server closes while this is still being written; the write may fail.
            let oversized = Data(repeating: UInt8(ascii: "a"), count: LatchRemoteProtocol.maxFrameBytes + 1)
            Task.detached { client.send(oversized) }
            try await client.expectClosed(timeout: .seconds(20))
            try await testbed.waitForLog("size limit")
        }
    }

    func testTheThirtyThirdOutstandingRequestIsBusy() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            let id = AgentRuntimeID("hanging")
            try await client.ok(.launchAgent(runtimeID: id, agent: testbed.bed.script("hanging-session.sh"), workspace: testbed.bed.workspace.path))
            // The agent never answers session/new, so each retry waits on the first.
            var pending: [UUID] = []
            for _ in 0..<32 { pending.append(client.request(.newSession(runtimeID: id))) }
            let extra = client.request(.listRuntimes)
            guard case let .failure(error) = try await client.reply(to: extra) else { return XCTFail("expected busy") }
            XCTAssertEqual(error.code, .busy)

            // Stopping the agent fails the waiting requests, which frees the connection.
            try await testbed.bed.ok(.stopRuntime(runtimeID: id))
            var answered = Set<UUID>()
            let frames = try await client.readFrames(until: "every newSession answered") { frame in
                if case let .reply(reply) = frame { answered.insert(reply.id) }
                return answered.isSuperset(of: pending)
            }
            XCTAssertEqual(frames.count, 32)
            let received = try await client.ok(.listRuntimes)
            XCTAssertEqual(received.kind, "runtimes")
        }
    }

    // MARK: Events

    func testTheAttachedReplyComesBeforeAnyEventOfThatRuntime() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            let id = AgentRuntimeID("ordered")
            try await client.ok(.launchAgent(runtimeID: id, agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path))
            try await client.ok(.newSession(runtimeID: id))
            // One turn journaled before the attach, one streaming while it is answered.
            let first = UUID()
            try await client.ok(.prompt(runtimeID: id, turnID: first, blocks: [.text("go")]))
            try await testbed.bed.waitForIdle(id, through: 5)
            let second = UUID()
            try await client.ok(.prompt(runtimeID: id, turnID: second, blocks: [.text("slow")]))

            let attach = client.request(.attach(runtimeID: id, after: 0))
            // The whole second turn: its end, and every chunk before it.
            var ended = false
            var chunks = 0
            let frames = try await client.readFrames(until: "the second turn, whole") { frame in
                guard case let .event(event) = frame else { return false }
                if event.chunkText != nil { chunks += 1 }
                if case let .turnEnded(turnID, _, _) = event.event, turnID == second { ended = true }
                return ended && chunks == 6
            }
            let replyIndex = try XCTUnwrap(frames.firstIndex {
                if case let .reply(reply) = $0 { reply.id == attach } else { false }
            })
            let events = frames.compactMap { frame -> LatchRemoteEventFrame? in
                if case let .event(event) = frame { event } else { nil }
            }
            let firstEventIndex = try XCTUnwrap(frames.firstIndex { if case .event = $0 { true } else { false } })
            XCTAssertLessThan(replyIndex, firstEventIndex)
            XCTAssertEqual(events.map(\.sequence), Array(1...UInt64(events.count)))
            XCTAssertEqual(events.chunkTexts, ["one", "two", "three", "one", "two", "three"])
            guard case let .reply(reply) = frames[replyIndex], case let .success(.attached(record, backlogFrom, truncated)) = reply.result else {
                return XCTFail("expected an attached reply")
            }
            XCTAssertEqual(record.runtimeID, id)
            XCTAssertEqual(backlogFrom, 1)
            XCTAssertFalse(truncated)
        }
    }

    /// The attach is answered while the writer waits between writing a pong and pulling
    /// events; activating the cursor any earlier than writing the reply would put the backlog
    /// ahead of it.
    func testAnAttachmentYieldsEventsOnlyOnceItsReplyIsWritten() async throws {
        try await withServer({ $0.writerPauseForTesting = .milliseconds(300) }) { testbed in
            let client = try await testbed.authenticated()
            let id = AgentRuntimeID("paused")
            try await client.ok(.launchAgent(runtimeID: id, agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path))
            try await client.ok(.newSession(runtimeID: id))
            try await client.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]))
            try await testbed.bed.waitForIdle(id, through: 5)

            client.send(.ping)
            let pong = try await client.readFrame()
            XCTAssertEqual(pong, .pong)
            let attach = client.request(.attach(runtimeID: id, after: 0))
            let frames = try await client.readFrames(until: "the backlog's turn end") { frame in
                if case let .event(event) = frame { event.isTurnEnded } else { false }
            }
            guard case let .reply(reply) = frames.first else { return XCTFail("an event came before the attached reply: \(frames)") }
            XCTAssertEqual(reply.id, attach)
        }
    }

    func testAClosedConnectionNoLongerHoldsItsRuntimes() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            let id = AgentRuntimeID("held")
            try await client.ok(.launchAgent(runtimeID: id, agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path))
            try await client.ok(.attach(runtimeID: id, after: 0))
            let muchLater = testbed.bed.clock.base + .seconds(48 * 60 * 60)
            await testbed.bed.hub.reapDetachedRuntimes(now: muchLater)
            try await testbed.bed.expect(id, lifecycle: .ready)

            client.disconnect()
            try await eventually("the server to let the connection go") { testbed.server.connectionCount == 0 }
            await testbed.bed.hub.reapDetachedRuntimes(now: muchLater)
            try await testbed.bed.expect(.attach(runtimeID: id, after: 0), fails: .runtimeNotFound)
        }
    }

    func testAnotherConnectionsRuntimeEventsAreNotSent() async throws {
        try await withServer { testbed in
            let watcher = try await testbed.authenticated()
            let other = try await testbed.authenticated()
            let id = AgentRuntimeID("elsewhere")
            try await other.ok(.launchAgent(runtimeID: id, agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path))
            try await other.ok(.newSession(runtimeID: id))
            try await other.ok(.attach(runtimeID: id, after: 0))
            try await other.ok(.prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]))
            _ = try await other.readFrames(until: "the turn's end") { frame in
                if case let .event(event) = frame { event.isTurnEnded } else { false }
            }
            watcher.send(.ping)
            let received = try await watcher.readFrame()
            XCTAssertEqual(received, .pong)
        }
    }

    // MARK: Liveness

    func testSilenceClosesAConnectionThatPingsKeepOpen() async throws {
        try await withServer({ $0.silenceTimeout = .milliseconds(500) }) { testbed in
            let client = try await testbed.authenticated()
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(200))
                client.send(.ping)
                let received = try await client.readFrame()
                XCTAssertEqual(received, .pong)
            }
            let start = ContinuousClock.now
            try await client.expectClosed(timeout: .seconds(5))
            XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(400))
            try await testbed.waitForLog("nothing received")
        }
    }

    // MARK: Token

    func testRotatingTheTokenDropsItsConnectionsAndRefusesIt() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            let old = testbed.token
            let new = try testbed.tokens.rotate()
            XCTAssertNotEqual(new, old)
            // What SIGHUP does.
            testbed.server.checkToken()
            try await client.expectClosed()

            let stale = try testbed.connect()
            stale.hello(token: old.rawValue)
            guard case let .rejected(rejected) = try await stale.readFrame() else { return XCTFail("expected a rejection") }
            XCTAssertEqual(rejected.reason, .unauthorized)

            let fresh = try testbed.connect()
            fresh.hello(token: new.rawValue)
            guard case .welcome = try await fresh.readFrame() else { return XCTFail("expected a welcome") }
        }
    }

    // MARK: Compression

    /// What a client that offers compression reads is compressed after the welcome, and the
    /// same frames as a plain client's once decompressed, events of a turn included.
    func testAClientThatOffersCompressionGetsItAndTheSameFrames() async throws {
        try await withServer { testbed in
            let id = AgentRuntimeID("compressed")
            var sizes: [Bool: (received: Int, chunks: [String])] = [:]
            for compressed in [false, true] {
                let client = try testbed.connect()
                client.hello(token: testbed.token.rawValue, compression: compressed ? [.deflate] : [])
                guard case let .welcome(welcome) = try await client.readFrame() else { return XCTFail("expected a welcome") }
                XCTAssertEqual(welcome.compression, compressed ? .deflate : nil)
                if !compressed {
                    try await client.ok(.launchAgent(runtimeID: id, agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path))
                    try await client.ok(.newSession(runtimeID: id))
                    for _ in 0..<5 {
                        let turnID = UUID()
                        try await client.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("go")]))
                        try await testbed.bed.waitForIdle(id, through: 0)
                    }
                    try await eventually("five turns") { testbed.bed.lines(in: "prompts.log") == 5 }
                }
                let start = client.bytesReceived.withLock { $0 }
                try await client.ok(.attach(runtimeID: id, after: 0))
                var chunks: [String] = []
                _ = try await client.readFrames(until: "the fifth turn's end") { frame in
                    guard case let .event(event) = frame else { return false }
                    if let text = event.chunkText { chunks.append(text) }
                    if case .turnEnded = event.event { return chunks.count == 15 }
                    return false
                }
                sizes[compressed] = (client.bytesReceived.withLock { $0 } - start, chunks)
            }
            XCTAssertEqual(sizes[true]?.chunks, sizes[false]?.chunks)
            let plain = try XCTUnwrap(sizes[false]?.received)
            let compressed = try XCTUnwrap(sizes[true]?.received)
            XCTAssertLessThan(compressed * 3, plain, "\(plain) bytes plain, \(compressed) compressed")
        }
    }

    func testAWebSocketCarriesTheCompressedStreamToo() async throws {
        try await withServer { testbed in
            let client = try testbed.connect()
            let response = try await client.upgrade()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 "), response)
            client.hello(token: testbed.token.rawValue, compression: [.deflate])
            guard case let .welcome(welcome) = try await client.readFrame() else { return XCTFail("expected a welcome") }
            XCTAssertEqual(welcome.compression, .deflate)
            guard case .runtimes = try await client.ok(.listRuntimes) else { return XCTFail("expected runtimes") }
            client.send(.ping)
            let pong = try await client.readFrame()
            XCTAssertEqual(pong, .pong)
        }
    }

    func testAServerWithoutCompressionSpeaksPlain() async throws {
        try await withServer({ $0.compression = false }) { testbed in
            let client = try testbed.connect()
            client.hello(token: testbed.token.rawValue, compression: [.deflate])
            guard case let .welcome(welcome) = try await client.readFrame() else { return XCTFail("expected a welcome") }
            XCTAssertNil(welcome.compression)
            guard case .runtimes = try await client.ok(.listRuntimes) else { return XCTFail("expected runtimes") }
        }
    }

    // MARK: Pairing codes

    /// What the welcome gave the hello, or nil when it was refused.
    private func exchange(_ code: LatchRemoteToken, on testbed: ServerTestbed, exchanges: Bool = true) async throws -> LatchRemoteWelcome? {
        let client = try testbed.connect()
        client.hello(token: code.rawValue, exchangesPairingCode: exchanges)
        switch try await client.readFrame() {
        case let .welcome(welcome): return welcome
        case .rejected: return nil
        default: throw HubTestError.unexpected("neither a welcome nor a rejection")
        }
    }

    func testAPairingCodeIsExchangedForADeviceTokenOnce() async throws {
        try await withServer { testbed in
            let code = try ServerDeviceTokens.makePairingCode("phone", access: .full, configDirectory: testbed.configDirectory)
            let first = try await exchange(code, on: testbed)
            let token = try XCTUnwrap(first?.deviceToken)
            XCTAssertNotEqual(token, code)
            try await testbed.waitForLog("authenticated as device phone, exchanging a pairing code for its token")
            // A welcome lost on its way: the code gives the same token again.
            let retried = try await exchange(code, on: testbed)
            XCTAssertEqual(retried?.deviceToken, token)

            // The device connects with its token: the code is spent.
            let device = try testbed.connect()
            device.hello(token: token.rawValue, exchangesPairingCode: true)
            guard case let .welcome(welcome) = try await device.readFrame() else { return XCTFail("expected a welcome") }
            XCTAssertNil(welcome.deviceToken)
            let spent = try await exchange(code, on: testbed)
            XCTAssertNil(spent)
            XCTAssertEqual(try ServerDeviceTokens.readAll(configDirectory: testbed.configDirectory).map(\.name), ["phone"])
            XCTAssertEqual(try ServerDeviceTokens.pairingCodes(configDirectory: testbed.configDirectory).read().count, 0)
        }
    }

    func testAnAppThatCannotExchangeKeepsTheCodeAsItsToken() async throws {
        try await withServer { testbed in
            let code = try ServerDeviceTokens.makePairingCode("old-phone", access: .full, configDirectory: testbed.configDirectory)
            let welcome = try await exchange(code, on: testbed, exchanges: false)
            XCTAssertNotNil(welcome)
            XCTAssertNil(welcome?.deviceToken)
            let devices = try ServerDeviceTokens.readAll(configDirectory: testbed.configDirectory)
            XCTAssertEqual(devices.map(\.name), ["old-phone"])
            XCTAssertEqual(try devices[0].token.get(), code)
            // It goes on working, as the device's token now.
            let again = try await exchange(code, on: testbed, exchanges: false)
            XCTAssertNotNil(again)
        }
    }

    func testAPairingCodeNobodyUsesExpires() async throws {
        try await withServer { testbed in
            let code = try ServerDeviceTokens.makePairingCode("late", access: .full, configDirectory: testbed.configDirectory)
            let codes = ServerDeviceTokens.pairingCodes(configDirectory: testbed.configDirectory)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-11 * 60)],
                                                  ofItemAtPath: codes.directory + "/late")
            let expired = try await exchange(code, on: testbed)
            XCTAssertNil(expired)
            XCTAssertEqual(try ServerDeviceTokens.readAll(configDirectory: testbed.configDirectory).count, 0)
        }
    }

    func testPairingADeviceAgainReplacesItsToken() async throws {
        try await withServer { testbed in
            let devices = ServerDeviceTokens(configDirectory: testbed.configDirectory)
            let old = try devices.readOrCreate("phone")
            let oldPhone = try testbed.connect()
            oldPhone.hello(token: old.rawValue)
            guard case .welcome = try await oldPhone.readFrame() else { return XCTFail("expected a welcome") }

            let code = try ServerDeviceTokens.makePairingCode("phone", access: .full, configDirectory: testbed.configDirectory)
            let exchanged = try await exchange(code, on: testbed)
            let new = try XCTUnwrap(exchanged?.deviceToken)
            XCTAssertNotEqual(new, old)
            testbed.server.checkToken()
            try await oldPhone.expectClosed()
        }
    }

    func testAWatchOnlyCodePairsAWatchOnlyDevice() async throws {
        try await withServer { testbed in
            let code = try ServerDeviceTokens.makePairingCode("tv", access: .watch, configDirectory: testbed.configDirectory)
            let exchanged = try await exchange(code, on: testbed)
            let token = try XCTUnwrap(exchanged?.deviceToken)
            let tv = try testbed.connect()
            tv.hello(token: token.rawValue)
            guard case .welcome = try await tv.readFrame() else { return XCTFail("expected a welcome") }
            guard case let .failure(error) = try await tv.reply(to: tv.request(.stopRuntime(runtimeID: AgentRuntimeID("x")))) else {
                return XCTFail("expected a refusal")
            }
            XCTAssertEqual(error.code, .forbidden)
            XCTAssertEqual(try ServerDeviceTokens.readAll(configDirectory: testbed.configDirectory).map(\.access), [.watch])
        }
    }

    func testAWatchOnlyDeviceFollowsAgentsAndChangesNothing() async throws {
        try await withServer { testbed in
            let viewerToken = try ServerDeviceTokens(configDirectory: testbed.configDirectory, access: .watch).readOrCreate("viewer")
            let owner = try await testbed.authenticated()
            let id = AgentRuntimeID("watched")
            try await owner.ok(.launchAgent(runtimeID: id, agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path))
            try await owner.ok(.newSession(runtimeID: id))

            let viewer = try testbed.connect()
            viewer.hello(token: viewerToken.rawValue)
            guard case .welcome = try await viewer.readFrame() else { return XCTFail("expected a welcome") }
            try await testbed.waitForLog("authenticated as device viewer, watch only")
            guard case let .runtimes(listed) = try await viewer.ok(.listRuntimes) else { return XCTFail("expected runtimes") }
            XCTAssertEqual(listed.map(\.runtimeID), [id])
            try await viewer.ok(.attach(runtimeID: id, after: 0))

            // What the owner does, the viewer sees.
            let turnID = UUID()
            try await owner.ok(.prompt(runtimeID: id, turnID: turnID, blocks: [.text("go")]))
            _ = try await viewer.readFrames(until: "the turn's end") { frame in
                if case let .event(event) = frame, case .turnEnded = event.event { true } else { false }
            }

            // And it can change nothing.
            for command: LatchRemoteCommand in [
                .prompt(runtimeID: id, turnID: UUID(), blocks: [.text("go")]),
                .cancelPrompt(runtimeID: id),
                .setMode(runtimeID: id, modeID: "code"),
                .stopRuntime(runtimeID: id),
                .launchAgent(runtimeID: AgentRuntimeID("mine"), agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path),
            ] {
                guard case let .failure(error) = try await viewer.reply(to: viewer.request(command)) else {
                    return XCTFail("\(command.kind) should be refused")
                }
                XCTAssertEqual(error.code, .forbidden, command.kind)
                XCTAssertTrue(error.message.contains("can only watch"), error.message)
            }
            XCTAssertEqual(testbed.bed.lines(in: "prompts.log"), 1)
            guard case let .runtimes(after) = try await owner.ok(.listRuntimes) else { return XCTFail("expected runtimes") }
            XCTAssertEqual(after.map(\.lifecycle), [.ready])
        }
    }

    func testADeviceTokenAuthenticatesAndRevokingItDropsOnlyThatDevice() async throws {
        try await withServer { testbed in
            let devices = ServerDeviceTokens(configDirectory: testbed.configDirectory)
            let phoneToken = try devices.readOrCreate("phone")
            let tabletToken = try devices.readOrCreate("tablet")
            let server = try await testbed.authenticated()
            let phone = try testbed.connect()
            phone.hello(token: phoneToken.rawValue)
            guard case .welcome = try await phone.readFrame() else { return XCTFail("expected a welcome") }
            let tablet = try testbed.connect()
            tablet.hello(token: tabletToken.rawValue)
            guard case .welcome = try await tablet.readFrame() else { return XCTFail("expected a welcome") }
            try await testbed.waitForLog("authenticated as device phone")

            let use = try XCTUnwrap(ServerTokenUse.read(configDirectory: testbed.configDirectory))
            XCTAssertEqual(use.devices.keys.sorted(), ["phone", "tablet"])
            XCTAssertEqual(use.devices["phone"]?.from, "127.0.0.1")
            XCTAssertEqual(use.server?.from, "127.0.0.1")

            XCTAssertTrue(try devices.revoke("phone"))
            // What SIGHUP does.
            testbed.server.checkToken()
            try await phone.expectClosed()
            try await testbed.waitForLog("closed: device phone's token is no longer valid")
            // A revoked device's use is forgotten.
            XCTAssertEqual(ServerTokenUse.read(configDirectory: testbed.configDirectory)?.devices.keys.sorted(), ["tablet"])
            for client in [server, tablet] {
                client.send(.ping)
                let pong = try await client.readFrame()
                XCTAssertEqual(pong, .pong)
            }

            let revoked = try testbed.connect()
            revoked.hello(token: phoneToken.rawValue)
            guard case let .rejected(rejected) = try await revoked.readFrame() else { return XCTFail("expected a rejection") }
            XCTAssertEqual(rejected.reason, .unauthorized)
        }
    }

    func testRotatingTheServerTokenLeavesDevicesConnected() async throws {
        try await withServer { testbed in
            let phoneToken = try ServerDeviceTokens(configDirectory: testbed.configDirectory).readOrCreate("phone")
            let server = try await testbed.authenticated()
            let phone = try testbed.connect()
            phone.hello(token: phoneToken.rawValue)
            guard case .welcome = try await phone.readFrame() else { return XCTFail("expected a welcome") }

            try testbed.tokens.rotate()
            testbed.server.checkToken()
            try await server.expectClosed()
            phone.send(.ping)
            let pong = try await phone.readFrame()
            XCTAssertEqual(pong, .pong)
        }
    }

    func testAnUnusableDeviceTokenIsRefusedAndDropsItsConnections() async throws {
        try await withServer { testbed in
            let devices = ServerDeviceTokens(configDirectory: testbed.configDirectory)
            let phoneToken = try devices.readOrCreate("phone")
            let phone = try testbed.connect()
            phone.hello(token: phoneToken.rawValue)
            guard case .welcome = try await phone.readFrame() else { return XCTFail("expected a welcome") }
            let server = try await testbed.authenticated()

            XCTAssertEqual(chmod(devices.directory + "/phone", 0o644), 0)
            let loose = try testbed.connect()
            loose.hello(token: phoneToken.rawValue)
            guard case let .rejected(rejected) = try await loose.readFrame() else { return XCTFail("expected a rejection") }
            XCTAssertEqual(rejected.reason, .unauthorized)
            // The check at that hello dropped the phone, and only the phone.
            try await phone.expectClosed()
            server.send(.ping)
            let pong = try await server.readFrame()
            XCTAssertEqual(pong, .pong)
        }
    }

    func testThePeriodicCheckNoticesARotation() async throws {
        try await withServer({ $0.tokenCheckInterval = .milliseconds(100) }) { testbed in
            let client = try await testbed.authenticated()
            try testbed.tokens.rotate()
            try await client.expectClosed(timeout: .seconds(5))
            try await testbed.waitForLog("token changed")
        }
    }

    func testATokenFileThatCannotBeReadForNowKeepsConnections() async throws {
        try XCTSkipIf(geteuid() == 0, "root opens the file whatever its directory's mode")
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            // Opening the file fails with EACCES, which says nothing about the token.
            XCTAssertEqual(chmod(testbed.configDirectory, 0), 0)
            defer { chmod(testbed.configDirectory, 0o700) }
            let refused = try testbed.connect()
            refused.hello(token: testbed.token.rawValue)
            guard case let .rejected(rejected) = try await refused.readFrame() else { return XCTFail("expected a rejection") }
            testbed.server.checkToken()
            XCTAssertEqual(rejected.reason, .unauthorized)

            client.send(.ping)
            let pong = try await client.readFrame()
            XCTAssertEqual(pong, .pong)
        }
    }

    func testAMissingOrLoosenedTokenFileFailsEveryHello() async throws {
        try await withServer { testbed in
            let client = try await testbed.authenticated()
            XCTAssertEqual(chmod(testbed.tokens.path, 0o640), 0)
            let loose = try testbed.connect()
            loose.hello(token: testbed.token.rawValue)
            guard case let .rejected(looseRejection) = try await loose.readFrame() else { return XCTFail("expected a rejection") }
            XCTAssertEqual(looseRejection.reason, .unauthorized)
            // The check at that hello also dropped the connection that used the token.
            try await client.expectClosed()

            XCTAssertEqual(unlink(testbed.tokens.path), 0)
            let missing = try testbed.connect()
            missing.hello(token: testbed.token.rawValue)
            guard case let .rejected(missingRejection) = try await missing.readFrame() else { return XCTFail("expected a rejection") }
            XCTAssertEqual(missingRejection.reason, .unauthorized)
        }
    }

    // MARK: Shutdown

    func testShutdownClosesConnectionsAndStopsRuntimes() async throws {
        let testbed = try await ServerTestbed()
        let client = try await testbed.authenticated()
        let id = AgentRuntimeID("stopping")
        try await client.ok(.launchAgent(runtimeID: id, agent: testbed.bed.mockAgent, workspace: testbed.bed.workspace.path))
        try await client.ok(.attach(runtimeID: id, after: 0))
        let handshaking = try testbed.connect()

        await testbed.server.shutdown()
        // Runtimes stop before connections close, so a client hears its agent was stopped
        // rather than only that the server went away.
        _ = try await client.readFrames(until: "the stop") { frame in
            guard case let .event(event) = frame, event.runtimeID == id else { return false }
            // Stopped by the server shutting down, so a client can resume once it is back.
            return event.event == .exited(LatchRemoteExit(status: nil, stopped: true, serverShutDown: true))
        }
        try await client.expectClosed()
        try await handshaking.expectClosed()
        XCTAssertThrowsError(try testbed.connect())
        XCTAssertEqual(testbed.server.connectionCount, 0)
        // The hub refuses commands once shut down; its runtimes were stopped.
        guard case let .failure(error) = await testbed.bed.send(.listRuntimes) else { return XCTFail("expected a failure") }
        XCTAssertEqual(error.code, .commandFailed)
        await testbed.close()
    }
}
