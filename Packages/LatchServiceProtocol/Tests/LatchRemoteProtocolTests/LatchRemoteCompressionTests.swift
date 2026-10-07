import Foundation
import XCTest
@testable import LatchRemoteProtocol

final class LatchRemoteCompressionTests: XCTestCase {
    /// Lines like the server's events: an envelope that repeats, around a little text.
    private func eventLines(_ count: Int) -> [Data] {
        (0..<count).map { index in
            Data(#"{"event":{"kind":"sessionUpdate","notification":{"sessionId":"019a2c4e-7b3f-7d21-9e44-5f0c8a1b2d3e","update":{"content":{"text":"word \#(index) of the reply ","type":"text"},"sessionUpdate":"agent_message_chunk"}}},"runtimeID":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","sequence":\#(index + 1),"type":"event"}"#.utf8 + [0x0A])
        }
    }

    func testEachWriteCanBeReadInFullAsItArrives() throws {
        let deflater = LatchRemoteDeflater()
        let inflater = LatchRemoteInflater()
        var received = Data()
        var sent = Data()
        for line in eventLines(500) {
            let compressed = try XCTUnwrap(deflater.compress(line))
            sent.append(line)
            // Nothing is held back: what was written is all there once its bytes are in.
            received.append(try inflater.decompress(compressed))
            XCTAssertEqual(received, sent)
        }
    }

    func testTheStreamMaySplitAnywhere() throws {
        let deflater = LatchRemoteDeflater()
        let lines = eventLines(200)
        var compressed = Data()
        for batch in stride(from: 0, to: lines.count, by: 7) {
            compressed.append(try XCTUnwrap(deflater.compress(lines[batch..<min(batch + 7, lines.count)].reduce(Data(), +))))
        }
        let inflater = LatchRemoteInflater()
        var received = Data()
        var offset = 0
        var size = 1
        while offset < compressed.count {
            let end = min(offset + size, compressed.count)
            received.append(try inflater.decompress(compressed[offset..<end]))
            offset = end
            size = size * 3 % 997 + 1
        }
        XCTAssertEqual(received, lines.reduce(Data(), +))
    }

    func testEventsCompressManyTimesOver() throws {
        let deflater = LatchRemoteDeflater()
        let lines = eventLines(1000)
        let raw = lines.reduce(0) { $0 + $1.count }
        // Written as the server writes them, a few at a time.
        var compressed = 0
        for batch in stride(from: 0, to: lines.count, by: 4) {
            compressed += try XCTUnwrap(deflater.compress(lines[batch..<min(batch + 4, lines.count)].reduce(Data(), +))).count
        }
        XCTAssertLessThan(compressed * 5, raw, "\(raw) bytes became \(compressed)")
    }

    func testBytesThatAreNotDeflateOrExpandWithoutEndAreRefused() throws {
        XCTAssertThrowsError(try LatchRemoteInflater().decompress(Data(#"{"type":"pong"}"#.utf8))) {
            XCTAssertEqual($0 as? LatchRemoteInflater.Failure, .corrupt)
        }
        let bomb = try XCTUnwrap(LatchRemoteDeflater(level: 9).compress(Data(repeating: 0x20, count: 4 * 1024 * 1024)))
        XCTAssertLessThan(bomb.count, 64 * 1024)
        XCTAssertThrowsError(try LatchRemoteInflater(limit: 1024 * 1024).decompress(bomb)) {
            XCTAssertEqual($0 as? LatchRemoteInflater.Failure, .tooLarge)
        }
    }
}
