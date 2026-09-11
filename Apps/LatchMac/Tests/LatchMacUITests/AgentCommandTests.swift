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
        for input in ["", "  ", "''", "./agent acp", "bin/agent", "../agent", "~someone/bin/agent"] {
            XCTAssertThrowsError(try AgentCommand(input))
        }
    }

    func testAcceptsNamesAndExplicitHomePaths() throws {
        for executable in ["agent", "~/.local/bin/agent", "~/Application Support/agent"] {
            let command = try AgentCommand(AgentCommand.quotedArgument(executable) + " acp")
            XCTAssertEqual(command.executable, executable)
            XCTAssertEqual(command.arguments, ["acp"])
        }
    }

    func testQuotedArgumentRoundTrip() throws {
        let arguments = ["", "two words", "a\"b", "a\\b\\", "'quoted'", "$HOME", "~", "$(whoami); | >", "line\nbreak\ttab", "日本語"]
        let input = "agent " + arguments.map { AgentCommand.quotedArgument($0) }.joined(separator: " ")
        XCTAssertEqual(try AgentCommand(input).arguments, arguments)
        XCTAssertEqual(AgentCommand.quotedArgument("a\\\"b"), "\"a\\\\\\\"b\"")
    }

    func testRejectsUnfinishedQuoting() {
        for input in ["/bin/sh 'abc", "/bin/sh \"abc", "/bin/sh \\"] {
            XCTAssertThrowsError(try AgentCommand(input))
        }
    }
}
