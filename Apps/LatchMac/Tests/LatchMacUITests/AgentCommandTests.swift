import XCTest
@testable import LatchMacUI

final class AgentCommandTests: XCTestCase {
    func testParsesQuotedArgumentsAndEscapedSpaces() throws {
        let command = try AgentCommand(#"/usr/bin/env agent 'two words' "more words" escaped\ space ''"#)
        XCTAssertEqual(command.executable, "/usr/bin/env")
        XCTAssertEqual(command.arguments, ["agent", "two words", "more words", "escaped space", ""])
    }

    func testDoesNotExpandShellSyntax() throws {
        let command = try AgentCommand("/usr/bin/env $HOME ~ | > $(whoami)")
        XCTAssertEqual(command.arguments, ["$HOME", "~", "|", ">", "$(whoami)"])
    }

    func testRejectsRelativeOrEmptyExecutable() {
        for input in ["", "  ", "agent acp", "''"] {
            XCTAssertThrowsError(try AgentCommand(input))
        }
    }

    func testRejectsUnfinishedQuoting() {
        for input in ["/bin/sh 'abc", "/bin/sh \"abc", "/bin/sh \\"] {
            XCTAssertThrowsError(try AgentCommand(input))
        }
    }
}
