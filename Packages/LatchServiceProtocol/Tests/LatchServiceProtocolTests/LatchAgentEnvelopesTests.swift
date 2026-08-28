import Foundation
import LatchACP
import XCTest
@testable import LatchServiceProtocol

final class LatchAgentEnvelopesTests: XCTestCase {
    private let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let runtimeID = AgentRuntimeID("runtime-1")

    func testRequestRoundTripsThroughJSON() throws {
        let request = LatchAgentRequest(
            requestID: requestID,
            command: .prompt(runtimeID: runtimeID, text: "Hello")
        )

        try assertJSONRoundTrip(request)
        XCTAssertEqual(request.protocolVersion, LatchServiceProtocolVersion.current)
    }

    func testSuccessAndFailureRepliesRoundTripThroughJSON() throws {
        let replies = [
            LatchAgentReply(
                requestID: requestID,
                result: .success(.runtimeList([
                    AgentRuntimeSnapshot(id: runtimeID, state: .ready),
                ]))
            ),
            LatchAgentReply(
                requestID: requestID,
                result: .failure(LatchAgentFailure(
                    code: .commandFailed,
                    message: "Runtime not found"
                ))
            ),
        ]

        for reply in replies {
            try assertJSONRoundTrip(reply)
        }
    }

    func testEventEnvelopeRoundTripsThroughJSON() throws {
        let envelope = LatchAgentEventEnvelope(
            sequence: 42,
            event: .processTerminated(runtimeID: runtimeID, status: 7)
        )

        try assertJSONRoundTrip(envelope)
        XCTAssertEqual(envelope.protocolVersion, LatchServiceProtocolVersion.current)
    }

    private func assertJSONRoundTrip<Value: Codable & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(Value.self, from: data), value)
    }
}
