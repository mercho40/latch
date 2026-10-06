#if canImport(Network)
import Foundation
import LatchACP
@testable import LatchRemoteClient
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest

final class LatchRemoteConnectionTests: XCTestCase {
    private func connect(
        _ server: FakeServer,
        options: LatchRemoteConnectionOptions? = nil,
        events: TestInbox<LatchRemoteEventFrame>? = nil,
        states: TestInbox<LatchRemoteConnection.State>? = nil
    ) -> LatchRemoteConnection {
        let connection = LatchRemoteConnection(
            options: options ?? server.options(),
            stateHandler: { states?.put($0) },
            eventHandler: { events?.put($0) }
        )
        connection.start()
        return connection
    }

    func testHandshakeSendsTheHelloAndReportsTheWelcome() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let states = TestInbox<LatchRemoteConnection.State>("a state")
        let connection = connect(server, states: states)
        defer { connection.close() }

        let hello = try await server.nextConnection().acceptHello(heartbeatSeconds: 7)
        XCTAssertEqual(hello.token, Fixture.token.rawValue)
        XCTAssertEqual(hello.client, Fixture.client)
        XCTAssertEqual(hello.protocolRange, .supported)

        let welcome = try await withTimeout { try await connection.waitUntilReady() }
        XCTAssertEqual(welcome, Fixture.welcome(heartbeatSeconds: 7))
        XCTAssertEqual(connection.state, .ready(welcome))
        assertEqual(try await states.next(), .connecting)
        assertEqual(try await states.next(), .authenticating)
        assertEqual(try await states.next(), .ready(welcome))
    }

    func testUnauthorizedIsItsOwnError() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        let peer = try await server.nextConnection()
        _ = try await peer.nextFrame()
        peer.send(.rejected(LatchRemoteRejected(reason: .unauthorized, message: "Bad token")))

        do {
            _ = try await withTimeout { try await connection.waitUntilReady() }
            XCTFail("Expected a rejection")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .unauthorized(message: "Bad token"))
        }
        XCTAssertEqual(connection.state, .closed(.unauthorized(message: "Bad token")))
        try await peer.waitForClose()
    }

    func testProtocolMismatchIsItsOwnError() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        let peer = try await server.nextConnection()
        _ = try await peer.nextFrame()
        let supported = LatchRemoteVersionRange(min: 2, max: 3)
        peer.send(.rejected(LatchRemoteRejected(reason: .protocolMismatch, message: "Too old", supported: supported)))

        do {
            _ = try await withTimeout { try await connection.waitUntilReady() }
            XCTFail("Expected a rejection")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .protocolMismatch(message: "Too old", supported: supported))
        }
    }

    func testAWelcomeForAnUnknownVersionIsAMismatch() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        let peer = try await server.nextConnection()
        _ = try await peer.nextFrame()
        peer.send(.welcome(LatchRemoteWelcome(protocolVersion: 99, server: Fixture.server)))

        do {
            _ = try await withTimeout { try await connection.waitUntilReady() }
            XCTFail("Expected a mismatch")
        } catch let LatchRemoteClientError.protocolMismatch(_, supported) {
            XCTAssertNil(supported)
        }
    }

    func testRepliesAreMatchedByIDWhenTheyArriveOutOfOrder() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        _ = try await connection.waitUntilReady()

        async let first = withTimeout { try await connection.request(.listRuntimes) }
        let firstRequest = try await peer.nextRequest()
        async let second = withTimeout { try await connection.request(.cancelPrompt(runtimeID: Fixture.runtimeID)) }
        let secondRequest = try await peer.nextRequest()
        XCTAssertEqual(firstRequest.command, .listRuntimes)
        XCTAssertEqual(secondRequest.command, .cancelPrompt(runtimeID: Fixture.runtimeID))
        XCTAssertNotEqual(firstRequest.id, secondRequest.id)

        peer.reply(secondRequest.id, .cancelRequested)
        peer.reply(UUID(), .stopped) // Nobody asked; ignored.
        peer.reply(firstRequest.id, .runtimes([]))

        let firstResponse = try await first
        let secondResponse = try await second
        XCTAssertEqual(firstResponse, .runtimes([]))
        XCTAssertEqual(secondResponse, .cancelRequested)
    }

    func testAServerFailureIsThrownAsItsCode() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        _ = try await connection.waitUntilReady()

        async let response = withTimeout { try await connection.request(.newSession(runtimeID: Fixture.runtimeID)) }
        peer.reply(try await peer.nextRequest().id, failure: .noSession)
        do {
            _ = try await response
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual((error as? LatchRemoteError)?.code, .noSession)
        }
    }

    func testAnInvalidReplyFailsOnlyItsRequest() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        _ = try await connection.waitUntilReady()

        async let broken = withTimeout { try await connection.request(.listRuntimes) }
        let brokenRequest = try await peer.nextRequest()
        async let fine = withTimeout { try await connection.request(.detach(runtimeID: Fixture.runtimeID)) }
        let fineRequest = try await peer.nextRequest()

        peer.sendLine(Data(#"{"id":"\#(brokenRequest.id.uuidString)","result":{"ok":{"no":"kind"}},"type":"reply"}"#.utf8 + [0x0A]))
        peer.reply(fineRequest.id, .detached)

        do {
            _ = try await broken
            XCTFail("Expected an invalid reply")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .invalidReply)
        }
        let fineResponse = try await fine
        XCTAssertEqual(fineResponse, .detached)
        guard case .ready = connection.state else { return XCTFail("The connection should stay up") }
    }

    func testAnOversizedRequestFailsLocallyAndWritesNothing() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello(maxFrameBytes: 512)
        _ = try await connection.waitUntilReady()
        let bytesAfterHello = peer.byteCount

        let prompt = LatchRemoteCommand.prompt(
            runtimeID: Fixture.runtimeID,
            turnID: UUID(),
            blocks: [.text(String(repeating: "x", count: 600))]
        )
        do {
            _ = try await withTimeout { try await connection.request(prompt) }
            XCTFail("Expected payloadTooLarge")
        } catch {
            XCTAssertEqual((error as? LatchRemoteError)?.code, .payloadTooLarge)
        }

        // The next frame the server reads is the next request, and the connection is still up.
        async let next = withTimeout { try await connection.request(.listRuntimes) }
        let request = try await peer.nextRequest()
        XCTAssertEqual(request.command, .listRuntimes)
        XCTAssertLessThan(peer.byteCount - bytesAfterHello, 200)
        peer.reply(request.id, .runtimes([]))
        _ = try await next
    }

    func testEventsKeepTheirSequenceEvenWhenTheirKindIsUnknown() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let events = TestInbox<LatchRemoteEventFrame>("an event")
        let connection = connect(server, events: events)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()

        let turnID = UUID()
        peer.event(1, .turnStarted(turnID: turnID, text: "hi", attachments: []))
        peer.sendLine(Data(#"{"event":{"kind":"fromTheFuture","x":1},"runtimeID":"rt-1","sequence":7,"type":"event"}"#.utf8 + [0x0A]))
        peer.sendLine(Data(#"{"type":"somethingNew"}"#.utf8 + [0x0A]))
        peer.event(9, .permissionClosed(requestID: turnID), gap: true, runtimeID: AgentRuntimeID("other"))

        assertEqual(try await events.next(), LatchRemoteEventFrame(
            runtimeID: Fixture.runtimeID, sequence: 1, event: .turnStarted(turnID: turnID, text: "hi", attachments: [])
        ))
        assertEqual(try await events.next(), LatchRemoteEventFrame(
            runtimeID: Fixture.runtimeID, sequence: 7, event: .unknown(kind: "fromTheFuture")
        ))
        assertEqual(try await events.next(), LatchRemoteEventFrame(
            runtimeID: AgentRuntimeID("other"), sequence: 9, event: .permissionClosed(requestID: turnID), gap: true
        ))
    }

    func testSilenceClosesAfterThreeHeartbeatsAndAPingGoesOutFirst() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let states = TestInbox<LatchRemoteConnection.State>("a state")
        let connection = connect(server, states: states)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello(heartbeatSeconds: 1)
        let start = ContinuousClock.now

        assertEqual(try await peer.nextFrame(timeout: 3), .ping)
        while true {
            if case let .closed(error) = try await states.next(timeout: 6) {
                XCTAssertEqual(error, .silence)
                break
            }
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(3))
        XCTAssertLessThan(elapsed, .seconds(5))
        try await peer.waitForClose()
    }

    func testAPongAnswersAPing() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        _ = try await connection.waitUntilReady()

        async let ping: Void = withTimeout { try await connection.ping(timeout: .seconds(3)) }
        assertEqual(try await peer.nextFrame(), .ping)
        peer.send(.pong)
        try await ping

        do {
            try await withTimeout { try await connection.ping(timeout: .milliseconds(100)) }
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .timedOut)
        }
    }

    func testAPeerOffTheTailnetNeverReceivesTheToken() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        var options = server.options()
        options.peerAddressForTesting = [203, 0, 113, 7]
        let connection = connect(server, options: options)
        let peer = try await server.nextConnection()

        do {
            _ = try await withTimeout { try await connection.waitUntilReady() }
            XCTFail("Expected destinationNotAllowed")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .destinationNotAllowed(address: "203.0.113.7"))
            XCTAssertTrue((error as? LatchRemoteClientError)?.isPermanent == true)
        }
        try await peer.waitForClose()
        XCTAssertEqual(peer.byteCount, 0)
    }

    func testATailnetAddressOffTheTunnelNeverReceivesTheToken() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        var options = server.options()
        // The real path runs over lo0, as a tailnet address would over Wi-Fi with Tailscale down.
        options.peerAddressForTesting = [100, 101, 102, 103]
        let connection = connect(server, options: options)
        let peer = try await server.nextConnection()

        do {
            _ = try await withTimeout { try await connection.waitUntilReady() }
            XCTFail("Expected destinationNotAllowed")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .destinationNotAllowed(address: "100.101.102.103"))
        }
        try await peer.waitForClose()
        XCTAssertEqual(peer.byteCount, 0)
    }

    func testATailnetAddressThroughATunnelReceivesTheHello() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        var options = server.options()
        options.peerAddressForTesting = [100, 101, 102, 103]
        options.localAddressForTesting = [100, 90, 1, 2]
        options.interfaceNameForTesting = "utun4"
        let connection = connect(server, options: options)
        defer { connection.close() }
        try await server.nextConnection().acceptHello()
        _ = try await withTimeout { try await connection.waitUntilReady() }
    }

    /// Another VPN's tunnel, from an address of that VPN's: nothing is written.
    func testATailnetAddressThroughAnotherVPNNeverReceivesTheHello() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        var options = server.options()
        options.peerAddressForTesting = [100, 101, 102, 103]
        options.localAddressForTesting = [10, 8, 0, 2]
        options.interfaceNameForTesting = "utun4"
        let connection = connect(server, options: options)
        let peer = try await server.nextConnection()
        do {
            _ = try await withTimeout { try await connection.waitUntilReady() }
            XCTFail("Expected destinationNotAllowed")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .destinationNotAllowed(address: "100.101.102.103"))
        }
        try await peer.waitForClose()
        XCTAssertEqual(peer.byteCount, 0)
    }

    func testAWelcomeWithLimitsOutOfRangeIsAViolation() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        for welcome in [Fixture.welcome(heartbeatSeconds: 40_000_000_000), Fixture.welcome(heartbeatSeconds: 0), Fixture.welcome(maxFrameBytes: 0)] {
            let connection = connect(server)
            let peer = try await server.nextConnection()
            _ = try await peer.nextFrame()
            peer.send(.welcome(welcome))
            do {
                _ = try await withTimeout { try await connection.waitUntilReady() }
                XCTFail("Expected a violation for \(welcome)")
            } catch {
                guard case .protocolViolation? = error as? LatchRemoteClientError else { return XCTFail("\(error)") }
            }
            try await peer.waitForClose()
        }
    }

    /// A server offering frames larger than this client reads does not get to make it buffer them.
    func testALineOverTheClientsOwnLimitIsAViolationWhateverTheWelcomeSays() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello(maxFrameBytes: 1 << 30)
        _ = try await withTimeout { try await connection.waitUntilReady() }
        peer.sendLine(Data(repeating: UInt8(ascii: "a"), count: LatchRemoteProtocol.maxFrameBytes + 1))
        try await peer.waitForClose(timeout: 10)
        guard case .closed(.protocolViolation) = connection.state else { return XCTFail("\(connection.state)") }
    }

    /// Only 127.0.0.1 is tried for `localhost`, as the server listens: whoever holds [::1] at
    /// the same port, such as another local user, never receives the token.
    func testLocalhostIsReachedAtIPv4LoopbackOnly() async throws {
        XCTAssertEqual(LatchRemoteConnection.connectHost(for: "localhost"), "127.0.0.1")
        XCTAssertEqual(LatchRemoteConnection.connectHost(for: "LocalHost."), "127.0.0.1")
        XCTAssertEqual(LatchRemoteConnection.connectHost(for: "::1"), "::1")
        XCTAssertEqual(LatchRemoteConnection.connectHost(for: "vps.example.ts.net"), "vps.example.ts.net")

        let squatter = try await FakeServer.start(host: "::1")
        defer { squatter.stop() }
        let connection = LatchRemoteConnection(options: LatchRemoteConnectionOptions(
            host: "localhost", port: squatter.port, token: Fixture.token, client: Fixture.client, handshakeTimeout: .seconds(3)))
        connection.start()
        defer { connection.close() }
        do {
            _ = try await withTimeout(5) { try await connection.waitUntilReady() }
            XCTFail("Expected a failure")
        } catch {}
        do {
            let peer = try await squatter.nextConnection(timeout: 0.5)
            if let frame = try? await peer.nextFrame(timeout: 0.5) { XCTFail("[::1] received \(frame)") }
        } catch is TestTimeout {}
    }

    func testAWebSocketGoesToTheServersAddressOverTLS() {
        XCTAssertEqual(LatchRemoteConnection.webSocketURL(host: "latch.example.com", port: 443)?.absoluteString, "wss://latch.example.com:443/")
        XCTAssertEqual(LatchRemoteConnection.webSocketURL(host: "::1", port: 8443)?.absoluteString, "wss://[::1]:8443/")
        XCTAssertNil(LatchRemoteConnection.webSocketURL(host: "a b", port: 443))
        XCTAssertEqual(LatchRemoteConnection.userAgent(LatchRemoteClientInfo(name: "Latch", version: "0.3.0", platform: "iOS")),
                       "Latch/0.3.0 (iOS)")
        XCTAssertEqual(LatchRemoteConnection.userAgent(LatchRemoteClientInfo(name: "La tch\r\n", version: "", platform: "mac(OS)")),
                       "Latch/unknown (macOS)")
    }

    /// Only TLS lifts the destination check: a WebSocket without it is checked as TCP is.
    func testAWebSocketWithoutTLSIsCheckedAsTCPIs() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        var options = server.options()
        options.useWebSocketWithoutTLSForTesting()
        options.peerAddressForTesting = [203, 0, 113, 7]
        let connection = connect(server, options: options)
        let peer = try await server.nextConnection()
        try await peer.answerUpgrade()
        let head = peer.byteCount
        do {
            _ = try await withTimeout { try await connection.waitUntilReady() }
            XCTFail("Expected destinationNotAllowed")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .destinationNotAllowed(address: "203.0.113.7"))
        }
        try await peer.waitForClose()
        // At most the close frame followed the upgrade request: no hello, no token.
        XCTAssertLessThanOrEqual(peer.byteCount - head, 8)
    }

    /// A proxy's pings, and their payloads, are not part of the stream.
    func testAWebSocketsControlFramesStayOutOfTheStream() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        var options = server.options()
        options.useWebSocketWithoutTLSForTesting()
        let connection = connect(server, options: options)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.answerUpgrade()
        let welcome = try LatchRemoteCoding.encodeLine(LatchRemoteServerFrame.welcome(Fixture.welcome()))
        // A ping with a payload, the welcome split around a pong, then a text frame.
        peer.sendLine(Data([0x89, 2]) + Data("{x".utf8))
        peer.sendLine(Data([0x82, UInt8(10)]) + welcome.prefix(10))
        peer.sendLine(Data([0x8A, 1]) + Data("}".utf8))
        let rest = welcome.dropFirst(10)
        peer.sendLine(Data([0x82, 126, UInt8(rest.count >> 8), UInt8(rest.count & 0xFF)]) + rest)
        let ready = try await withTimeout { try await connection.waitUntilReady() }
        XCTAssertEqual(ready, Fixture.welcome())
        XCTAssertTrue(LatchRemoteConnection.carriesStream(.cont))
        XCTAssertFalse(LatchRemoteConnection.carriesStream(.close))
    }

    /// A tunnel that cannot reach the server answers the upgrade with an HTTP error, such as
    /// a 502; the token never goes out and the message says where to look.
    func testAProxyThatAnswersWithoutAWebSocketIsNamed() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        var options = server.options()
        options.useWebSocketWithoutTLSForTesting()
        let connection = connect(server, options: options)
        let peer = try await server.nextConnection()
        let head = try await peer.answerUpgrade(status: "502 Bad Gateway")
        XCTAssertTrue(head.contains("User-Agent: LatchTests/1.0 (macOS)"), head)
        do {
            _ = try await withTimeout { try await connection.waitUntilReady() }
            XCTFail("Expected a failure")
        } catch {
            guard case let .connectionFailed(detail)? = error as? LatchRemoteClientError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("not with a WebSocket"), detail)
        }
    }

    func testAllowingAnUnencryptedNetworkSendsTheHelloAnyway() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        var options = server.options()
        options.peerAddressForTesting = [203, 0, 113, 7]
        options.allowUnencryptedNetwork = true
        let connection = connect(server, options: options)
        defer { connection.close() }
        try await server.nextConnection().acceptHello()
        _ = try await withTimeout { try await connection.waitUntilReady() }
    }

    func testCloseIsIdempotentAndFailsPendingRequests() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let states = TestInbox<LatchRemoteConnection.State>("a state")
        let connection = connect(server, states: states)
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        _ = try await connection.waitUntilReady()

        async let pending = withTimeout { try await connection.request(.listRuntimes) }
        _ = try await peer.nextRequest()
        connection.close()
        connection.close()
        do {
            _ = try await pending
            XCTFail("Expected closed")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .closed)
        }
        do {
            _ = try await connection.request(.listRuntimes)
            XCTFail("Expected closed")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .closed)
        }
        try await peer.waitForClose()
        var closedStates = 0
        while let state = try? await states.next(timeout: 0.3) {
            if case .closed = state { closedStates += 1 }
        }
        XCTAssertEqual(closedStates, 1)
    }

    func testTheServerClosingIsALinkFailure() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        _ = try await connection.waitUntilReady()

        async let pending = withTimeout { try await connection.request(.listRuntimes) }
        _ = try await peer.nextRequest()
        peer.drop()
        do {
            _ = try await pending
            XCTFail("Expected a link failure")
        } catch {
            XCTAssertTrue((error as? LatchRemoteClientError)?.isLinkFailure == true, "\(error)")
        }
    }

    func testARefusedConnectionFailsPromptly() async throws {
        let server = try await FakeServer.start()
        let options = server.options()
        server.stop()
        try await Task.sleep(for: .milliseconds(100))

        let connection = LatchRemoteConnection(options: options)
        connection.start()
        do {
            _ = try await withTimeout(3) { try await connection.waitUntilReady() }
            XCTFail("Expected a failure")
        } catch {
            guard case .connectionFailed? = error as? LatchRemoteClientError else { return XCTFail("\(error)") }
        }
    }

    func testCancellingARequestFailsItWithCancellation() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        let connection = connect(server)
        defer { connection.close() }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        _ = try await connection.waitUntilReady()

        let task = Task { try await connection.request(.listRuntimes) }
        let request = try await peer.nextRequest()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // A late reply for the cancelled request is ignored.
        peer.reply(request.id, .runtimes([]))
        async let next = withTimeout { try await connection.request(.detach(runtimeID: Fixture.runtimeID)) }
        peer.reply(try await peer.nextRequest().id, .detached)
        let response = try await next
        XCTAssertEqual(response, .detached)
    }
}

final class LatchRemoteServerCheckTests: XCTestCase {
    func testReturnsTheServerDescription() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        async let info = withTimeout { try await LatchRemoteServerCheck.run(server.options()) }
        let peer = try await server.nextConnection()
        try await peer.acceptHello()
        let result = try await info
        XCTAssertEqual(result, Fixture.server)
        XCTAssertEqual(result.home, "/home/me")
        try await peer.waitForClose()
    }

    func testReportsTheRejection() async throws {
        let server = try await FakeServer.start()
        defer { server.stop() }
        async let info = withTimeout { try await LatchRemoteServerCheck.run(server.options()) }
        let peer = try await server.nextConnection()
        _ = try await peer.nextFrame()
        peer.send(.rejected(LatchRemoteRejected(reason: .unauthorized, message: "Bad token")))
        do {
            _ = try await info
            XCTFail("Expected a rejection")
        } catch {
            XCTAssertEqual(error as? LatchRemoteClientError, .unauthorized(message: "Bad token"))
        }
    }
}
#endif
