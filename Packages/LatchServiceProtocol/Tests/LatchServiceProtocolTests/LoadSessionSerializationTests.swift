import Foundation
import XCTest
import LatchACP
@testable import LatchServiceProtocol

final class LoadSessionSerializationTests: XCTestCase {
    func testLoadCommandAndResponseEnvelopeRoundTrips() throws {
        let id = AgentRuntimeID("persisted-runtime")
        let request = LatchAgentRequest(command: .loadSession(runtimeID: id, sessionID: "saved-session", cwd: "/tmp/project"))
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(LatchAgentRequest.self, from: data), request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let command = try XCTUnwrap(object["command"] as? [String: Any])
        let load = try XCTUnwrap(command["loadSession"] as? [String: Any])
        XCTAssertEqual(load["sessionID"] as? String, "saved-session")
        XCTAssertEqual(load["cwd"] as? String, "/tmp/project")

        let response = ACPLoadSessionResponse(
            modes: .object(["currentModeId": .string("ask")]),
            models: .object(["currentModelId": .string("model-b")]),
            configOptions: [.object(["id": .string("effort"), "currentValue": .string("high")])],
            meta: .object(["test": .bool(true)]), localSequence: 42
        )
        let reply = LatchAgentReply(requestID: request.requestID, result: .success(.sessionLoaded(runtimeID: id, response: response)))
        let replyData = try JSONEncoder().encode(reply)
        XCTAssertEqual(try JSONDecoder().decode(LatchAgentReply.self, from: replyData), reply)
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        XCTAssertNil(responseObject["sessionId"])
        XCTAssertNotNil(responseObject["_meta"])
        XCTAssertEqual(responseObject["localSequence"] as? Int, 42)
        XCTAssertEqual(try JSONDecoder().decode(ACPLoadSessionResponse.self, from: Data("{}".utf8)), ACPLoadSessionResponse())
    }
}
