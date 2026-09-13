import LatchACP
import XCTest
@testable import LatchAgentCore

final class AgentRPCFailureMessageTests: XCTestCase {
    func testPrefersOnlyStringDataMessage() {
        XCTAssertEqual(render("Internal error", data: .object([
            "message": .string("Authentication required"), "stderr": .string("secret"),
        ])), "Agent reported: Authentication required")
        for data: ACPJSONValue in [.object(["message": .string(" \n")]),
                                .object(["message": .object(["detail": .string("secret-nested")])]), .string("secret")] {
            XCTAssertEqual(render("Request rejected", data: data), "Agent reported: Request rejected")
        }
        XCTAssertEqual(render(" \n"), "Agent reported an error.")
    }

    func testRedactsCommonCredentials() {
        for credential in [
            "Authorization: Bearer private-value", "Proxy-Authorization: Basic private-value",
            "Bearer private-value", "Basic private-value", "token=private-value",
            "access_token=private-value", "API_KEY=private-value", "password='private value'",
            "\"apiKey\":\"private-value\"", "client_secret=private-value", "Cookie: private-value",
            "https://user:private-value@example.com/?token=private-value#private-value",
            "sk-private-value", "ghp_private_value", "eyJprivate.payload.signature",
        ] {
            XCTAssertEqual(render("Rejected: " + credential), "Agent reported: Rejected: [redacted]", credential)
        }
    }

    func testBoundsAndNormalizesUntrustedText() {
        let long = render(String(repeating: "x", count: 1_000))
        XCTAssertEqual(long.count, AgentRPCFailureMessage.maximumLength)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(render(String(repeating: "x", count: 16_385)), "Agent reported an error.")
        XCTAssertEqual(render("Try\nagain\u{0000}\u{202E} now"), "Agent reported: Try again now")
        let crossingBoundary = render(String(repeating: "x", count: 470) + " token=" + String(repeating: "s", count: 1_000))
        XCTAssertFalse(crossingBoundary.contains("ssss"))
        XCTAssertLessThanOrEqual(crossingBoundary.count, AgentRPCFailureMessage.maximumLength)
    }

    private func render(_ message: String, data: ACPJSONValue? = nil) -> String {
        AgentRPCFailureMessage.message(for: ACPJSONRPCErrorObject(code: -32603, message: message, data: data))
    }
}
