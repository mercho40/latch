import AppKit
import XCTest
@testable import LatchMacUI

/// The window's harness control is the only place a session's agent is shown and changed,
/// so it must never report an agent the session is not running on.
///
/// Every window here is built without a store and against an environment where nothing
/// resolves, so no test writes to disk or launches an agent process.
@MainActor
final class HarnessControlTests: XCTestCase {
    private var suite = ""
    private var settings = AgentSettings(defaults: .standard)
    private var root = URL(fileURLWithPath: "/tmp")
    private var windows: [SessionWindowController] = []

    private func makeFixture() {
        _ = NSApplication.shared
        suite = "HarnessControlTests-\(UUID().uuidString)"
        settings = AgentSettings(defaults: UserDefaults(suiteName: suite)!)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [suite, root] in
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeWindow() -> SessionWindowController {
        let window = SessionWindowController(settings: settings)
        windows.append(window)
        return window
    }

    private func cleanUp() async {
        for window in windows {
            await window.shutdown()
            window.close()
        }
        windows.removeAll()
    }

    /// Nothing resolves here, so no selection can launch a process.
    private func environment() -> AgentLaunchEnvironment {
        AgentLaunchEnvironment(environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
                               home: root, includeCommonLocations: false)
    }

    /// What the control reports, read the way it renders: the pull-down's title item and
    /// the row it marks as current.
    private func selectedPreset(in window: SessionWindowController) -> String? {
        window.harnessCheckedAgent
    }

    func testControlReportsTheAgentTheSessionRunsOnNotTheFirstOffered() async {
        makeFixture()
        let window = makeWindow()
        let session = window.addSession(workspace: root, launchEnvironment: environment())
        _ = session.view

        // Every agent is offered, so the session's agent is deliberately not row zero.
        window.chooseHarnessFromToolbar(.claudeCode)

        XCTAssertEqual(session.harnessSelection.current, .claudeCode)
        XCTAssertEqual(selectedPreset(in: window), AgentPreset.claudeCode.rawValue,
                       "The control must show the session's agent, not the first row")
        XCTAssertEqual(window.harnessTitle, AgentPreset.claudeCode.title,
                       "The control's own title must name the session's agent")
        await cleanUp()
    }

    /// Selecting a session in the sidebar rebuilds the menu. The rebuild must land on that
    /// session's agent, not reset to whichever row happens to be first.
    func testSwitchingSessionsShowsEachSessionsOwnAgent() async {
        makeFixture()
        let window = makeWindow()
        let first = window.addSession(workspace: root, launchEnvironment: environment())
        _ = first.view
        window.chooseHarnessFromToolbar(.openCode)

        let second = window.addSession(workspace: root, launchEnvironment: environment())
        _ = second.view
        window.chooseHarnessFromToolbar(.codex)
        XCTAssertEqual(selectedPreset(in: window), AgentPreset.codex.rawValue)

        window.reveal(first.id)
        XCTAssertEqual(selectedPreset(in: window), AgentPreset.openCode.rawValue,
                       "Re-selecting a session must restore its own agent in the control")
        await cleanUp()
    }

    /// The menu ends in a settings entry, which is not an agent. Choosing it must leave the
    /// control reporting the session's agent rather than the entry that was clicked.
    func testChoosingTheSettingsEntryLeavesTheSelectionAlone() async {
        makeFixture()
        let window = makeWindow()
        let session = window.addSession(workspace: root, launchEnvironment: environment())
        _ = session.view
        window.chooseHarnessFromToolbar(.claudeCode)

        let index = window.harnessMenu.numberOfItems - 1
        XCTAssertEqual(window.harnessMenu.items[index].title, "Agent Settings…")
        XCTAssertNil(window.harnessMenu.items[index].representedObject)
        // Through the menu, the way tracking picks an item, not by selecting the row first.
        window.harnessMenu.performActionForItem(at: index)
        XCTAssertEqual(window.harnessTitle, AgentPreset.claudeCode.title)

        XCTAssertEqual(session.harnessSelection.current, .claudeCode, "A settings entry is not a harness")
        XCTAssertEqual(selectedPreset(in: window), AgentPreset.claudeCode.rawValue)
        await cleanUp()
    }

    /// An agent the user stopped offering still has to be representable while a session is
    /// running on it, and it must stay the selected row.
    func testAnAgentThatIsNoLongerOfferedStaysSelectedWhileInUse() async {
        makeFixture()
        let window = makeWindow()
        let session = window.addSession(workspace: root, launchEnvironment: environment())
        _ = session.view
        window.chooseHarnessFromToolbar(.openCode)

        settings.setEnabled(false, for: .openCode)

        XCTAssertEqual(session.harnessSelection.current, .openCode)
        XCTAssertEqual(selectedPreset(in: window), AgentPreset.openCode.rawValue)
        await cleanUp()
    }

    /// The menu must never place a row over the button: the control sits beside the menu
    /// bar, and a select-style pop-up would clip its first agents off the top of the screen.
    func testMenuIsAPullDownSoItAlwaysOpensBelowTheControl() async {
        makeFixture()
        let window = makeWindow()
        let session = window.addSession(workspace: root, launchEnvironment: environment())
        _ = session.view
        window.chooseHarnessFromToolbar(.openCode)

        XCTAssertTrue(window.harnessControl.pullsDown)
        XCTAssertEqual(window.harnessMenu.items.first?.title, AgentPreset.openCode.title)
        XCTAssertNil(window.harnessMenu.items.first?.representedObject,
                     "The title item is the button's own label, not a selectable agent")
        let agents = window.harnessMenu.items.compactMap { $0.representedObject as? String }
        XCTAssertEqual(agents, AgentPreset.allCases.map(\.rawValue),
                       "Every offered agent stays reachable in the list")
        await cleanUp()
    }

    /// Settings and the session both react to a preference change, and the control renders
    /// from the session's scan. It must report the scan taken after the change, not the one
    /// the session was still holding when the notification went out.
    func testSettingACustomCommandUpdatesWhatTheControlReports() async {
        makeFixture()
        let window = makeWindow()
        let session = window.addSession(workspace: root, launchEnvironment: environment())
        _ = session.view
        window.chooseHarnessFromToolbar(.custom)
        XCTAssertEqual(window.harnessControl.toolTip, "No command set yet.")

        settings.setCustomCommand("/bin/echo acp")

        XCTAssertEqual(window.harnessControl.toolTip, "The agent this session runs on",
                       "The control is still reporting the scan from before the command was set")
        let custom = window.harnessMenu.items.first { $0.representedObject as? String == AgentPreset.custom.rawValue }
        XCTAssertEqual(custom?.toolTip, "Installed")
        await cleanUp()
    }

    /// With no session there is nothing to switch, and the control must not offer a stale
    /// agent from the session that was just closed.
    func testControlIsInertWithNoSelectedSession() async {
        makeFixture()
        let window = makeWindow()
        XCTAssertFalse(window.harnessControl.isEnabled)
        XCTAssertNil(selectedPreset(in: window))
        XCTAssertEqual(window.harnessTitle, "Agent")
        await cleanUp()
    }
}
