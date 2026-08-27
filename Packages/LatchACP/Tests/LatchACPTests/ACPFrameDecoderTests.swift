import Foundation
import XCTest
@testable import LatchACP

final class ACPFrameDecoderTests: XCTestCase {
    func testDecodesFragmentedFrame() {
        var decoder = ACPFrameDecoder()

        XCTAssertTrue(decoder.append(Data("{\"jsonrpc\":\"2.0\",".utf8)).isEmpty)
        XCTAssertEqual(
            decoder.append(Data("\"id\":1}\n".utf8)),
            [.frame(Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8))]
        )
    }

    func testDecodesMultipleFramesAndIgnoresEmptyLines() {
        var decoder = ACPFrameDecoder()

        XCTAssertEqual(
            decoder.append(Data("\n{\"id\":1}\n{\"id\":2}\n\n".utf8)),
            [
                .frame(Data("{\"id\":1}".utf8)),
                .frame(Data("{\"id\":2}".utf8)),
            ]
        )
    }

    func testAcceptsFrameAtSizeLimit() {
        var decoder = ACPFrameDecoder(maximumFrameSize: 8)

        XCTAssertTrue(decoder.append(Data("1234".utf8)).isEmpty)
        XCTAssertEqual(
            decoder.append(Data("5678\n".utf8)),
            [.frame(Data("12345678".utf8))]
        )
    }

    func testDrainsOversizedFrameAndRecovers() {
        var decoder = ACPFrameDecoder(maximumFrameSize: 8)

        XCTAssertEqual(decoder.append(Data("123456789".utf8)), [.oversizedFrame])
        XCTAssertEqual(
            decoder.append(Data(" ignored\n{\"id\":2}\n".utf8)),
            [.frame(Data("{\"id\":2}".utf8))]
        )
    }

    func testReportsCompleteOversizedFrameOnce() {
        var decoder = ACPFrameDecoder(maximumFrameSize: 8)

        XCTAssertEqual(
            decoder.append(Data("123456789\n{\"id\":2}\n".utf8)),
            [
                .oversizedFrame,
                .frame(Data("{\"id\":2}".utf8)),
            ]
        )
    }
}
