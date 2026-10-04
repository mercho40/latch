import LatchACP
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// What the agent says about the conversation besides its words: how much of its context is
/// in use, its own title for it, its other options, and the rows and notices it leaves.
@MainActor
final class SessionContextTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach(Snapshot.tearDown)
        windows = []
        try await super.tearDown()
    }

    private func shown(_ client: ScriptedSessionClient = ScriptedSessionClient()) async -> SessionScreenFixture {
        let fixture = SessionScreenFixture(client: client)
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        await fixture.connect()
        return fixture
    }

    // MARK: Context usage

    func testUsageSaysTheShareTheTokensAndTheCost() {
        let english = Locale(identifier: "en_US")
        let quarter = ContextUsageSummary(ContextUsage(used: 50_000, size: 200_000, cost: 0.12, currency: "USD"), locale: english)
        XCTAssertEqual(quarter.short, "25%")
        XCTAssertEqual(quarter.title, "Context 25% full")
        XCTAssertEqual(quarter.details, ["50,000 of 200,000 tokens", "$0.12 so far"])
        XCTAssertEqual(quarter.spoken, "Context 25% full, 50,000 of 200,000 tokens, $0.12 so far")
        XCTAssertFalse(quarter.isHigh)
        let full = ContextUsageSummary(ContextUsage(used: 160_000, size: 200_000), locale: english)
        XCTAssertEqual(full.short, "80%")
        XCTAssertEqual(full.details, ["160,000 of 200,000 tokens"], "No cost until the agent says")
        XCTAssertTrue(full.isHigh, "Amber from 80%, when the agent is about to compact")
        XCTAssertEqual(ContextUsageSummary(ContextUsage(used: 1_000, size: 200_000), locale: english).short, "1%")
        let euros = ContextUsageSummary(ContextUsage(used: 1, size: 2, cost: 3, currency: "EUR"), locale: english)
        XCTAssertEqual(euros.details.last, "€3.00 so far")
    }

    func testTheComposerShowsUsageOnceTheAgentSaysIt() async throws {
        let fixture = await shown()
        let button = fixture.screen.composer.usageButton
        XCTAssertTrue(button.isHidden, "Nothing until the agent says")
        fixture.client.usage(used: 50_000, size: 200_000, cost: 0.12)
        await waitUntil("the usage") { fixture.model.usage != nil }
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.configuration?.title, "25%")
        XCTAssertEqual(button.configuration?.baseForegroundColor, .secondaryLabel)
        let summary = ContextUsageSummary(try XCTUnwrap(fixture.model.usage))
        XCTAssertEqual(button.accessibilityLabel, summary.spoken)
        XCTAssertEqual(button.menu?.title, "Context 25% full")
        XCTAssertEqual(button.menu?.children.compactMap { ($0 as? UIAction)?.title }, summary.details)
        XCTAssertTrue(button.showsMenuAsPrimaryAction)

        fixture.client.usage(used: 170_000, size: 200_000)
        await waitUntil("the new usage") { fixture.model.usage?.used == 170_000 }
        XCTAssertEqual(button.configuration?.title, "85%")
        XCTAssertEqual(button.configuration?.baseForegroundColor, .systemOrange)

        await fixture.model.disconnect()
        await waitUntil("the usage to clear") { button.isHidden }
    }

    // MARK: The agent's other options

    func testTheAgentsOtherOptionsAreInTheMenu() async throws {
        let fixture = await shown(ScriptedSessionClient(configOptions: ScriptedConfiguration.options))
        func fast() throws -> UIMenu {
            let menu = try XCTUnwrap(fixture.screen.menuButton.menu)
            let pickers = (menu.children.first as? UIMenu)?.children.compactMap { $0 as? UIMenu } ?? []
            return try XCTUnwrap(pickers.first { $0.title == "Fast mode" })
        }
        var picker = try fast()
        XCTAssertEqual(picker.subtitle, "Off")
        XCTAssertNotNil(picker.image)
        let choices = picker.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(choices.map(\.title), ["Off", "On"])
        XCTAssertEqual(choices.map(\.state), [.on, .off])
        choices[1].performWithSender(nil, target: nil)
        await waitUntil("the change") {
            fixture.client.commands.contains { if case .setSessionConfigOption(_, "fast_mode", "on") = $0 { true } else { false } }
        }
        await waitUntil("the confirmed value") { fixture.model.configuration.extras.first?.currentValue == "on" }
        picker = try fast()
        XCTAssertEqual(picker.subtitle, "On")
        XCTAssertEqual(picker.children.compactMap { ($0 as? UIAction)?.state }, [.off, .on])
    }

    // MARK: The agent's title

    /// The Mac's rule: the agent's title replaces "New Session", the first prompt's, or one it
    /// gave before; never a name the user chose.
    func testTheAgentsTitleReplacesOnlyATitleNobodyChose() {
        let prompt = ChatMessage(role: .user, text: "The reconnect test fails on Linux\nCan you look?")
        func adopted(_ current: String, _ agent: String?, before: String? = nil) -> String? {
            PhoneSession.adoptedTitle(current: current, agentTitle: agent, firstPrompt: prompt, adoptedBefore: before)
        }
        XCTAssertEqual(adopted(PhoneSession.untitled, "Fix the flaky test"), "Fix the flaky test")
        XCTAssertEqual(adopted("The reconnect test fails on Linux", "Fix the flaky test"), "Fix the flaky test")
        XCTAssertEqual(adopted("Fix the flaky test", "Keep the port across restarts", before: "Fix the flaky test"),
                       "Keep the port across restarts", "A later title replaces the agent's own")
        XCTAssertNil(adopted("Flaky test", "Fix the flaky test"), "A name the user chose stays")
        XCTAssertNil(adopted(PhoneSession.untitled, nil))
        XCTAssertNil(adopted(PhoneSession.untitled, "   "))
        XCTAssertNil(adopted("Fix the flaky test", "Fix the flaky test", before: "Fix the flaky test"))
        XCTAssertEqual(adopted(PhoneSession.untitled, String(repeating: "x", count: 80))?.count, 60)
    }

    func testASessionTakesTheAgentsTitleUntilTheUserNamesIt() async throws {
        let connector = ScriptedConnector()
        let session = PhoneSession(serverID: UUID(), path: "/home/simon/latch", agent: .claudeCode, customCommand: "",
                                   connector: connector)
        session.connect()
        await session.settled()
        let client = try XCTUnwrap(connector.latest)
        let sending = Task { await session.model.send("The reconnect test fails on Linux") }
        await waitUntil("the turn") { client.hasOpenTurn }
        XCTAssertEqual(session.title, "The reconnect test fails on Linux")
        client.title("Fix the flaky reconnect test")
        await waitUntil("the agent's title") { session.title == "Fix the flaky reconnect test" }
        client.title("Keep the port across restarts")
        await waitUntil("its next title") { session.title == "Keep the port across restarts" }
        session.rename(to: "Port reuse")
        client.title("Something else")
        await waitUntil("the title to arrive") { session.model.agentTitle == "Something else" }
        XCTAssertEqual(session.title, "Port reuse", "A name the user chose is never replaced")
        client.endTurn()
        await sending.value
        client.close()
    }

    // MARK: Rows

    func testCompactingHasItsOwnSymbol() {
        let compact = ChatMessage(role: .tool, text: "Compacting conversation · completed",
                                  tool: ToolSummary(callID: "c1", kind: "other", status: "completed", toolName: "compact"))
        XCTAssertEqual(ToolCallPresentation(compact).symbolName, "arrow.down.right.and.arrow.up.left")
        let other = ChatMessage(role: .tool, text: "Compacting conversation · completed",
                                tool: ToolSummary(callID: "c2", kind: "other", status: "completed", toolName: "Bash"))
        XCTAssertNotEqual(ToolCallPresentation(other).symbolName, "arrow.down.right.and.arrow.up.left")
    }

    /// A turn the agent cut short ends with Latch's notice, drawn as a notice rather than as
    /// the agent's words. Fails if the model's wording and the transcript's part.
    func testATurnCutShortEndsWithANotice() async throws {
        let fixture = await shown()
        for reason in ["max_tokens", "max_turn_requests", "refusal"] {
            fixture.type("Go on")
            fixture.screen.send()
            await waitUntil("the turn") { fixture.client.hasOpenTurn }
            fixture.client.chunk("Partly")
            await waitUntil("the reply") { fixture.model.messages.last?.role == .assistant }
            fixture.client.endTurn(stopReason: reason)
            await waitUntil("the turn's end") { fixture.model.phase == .ready }
            let last = try XCTUnwrap(fixture.model.messages.last)
            XCTAssertEqual(TranscriptController.kind(of: last), .notice, "\(reason): \(last.text)")
        }
        XCTAssertEqual(fixture.model.messages.filter { TranscriptController.kind(of: $0) == .notice }.count, 3)
    }

    /// Hunks of a minimal diff, with the unchanged lines between them counted in grey.
    func testADiffsHunksAndWhatLiesBetweenThem() {
        let details = """
            Diff: Sources/Server.swift
            [2 unchanged lines omitted]
            @@ -3,3 +3,3 @@
             let a = 1
            -let b = 2
            +let b = 3
             let c = 4
            [12 unchanged lines omitted]
            @@ -18,2 +18,2 @@
            -return a
            +return b
            """
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let styled = ToolCallPresentation.styledDetails(details, font: font, boldFont: font)
        func color(of line: String) -> UIColor? {
            let range = (styled.string as NSString).range(of: line)
            return styled.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
        }
        XCTAssertEqual(color(of: "[2 unchanged lines omitted]"), .secondaryLabel)
        XCTAssertEqual(color(of: "[12 unchanged lines omitted]"), .secondaryLabel, "Between hunks too")
        XCTAssertEqual(color(of: "@@ -18,2 +18,2 @@"), .secondaryLabel)
        XCTAssertEqual(color(of: "+return b"), .systemGreen, "The second hunk is coloured as the first")
        XCTAssertEqual(color(of: "-let b = 2"), .systemRed)
        XCTAssertEqual(color(of: " let c = 4"), .label)
    }
}
