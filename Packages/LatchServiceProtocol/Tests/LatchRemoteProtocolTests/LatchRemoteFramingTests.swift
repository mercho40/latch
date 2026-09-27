import Foundation
import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest

final class LatchRemoteFramingTests: XCTestCase {
    func testLinesSplitAcrossChunksAreJoined() throws {
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: 64)
        XCTAssertEqual(try decoder.lines(appending: Data(#"{"type":"#.utf8)), [])
        XCTAssertEqual(try decoder.lines(appending: Data(#""ping"#.utf8)), [])
        XCTAssertEqual(try decoder.lines(appending: Data("\"}\n".utf8)), [Data(#"{"type":"ping"}"#.utf8)])
        XCTAssertEqual(try decoder.lines(appending: Data()), [])
    }

    func testSeveralLinesInOneChunk() throws {
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: 64)
        XCTAssertEqual(try decoder.lines(appending: Data("a\nbb\nccc".utf8)), [Data("a".utf8), Data("bb".utf8)])
        XCTAssertEqual(try decoder.lines(appending: Data("\nd\n".utf8)), [Data("ccc".utf8), Data("d".utf8)])
    }

    func testALineOfExactlyTheLimitIsAccepted() throws {
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: 4)
        XCTAssertEqual(try decoder.lines(appending: Data("abcd".utf8)), [])
        XCTAssertEqual(try decoder.lines(appending: Data("\n".utf8)), [Data("abcd".utf8)])
    }

    func testAnOversizedLineIsFatalBeforeItsNewlineArrives() throws {
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: 4)
        XCTAssertEqual(try decoder.lines(appending: Data("ok\nabc".utf8)), [Data("ok".utf8)])
        XCTAssertThrowsError(try decoder.lines(appending: Data("de".utf8))) {
            XCTAssertEqual($0 as? LatchRemoteFramingError, .lineTooLong(maximumBytes: 4))
        }
        // Never drained and resumed: the connection is done.
        XCTAssertThrowsError(try decoder.lines(appending: Data("\nok\n".utf8)))
    }

    func testAnOversizedCompleteLineIsFatal() {
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: 4)
        XCTAssertThrowsError(try decoder.lines(appending: Data("abcdef\nok\n".utf8))) {
            XCTAssertEqual($0 as? LatchRemoteFramingError, .lineTooLong(maximumBytes: 4))
        }
    }

    func testAnEmptyLineIsAProtocolError() {
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: 16)
        XCTAssertThrowsError(try decoder.lines(appending: Data("ok\n\nok\n".utf8))) {
            XCTAssertEqual($0 as? LatchRemoteFramingError, .emptyLine)
        }
        XCTAssertThrowsError(try decoder.nextLine())
    }

    /// The server reads the hello under the pre-auth limit, then raises it for what follows,
    /// even when both arrived in one chunk.
    func testRaisingTheLimitAppliesToLinesNotYetReturned() throws {
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: 4)
        decoder.append(Data("abc\n0123456789\n".utf8))
        XCTAssertEqual(try decoder.nextLine(), Data("abc".utf8))
        decoder.maximumLineBytes = 16
        XCTAssertEqual(try decoder.nextLine(), Data("0123456789".utf8))
        XCTAssertNil(try decoder.nextLine())
    }

    func testByteAtATimeDelivery() throws {
        let frames = try [LatchRemoteServerFrame.pong, .reply(LatchRemoteReply(id: Sample.frameID, result: .success(.detached)))]
            .map { try LatchRemoteCoding.encodeLine($0) }
        var decoder = LatchRemoteLineDecoder(maximumLineBytes: LatchRemoteProtocol.maxFrameBytes)
        var lines: [Data] = []
        for byte in frames.joined() {
            lines += try decoder.lines(appending: Data([byte]))
        }
        XCTAssertEqual(lines, frames.map { $0.dropLast() })
    }

    func testEncodedFramesAreSingleLines() throws {
        let command = LatchRemoteCommand.prompt(runtimeID: Sample.runtimeID, turnID: Sample.turnID, blocks: [.text("one\ntwo\r\n")])
        let line = try LatchRemoteCoding.encodeLine(LatchRemoteClientFrame.request(LatchRemoteRequest(id: Sample.frameID, command: command)))
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(line.last, 0x0A)
    }

    func testSplicedEventFramesMatchEncodedFrames() throws {
        let events: [LatchRemoteEvent] = [
            .sessionUpdate(notification: Sample.notification),
            .permissionRequested(requestID: Sample.requestID, request: Sample.permission),
            .turnStarted(turnID: Sample.turnID, text: "quote \" and \\ and / and ✓", attachments: []),
            .configurationSet(Sample.configurationSet),
            .exited(LatchRemoteExit(status: nil, stopped: true)),
            .omitted(originalKind: "sessionUpdate", byteCount: 1),
            .unknown(kind: "future"),
        ]
        let ids = [Sample.runtimeID, AgentRuntimeID("A.b_c-9"), AgentRuntimeID(String(repeating: "x", count: 64))]
        for event in events {
            let encodedEvent = try LatchRemoteCoding.encodeEvent(event)
            for runtimeID in ids {
                for sequence: UInt64 in [1, 12_345, .max] {
                    for gap in [false, true] {
                        let frame = LatchRemoteEventFrame(runtimeID: runtimeID, sequence: sequence, event: event, gap: gap)
                        let spliced = LatchRemoteEventFrame.encodedLine(
                            runtimeID: runtimeID, sequence: sequence, gap: gap, encodedEvent: encodedEvent
                        )
                        XCTAssertEqual(spliced, try LatchRemoteCoding.encodeLine(LatchRemoteServerFrame.event(frame)))
                        XCTAssertEqual(try LatchRemoteCoding.decode(LatchRemoteServerFrame.self, fromLine: spliced.dropLast()), .event(frame))
                    }
                }
            }
        }
    }

    func testNegotiation() {
        XCTAssertEqual(LatchRemoteProtocol.negotiate(clientMin: 1, clientMax: 1), 1)
        XCTAssertEqual(LatchRemoteProtocol.negotiate(clientMin: 1, clientMax: 5), 1)
        XCTAssertEqual(LatchRemoteProtocol.negotiate(clientMin: 0, clientMax: 1), 1)
        XCTAssertNil(LatchRemoteProtocol.negotiate(clientMin: 2, clientMax: 5))
        XCTAssertNil(LatchRemoteProtocol.negotiate(clientMin: 0, clientMax: 0))
        XCTAssertNil(LatchRemoteProtocol.negotiate(clientMin: 1, clientMax: 0))
    }

    func testLimits() {
        XCTAssertEqual(LatchRemoteProtocol.maxFrameBytes, 8_454_144)
        XCTAssertEqual(LatchRemoteProtocol.maxEncodedEventBytes, 8 * 1024 * 1024)
        XCTAssertEqual(LatchRemoteProtocol.preAuthMaxLineBytes, 16_384)
        XCTAssertGreaterThanOrEqual(LatchRemoteProtocol.maxEncodedEventBytes, LatchServiceCodec.defaultMaximumPayloadSize)
    }

    func testRuntimeIDValidation() {
        for valid in ["a", "rt-1", "A.b_c-9", "0", String(repeating: "z", count: 64), "8F1C7C6E-3D9A-4B8F-9E0A-2E1C5A7B9D10"] {
            XCTAssertTrue(LatchRemoteProtocol.isValidRuntimeID(valid), valid)
        }
        for invalid in ["", String(repeating: "z", count: 65), "a b", "a/b", "a\"b", "a\\b", "é", "a\n", "a:b", "a+b"] {
            XCTAssertFalse(LatchRemoteProtocol.isValidRuntimeID(invalid), invalid)
        }
    }
}
