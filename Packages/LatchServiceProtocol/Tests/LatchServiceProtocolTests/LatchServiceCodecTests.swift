import Foundation
import XCTest
@testable import LatchServiceProtocol

final class LatchServiceCodecTests: XCTestCase {
    func testRoundTripsServiceEnvelopes() throws {
        let codec = LatchServiceCodec()
        let request = LatchAgentRequest(command: .listRuntimes)
        let reply = LatchAgentReply(
            requestID: request.requestID,
            result: .success(.runtimeList([]))
        )
        let event = LatchAgentEventEnvelope(
            sequence: 1,
            event: .processTerminated(runtimeID: AgentRuntimeID("runtime-1"), status: 7)
        )

        XCTAssertEqual(try codec.decode(LatchAgentRequest.self, from: codec.encode(request)), request)
        XCTAssertEqual(try codec.decode(LatchAgentReply.self, from: codec.encode(reply)), reply)
        XCTAssertEqual(try codec.decode(LatchAgentEventEnvelope.self, from: codec.encode(event)), event)
    }

    func testRejectsEmptyPayload() {
        XCTAssertThrowsError(try LatchServiceCodec().decode(LatchAgentRequest.self, from: Data())) {
            XCTAssertEqual($0 as? LatchServiceCodecError, .emptyPayload)
        }
    }

    func testRejectsMalformedJSONAndWrongShape() {
        for payload in ["not JSON", "{}", "null", "[]"] {
            XCTAssertThrowsError(
                try LatchServiceCodec().decode(LatchAgentRequest.self, from: Data(payload.utf8))
            ) {
                XCTAssertEqual($0 as? LatchServiceCodecError, .malformedPayload)
            }
        }
    }

    func testAcceptsExactByteLimitAndRejectsOversizedEncodingAndDecoding() throws {
        let value = "é"
        let data = try LatchServiceCodec().encode(value)
        XCTAssertEqual(data.count, 4)
        let exactCodec = LatchServiceCodec(maximumPayloadSize: data.count)
        XCTAssertEqual(try exactCodec.encode(value), data)
        XCTAssertEqual(try exactCodec.decode(String.self, from: data), value)

        let smallCodec = LatchServiceCodec(maximumPayloadSize: data.count - 1)
        let expected = LatchServiceCodecError.payloadTooLarge(
            maximumBytes: data.count - 1,
            actualBytes: data.count
        )
        XCTAssertThrowsError(try smallCodec.encode(value)) {
            XCTAssertEqual($0 as? LatchServiceCodecError, expected)
        }
        XCTAssertThrowsError(try smallCodec.decode(String.self, from: data)) {
            XCTAssertEqual($0 as? LatchServiceCodecError, expected)
        }
    }

    func testChecksSizeBeforeDecodingMalformedPayload() {
        let codec = LatchServiceCodec(maximumPayloadSize: 3)
        XCTAssertThrowsError(try codec.decode(LatchAgentRequest.self, from: Data("oops".utf8))) {
            XCTAssertEqual(
                $0 as? LatchServiceCodecError,
                .payloadTooLarge(maximumBytes: 3, actualBytes: 4)
            )
        }
    }
}
