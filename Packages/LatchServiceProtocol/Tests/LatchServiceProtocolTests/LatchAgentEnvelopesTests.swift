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

    func testAuthenticationRequiredFailureSerialization() throws {
        let failure = LatchAgentFailure(
            code: .authenticationRequired,
            message: "Agent reported: Not logged in. Please run /login."
        )
        let data = try JSONEncoder().encode(failure)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["code"], "authenticationRequired")
        XCTAssertEqual(object["message"], failure.message)
        XCTAssertEqual(try JSONDecoder().decode(LatchAgentFailure.self, from: data), failure)
        try assertJSONRoundTrip(LatchAgentReply(requestID: requestID, result: .failure(failure)))
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
