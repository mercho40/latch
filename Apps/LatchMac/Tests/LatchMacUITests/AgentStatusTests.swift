import LatchAgentCore
import XCTest
@testable import LatchMacUI

final class AgentStatusTests: XCTestCase {
    /// Advice under the command must be true of the state it is shown in: an installed agent is
    /// not told to install itself, and a missing one does not have its problem said twice.
    func testGuidanceMatchesReadiness() {
        let installed = AgentStatus(preset: .fx, command: "fx acp", readiness: .installed(path: "/usr/local/bin/fx"),
                                    setup: "Install fx and sign in with fx login.", signIn: "Sign in with fx login.")
        XCTAssertEqual(installed.guidance, "Sign in with fx login.")
        let missing = AgentStatus(preset: .fx, command: "fx acp",
                                  readiness: .unavailable(problem: "Install fx and sign in with fx login."),
                                  setup: "Install fx and sign in with fx login.", signIn: "Sign in with fx login.")
        XCTAssertNil(missing.guidance)
    }
}
