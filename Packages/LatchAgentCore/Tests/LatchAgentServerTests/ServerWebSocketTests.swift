import Foundation
import LatchRemoteProtocol
import XCTest
@testable import LatchAgentServer

/// The WebSocket side of the server's port: the upgrade, the framing, and a proxy on this
/// machine naming the client it forwards for.
final class ServerWebSocketTests: XCTestCase {
    // MARK: Pieces

    func testSHA1AndTheAcceptValueMatchTheirStandards() {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(SHA1.hash([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(SHA1.hash(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        // Two blocks, and a message that ends where the length must start a new block.
        XCTAssertEqual(hex(SHA1.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(hex(SHA1.hash([UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000))),
                       "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
        // RFC 6455 §1.3.
        XCTAssertEqual(ServerWebSocket.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testAnUpgradeIsCheckedHeaderByHeader() throws {
        func head(_ lines: [String]) -> [UInt8] {
            Array(((["GET / HTTP/1.1"] + lines).joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }
        let upgrade = try ServerWebSocket.upgrade(fromHead: head(TestWebSocketReader.upgradeHeaders()))
        XCTAssertEqual(upgrade.accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertNil(try ServerWebSocket.Head(head(TestWebSocketReader.upgradeHeaders())).forwardedFor)

        // Header names and the tokens in them in any case, and lists in Connection.
        let relaxed = [
            "upgrade: WebSocket", "CONNECTION: keep-alive, Upgrade", "sec-websocket-key: \(TestWebSocketReader.key)",
            "Sec-WebSocket-Version:13", "X-Forwarded-For: 198.51.100.7, 203.0.113.9", "x-forwarded-for: [2001:db8::5]",
        ]
        XCTAssertEqual(try ServerWebSocket.upgrade(fromHead: head(relaxed)).accept, upgrade.accept)
        XCTAssertEqual(try ServerWebSocket.Head(head(relaxed)).forwardedFor, [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 11) + [5])
        let mapped = try ServerWebSocket.Head(head(["X-Forwarded-For: ::ffff:203.0.113.9"]))
        XCTAssertEqual(mapped.forwardedFor, [203, 0, 113, 9])
        XCTAssertNil(try ServerWebSocket.Head(head(["X-Forwarded-For: client.example"])).forwardedFor)

        let refused: [([String], ServerWebSocket.Refusal)] = [
            (["Host: h"], .notAnUpgrade),
            (TestWebSocketReader.upgradeHeaders().filter { !$0.hasPrefix("Connection") }, .notAnUpgrade),
            (TestWebSocketReader.upgradeHeaders(adding: ["Origin: https://evil.example"]), .fromAWebPage),
            (TestWebSocketReader.upgradeHeaders().map { $0.hasPrefix("Sec-WebSocket-Version") ? "Sec-WebSocket-Version: 8" : $0 }, .unsupportedVersion),
            (TestWebSocketReader.upgradeHeaders().filter { !$0.hasPrefix("Sec-WebSocket-Key") }, .malformed("no valid Sec-WebSocket-Key")),
            (TestWebSocketReader.upgradeHeaders(adding: ["Sec-WebSocket-Key: AAAA"]), .malformed("no valid Sec-WebSocket-Key")),
            (TestWebSocketReader.upgradeHeaders(adding: ["no colon"]), .malformed("a header line without a colon")),
        ]
        for (lines, refusal) in refused {
            XCTAssertThrowsError(try ServerWebSocket.upgrade(fromHead: head(lines)), "\(lines)") {
                XCTAssertEqual($0 as? ServerWebSocket.Refusal, refusal, "\(lines)")
            }
        }
        for method in ["POST", "HEAD", "OPTIONS"] {
            XCTAssertTrue(ServerWebSocket.beginsRequest(method.utf8.first!))
            XCTAssertThrowsError(try ServerWebSocket.upgrade(fromHead: Array("\(method) / HTTP/1.1\r\n\r\n".utf8))) {
                XCTAssertEqual($0 as? ServerWebSocket.Refusal, .notAnUpgrade)
            }
        }
        XCTAssertFalse(ServerWebSocket.beginsRequest(UInt8(ascii: "{")))
        XCTAssertThrowsError(try ServerWebSocket.upgrade(fromHead: Array("GET /\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? ServerWebSocket.Refusal, .malformed("not an HTTP/1.1 request line"))
        }
    }

    func testFramesDecodeTheSameHoweverTheBytesArrive() throws {
        let first = Data("{\"type\":\"hello\"".utf8)
        let second = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0) })
        let wire = TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodeText, payload: first, fin: false)
            + TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodePing, payload: Data("hi".utf8))
            + TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodeContinuation, payload: Data())
            + TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodeBinary, payload: second, mask: [0, 0xFF, 0x80, 0x7F])
            + TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodePong, payload: Data())
            + TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodeClose, payload: Data([0x03, 0xE8]))
        for pieceSize in [1, 2, 3, 7, 125, 4096, wire.count] {
            var decoder = ServerWebSocket.FrameDecoder()
            var data = Data()
            var controls: [ServerWebSocket.Received] = []
            var start = 0
            while start < wire.count {
                let end = min(start + pieceSize, wire.count)
                for received in try decoder.decode(wire.subdata(in: start..<end)) {
                    if case let .data(payload) = received { data.append(payload) } else { controls.append(received) }
                }
                start = end
            }
            XCTAssertEqual(data, first + second, "pieces of \(pieceSize)")
            XCTAssertEqual(controls, [.ping(Data("hi".utf8)), .close], "pieces of \(pieceSize)")
        }
    }

    func testFramesThatBreakTheStandardAreRefused() {
        func error(_ bytes: [UInt8]) -> ServerWebSocket.FrameError? {
            var decoder = ServerWebSocket.FrameDecoder()
            do {
                _ = try decoder.decode(Data(bytes))
                return nil
            } catch {
                // And from then on.
                XCTAssertThrowsError(try decoder.decode(Data([0x82, 0x80, 0, 0, 0, 0])))
                return error
            }
        }
        XCTAssertEqual(error([0x82, 0x01, 0x41]), .unmasked)
        XCTAssertEqual(error([0xC2, 0x80, 0, 0, 0, 0]), .reservedBits)
        XCTAssertEqual(error([0x83, 0x80, 0, 0, 0, 0]), .unknownOpcode(3))
        XCTAssertEqual(error([0x09, 0x80, 0, 0, 0, 0]), .invalidControlFrame)
        XCTAssertEqual(error([0x89, 0xFE, 0x00, 0x7E, 0, 0, 0, 0]), .invalidControlFrame)
        XCTAssertEqual(error([0x82, 0xFE, 0x00, 0x05, 0, 0, 0, 0]), .invalidLength)
        XCTAssertEqual(error([0x82, 0xFF, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0]), .invalidLength)
        XCTAssertEqual(error([0x82, 0xFF, 0x80, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]), .invalidLength)
        XCTAssertNil(error([0x82, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
    }

    func testTheServerWritesSmallUnmaskedFrames() throws {
        let stream = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        var reader = TestWebSocketReader()
        let frames = ServerWebSocket.binaryFrames(stream)
        XCTAssertEqual(frames.count, stream.count + 4 * 4)
        XCTAssertEqual(try reader.read(frames), stream)
        XCTAssertEqual(try reader.read(ServerWebSocket.binaryFrames(Data())), Data())
        XCTAssertEqual(ServerWebSocket.frame(opcode: ServerWebSocket.opcodePong, payload: Data("hi".utf8)), Data([0x8A, 0x02, 0x68, 0x69]))
    }

    // MARK: On the port

    func testAWebSocketCarriesTheSameProtocolOnTheSamePort() async throws {
        try await withServer { testbed in
            let client = try testbed.connect()
            let response = try await client.upgrade()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"), response)
            XCTAssertTrue(response.contains("\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"), response)

            // The hello split across frames, with a ping between, before authentication.
            let hello = try LatchRemoteCoding.encodeLine(LatchRemoteClientFrame.hello(LatchRemoteHello(
                token: testbed.token.rawValue, client: LatchRemoteClientInfo(name: "test", version: "1", platform: "test")
            )))
            client.send(hello.prefix(10))
            client.sendRaw(TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodePing, payload: Data("early".utf8)))
            client.send(hello.dropFirst(10))
            guard case .welcome = try await client.readFrame() else { return XCTFail("expected a welcome") }
            XCTAssertEqual(client.pongs, [Data("early".utf8)])

            let runtimes = try await client.ok(.listRuntimes)
            XCTAssertEqual(runtimes, .runtimes([]))
            client.sendRaw(TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodePing, payload: Data("late".utf8)))
            client.send(.ping)
            let pong = try await client.readFrame()
            XCTAssertEqual(pong, .pong)
            try await eventually("the late pong") { client.pongs.count == 2 }
            XCTAssertEqual(client.pongs.last, Data("late".utf8))
            try await testbed.waitForLog("from 127.0.0.1:")

            // A close frame ends the connection after what came before it.
            let id = UUID()
            client.sendRaw(
                TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodeBinary, payload: try LatchRemoteCoding.encodeLine(
                    LatchRemoteClientFrame.request(LatchRemoteRequest(id: id, command: .listRuntimes))
                )) + TestWebSocketReader.maskedFrame(opcode: ServerWebSocket.opcodeClose, payload: Data())
            )
            try await testbed.waitForLog("closed: closed by the client")
        }
    }

    func testRequestsThatAreNotUpgradesGetAnHTTPError() async throws {
        try await withServer { testbed in
            let cases: [([String], String)] = [
                (["Host: latch.example.com"], "HTTP/1.1 426 Upgrade Required\r\n"),
                (TestWebSocketReader.upgradeHeaders(adding: ["Origin: https://evil.example"]), "HTTP/1.1 403 Forbidden\r\n"),
                (TestWebSocketReader.upgradeHeaders().filter { !$0.hasPrefix("Sec-WebSocket-Key") }, "HTTP/1.1 400 Bad Request\r\n"),
            ]
            for (headers, status) in cases {
                let client = try testbed.connect()
                let response = try await client.upgrade(headers: headers)
                XCTAssertTrue(response.hasPrefix(status), response)
                XCTAssertTrue(response.contains("\r\nConnection: close\r\n"), response)
                try await client.expectClosed()
            }
            try await testbed.waitForLog("sent a WebSocket upgrade from a web page")

            // A proxy's HEAD check gets an answer too, and its client is named.
            let check = try testbed.connect()
            check.sendRaw(Data("HEAD / HTTP/1.1\r\nHost: latch.example.com\r\nX-Forwarded-For: 198.51.100.4\r\n\r\n".utf8))
            let answer = try await check.readResponseHead()
            XCTAssertTrue(answer.hasPrefix("HTTP/1.1 426 Upgrade Required\r\n"), answer)
            try await testbed.waitForLog("from 198.51.100.4 via 127.0.0.1:")

            // A head that never ends is cut off.
            let endless = try testbed.connect()
            endless.sendRaw(Data(("GET / HTTP/1.1\r\n" + String(repeating: "X-Filler: 0123456789\r\n", count: 1000)).utf8))
            let response = try await endless.readResponseHead()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 431 "), response)
        }
    }

    /// A refusal and a shutdown end the WebSocket with a close frame, after what came before.
    func testTheServerClosesAWebSocketWithACloseFrame() async throws {
        try await withServer { testbed in
            let refused = try testbed.connect()
            _ = try await refused.upgrade()
            refused.hello(token: LatchRemoteToken.generate().rawValue)
            guard case .rejected = try await refused.readFrame() else { return XCTFail("expected a rejection") }
            try await refused.expectClosed()
            XCTAssertEqual(refused.closes, [1008])

            let client = try testbed.connect()
            _ = try await client.upgrade()
            client.hello(token: testbed.token.rawValue)
            guard case .welcome = try await client.readFrame() else { return XCTFail("expected a welcome") }
            await testbed.server.shutdown()
            try await client.expectClosed()
            XCTAssertEqual(client.closes, [1001])
        }
    }

    func testAnIPv6PeerIsCountedByItsSlash64() {
        let first: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 1] + [UInt8](repeating: 7, count: 8)
        let second: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 1] + [UInt8](repeating: 9, count: 8)
        XCTAssertEqual(RemoteServer.peerKey(first), RemoteServer.peerKey(second))
        XCTAssertEqual(RemoteServer.peerKey(first).count, 8)
        XCTAssertEqual(RemoteServer.peerKey([203, 0, 113, 9]), [203, 0, 113, 9])
        XCTAssertEqual(RemoteServer.peerKey([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 203, 0, 113, 9]), [203, 0, 113, 9])
    }

    func testAHeadArrivingAByteAtATimeIsFoundWhereItEnds() {
        let head = Array("GET / HTTP/1.1\r\nHost: h\r\n\r\nrest".utf8)
        var searched = 0
        var found: Int?
        for end in 1...head.count where found == nil {
            found = ServerWebSocket.requestHeadLength(in: Array(head[..<end]), from: searched)
            searched = end
        }
        XCTAssertEqual(found, head.count - 4)
    }

    func testAnUnmaskedFrameClosesTheConnection() async throws {
        try await withServer { testbed in
            let client = try testbed.connect()
            _ = try await client.upgrade()
            client.sendRaw(Data([0x82, 0x01, 0x7B]))
            try await client.expectClosed()
            try await testbed.waitForLog("sent an unmasked frame")
        }
    }

    func testAProxyOnThisMachineNamesTheClientItForwardsFor() async throws {
        try await withServer({ $0.maxUnauthenticatedConnectionsPerPeer = 2 }) { testbed in
            func forwarded(for client: String) async throws -> TestSocketClient {
                let connection = try testbed.connect()
                let response = try await connection.upgrade(headers: TestWebSocketReader.upgradeHeaders(adding: ["X-Forwarded-For: \(client)"]))
                XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 "), response)
                return connection
            }
            // Each client has its own room, not the proxy's.
            let first = try await forwarded(for: "198.51.100.1, 203.0.113.9")
            let second = try await forwarded(for: "203.0.113.9")
            let other = try await forwarded(for: "198.51.100.1")
            let third = try await forwarded(for: "203.0.113.9")
            try await first.expectClosed(timeout: .seconds(3))
            XCTAssertTrue(other.isOpen)
            XCTAssertTrue(second.isOpen)

            third.hello(token: LatchRemoteToken.generate().rawValue)
            guard case .rejected = try await third.readFrame() else { return XCTFail("expected a rejection") }
            try await testbed.waitForLog("from 203.0.113.9 via 127.0.0.1:")
            second.hello(token: testbed.token.rawValue)
            guard case .welcome = try await second.readFrame() else { return XCTFail("expected a welcome") }
            try await testbed.waitForLog("from 203.0.113.9 via 127.0.0.1:")
        }
    }

    func testADeviceThroughAProxyIsNamedAndRevokedLikeAnyOther() async throws {
        try await withServer { testbed in
            let devices = ServerDeviceTokens(configDirectory: testbed.configDirectory)
            let token = try devices.readOrCreate("phone")
            let phone = try testbed.connect()
            let response = try await phone.upgrade(headers: TestWebSocketReader.upgradeHeaders(adding: ["X-Forwarded-For: 203.0.113.9"]))
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 "), response)
            phone.hello(token: token.rawValue)
            guard case .welcome = try await phone.readFrame() else { return XCTFail("expected a welcome") }
            try await testbed.waitForLog("from 203.0.113.9 via 127.0.0.1:")
            try await testbed.waitForLog("authenticated as device phone")
            // The client the proxy named, not the proxy.
            XCTAssertEqual(ServerTokenUse.read(configDirectory: testbed.configDirectory)?.devices["phone"]?.from, "203.0.113.9")

            XCTAssertTrue(try devices.revoke("phone"))
            testbed.server.checkToken()
            try await phone.expectClosed()
            try await testbed.waitForLog("closed: device phone's token is no longer valid")
        }
    }
}
