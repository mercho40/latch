import LatchACP
import XCTest
@testable import LatchMacUI

final class SlashCommandMenuTests: XCTestCase {
    private let commands = [
        ACPAvailableCommand(name: "review", description: "Review the current changes"),
        ACPAvailableCommand(name: "compact", description: "Summarise the conversation so far"),
        ACPAvailableCommand(name: "pr-comments", description: "Read the comments on a pull request"),
        ACPAvailableCommand(name: "init", description: "Write an AGENTS.md for this workspace"),
    ]

    func testAnEmptyQueryKeepsTheAgentsOrder() {
        XCTAssertEqual(SlashCommandMenu.filter(commands, query: "").map(\.name), ["review", "compact", "pr-comments", "init"])
    }

    func testNamePrefixesComeBeforeNameMatchesAndDescriptions() {
        // "com": compact by prefix, pr-comments inside its name, then nothing by description.
        XCTAssertEqual(SlashCommandMenu.filter(commands, query: "com").map(\.name), ["compact", "pr-comments"])
        // "re": review by prefix, then pr-comments only through its description.
        XCTAssertEqual(SlashCommandMenu.filter(commands, query: "re").map(\.name), ["review", "pr-comments"])
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(SlashCommandMenu.filter(commands, query: "AGENTS").map(\.name), ["init"])
        XCTAssertEqual(SlashCommandMenu.filter(commands, query: "Rev").map(\.name), ["review"])
    }

    func testNoMatchLeavesNothingToShow() {
        XCTAssertTrue(SlashCommandMenu.filter(commands, query: "zzz").isEmpty)
    }
}
