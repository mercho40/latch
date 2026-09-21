import AppKit
import XCTest
@testable import LatchMacUI

/// The Agents pane owns install state and the custom command. Rendering it must never
/// change what it is reporting.
@MainActor
final class AgentsSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults = UserDefaults.standard
    private var settings = AgentSettings(defaults: .standard)

    /// Each test gets its own preference domain: a run must never read or write the
    /// developer's real agent settings.
    private func makeSettings() {
        _ = NSApplication.shared
        suite = "AgentsSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings = AgentSettings(defaults: defaults)
        addTeardownBlock { [suite] in UserDefaults().removePersistentDomain(forName: suite) }
    }

    func testEveryAgentIsOfferedUntilOneIsTurnedOff() {
        makeSettings()
        XCTAssertEqual(settings.enabled, AgentPreset.allCases)
        for preset in AgentPreset.allCases { XCTAssertTrue(settings.isEnabled(preset)) }
        XCTAssertNil(defaults.array(forKey: "LatchDisabledAgents"),
                     "Reading preferences must not write them")
    }

    /// Showing the pane walks every row and writes each agent's state into the switch.
    /// None of that may be mistaken for the user turning an agent off.
    func testShowingThePaneChangesNothing() {
        makeSettings()
        let pane = AgentsSettingsViewController(settings: settings, environment: emptyEnvironment())
        _ = pane.view
        pane.viewWillAppear()
        pane.viewDidAppear()
        for preset in AgentPreset.allCases {
            pane.smokeSelect(preset)
        }
        XCTAssertEqual(settings.enabled, AgentPreset.allCases, "Rendering the pane disabled an agent")
        XCTAssertNil(defaults.array(forKey: "LatchDisabledAgents"))
        XCTAssertEqual(settings.customCommand, "")
        XCTAssertNil(defaults.string(forKey: "LatchCustomAgentCommand"))
    }

    func testTurningAnAgentOffRemovesItFromTheOfferedListAndPersists() {
        makeSettings()
        let pane = AgentsSettingsViewController(settings: settings, environment: emptyEnvironment())
        _ = pane.view
        pane.smokeSelect(.openCode)
        pane.smokeSetEnabled(false)

        XCTAssertFalse(settings.isEnabled(.openCode))
        XCTAssertEqual(settings.enabled, AgentPreset.allCases.filter { $0 != .openCode })
        XCTAssertEqual(defaults.array(forKey: "LatchDisabledAgents") as? [String], ["openCode"])

        // Selecting another row must not carry the previous row's switch state with it.
        pane.smokeSelect(.codex)
        XCTAssertTrue(settings.isEnabled(.codex))
        XCTAssertEqual(defaults.array(forKey: "LatchDisabledAgents") as? [String], ["openCode"])

        pane.smokeSelect(.openCode)
        pane.smokeSetEnabled(true)
        XCTAssertEqual(settings.enabled, AgentPreset.allCases)
    }

    /// A new session starts on the first agent that is both offered and able to start.
    /// Turning agents off has to move that answer, or a session opens on a harness the
    /// user has explicitly stopped offering.
    func testSuggestionSkipsAgentsThatAreTurnedOff() {
        makeSettings()
        let catalog = AgentCatalog(environment: emptyEnvironment())
        // Nothing resolves in this environment, so the filesystem fallback decides.
        XCTAssertEqual(settings.suggested(in: catalog), AgentPreset.suggested(in: catalog.environment))

        let installed = AgentCatalog(environment: nodeEnvironment())
        XCTAssertEqual(settings.suggested(in: installed), .fx, "fx resolves first in this environment")
        settings.setEnabled(false, for: .fx)
        XCTAssertEqual(settings.suggested(in: installed), .codex, "A disabled agent must not be suggested")
        settings.setEnabled(false, for: .codex)
        settings.setEnabled(false, for: .claudeCode)
        settings.setEnabled(false, for: .openCode)
        XCTAssertFalse(settings.enabled.contains(.fx))
    }

    /// Turning agents off is an instruction. A new session must not open on one the user
    /// switched off just because it is the one that happens to be installed.
    func testANewSessionPrefersAnOfferedAgentOverAnInstalledOneThatIsOff() {
        makeSettings()
        let installed = AgentCatalog(environment: nodeEnvironment())
        XCTAssertEqual(settings.suggested(in: installed), .fx)

        // fx is the only agent that resolves here; turning it off must move the suggestion
        // to an offered agent, even though that one cannot start yet.
        settings.setEnabled(false, for: .fx)
        settings.setEnabled(false, for: .codex)
        settings.setEnabled(false, for: .claudeCode)
        XCTAssertEqual(settings.suggested(in: installed), .openCode)
        XCTAssertFalse(installed.status(for: .openCode).readiness.isUsable,
                       "The suggestion is offered but not ready, so the banner has something to say")

        // With nothing offered at all there is no instruction left to honour, so the
        // filesystem decides: fx is the one agent on the path here.
        settings.setEnabled(false, for: .openCode)
        settings.setEnabled(false, for: .custom)
        XCTAssertEqual(settings.suggested(in: installed), .fx)
    }

    /// Being able to start is what decides the suggestion; `.custom` only loses to the
    /// agents Latch knows how to talk about when both are equally ready.
    func testACustomAgentIsSuggestedOnlyWhenItIsTheOneThatCanStart() {
        makeSettings()
        settings.setCustomCommand("/bin/echo acp")

        let nothingElse = AgentCatalog(environment: emptyEnvironment(), customCommand: settings.customCommand)
        XCTAssertTrue(nothingElse.status(for: .custom).readiness.isUsable, "The custom command resolves")
        XCTAssertFalse(nothingElse.status(for: .fx).readiness.isUsable, "Nothing else does")
        XCTAssertEqual(settings.suggested(in: nothingElse), .custom,
                       "A working custom agent beats an offered one that cannot start")

        let fxInstalled = AgentCatalog(environment: nodeEnvironment(), customCommand: settings.customCommand)
        XCTAssertTrue(fxInstalled.status(for: .custom).readiness.isUsable)
        XCTAssertEqual(settings.suggested(in: fxInstalled), .fx,
                       "Both can start, so the agent Latch can report on wins")
    }

    func testASessionKeepsAHarnessThatIsNoLongerOffered() throws {
        makeSettings()
        let workspace = FileManager.default.temporaryDirectory
        let session = SessionViewController(workspace: workspace, launchEnvironment: emptyEnvironment(),
                                            initialAgent: .openCode, settings: settings)
        _ = session.view
        settings.setEnabled(false, for: .openCode)

        let selection = session.harnessSelection
        XCTAssertTrue(selection.rows.contains { $0.preset == .openCode },
                      "A session must keep the harness it is running on")
        XCTAssertEqual(selection.current, .openCode)
        XCTAssertTrue(try XCTUnwrap(selection.rows.first { $0.preset == .openCode }).isCurrent)
    }

    /// fx and Node resolve here, so fx is installed and the npx adapters are reachable.
    /// Nothing is ever launched: discovery only inspects files.
    private func nodeEnvironment() -> AgentLaunchEnvironment {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = home.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["fx", "node", "npx"] {
            let file = bin.appendingPathComponent(name)
            try? Data("Discovery must not execute this file".utf8).write(to: file)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return AgentLaunchEnvironment(environment: ["HOME": home.path, "PATH": bin.path],
                                      home: home, includeCommonLocations: false)
    }

    /// Nothing is installed here, so no selection can launch a process.
    private func emptyEnvironment() -> AgentLaunchEnvironment {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return AgentLaunchEnvironment(environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
                                      home: home, includeCommonLocations: false)
    }

    private func find<T: NSView>(in view: NSView, label: String) -> T? {
        if let control = view as? T, control.accessibilityLabel() == label { return control }
        return view.subviews.lazy.compactMap { self.find(in: $0, label: label) as T? }.first
    }
}

extension AgentsSettingsTests {
    /// The tab controller only titles the window on a selection it makes while it has one.
    @MainActor func testSettingsWindowIsTitledAfterItsPane() {
        let controller = SettingsWindowController(settings: AgentSettings(defaults: UserDefaults(suiteName: "LatchTitle-\(UUID().uuidString)")!))
        XCTAssertEqual(controller.window?.title, "Agents")
    }
}
