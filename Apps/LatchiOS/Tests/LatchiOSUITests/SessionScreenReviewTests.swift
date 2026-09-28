import LatchACP
import LatchRemoteProtocol
import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// The session screen's banner, permission sheet, keyboard and naming, and the list's rows
/// for runtimes and their menus.
@MainActor
final class SessionScreenReviewTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach(Snapshot.tearDown)
        windows = []
        try await super.tearDown()
    }

    private func shown(_ client: ScriptedSessionClient = ScriptedSessionClient()) -> SessionScreenFixture {
        let fixture = SessionScreenFixture(client: client)
        windows.append(Snapshot.host(fixture.screen, appearance: .light))
        return fixture
    }

    // MARK: Banner

    /// Only a failure to act on moves VoiceOver's cursor; reconnecting and a refused photo
    /// are read out and leave it where it was.
    func testOnlyAFailureToActOnTakesVoiceOversFocus() {
        XCTAssertTrue(SessionBanner(key: "a", title: "Can’t connect", severity: .error, actions: []).movesFocus)
        XCTAssertTrue(SessionBanner(key: "b", title: "Stopped", severity: .warning,
                                    actions: [.init(title: "Retry", id: "retry")]).movesFocus)
        XCTAssertFalse(SessionBanner(key: "c", title: "Reconnecting to vps…", severity: .info, isWaiting: true).movesFocus)
        XCTAssertFalse(SessionBanner(key: "d", title: "Can’t receive images", severity: .warning, takesFocus: false).movesFocus)
        XCTAssertFalse(SessionBanner(key: "e", title: "Read-only", severity: .info).movesFocus)
        XCTAssertEqual(SessionBanner.Severity.error.spokenPrefix, "Error: ")
    }

    /// With Retry on the banner, the model's advice to retry is not said again, and the
    /// server's name does not break at its hyphen.
    func testAFailedResumeDoesNotRepeatTheRetryButton() {
        XCTAssertEqual(SessionDetailViewController.withoutRetryAdvice(" Your saved history is unchanged. Retry, or start a new session."), "")
        XCTAssertEqual(SessionDetailViewController.iOSWords("Check that latch-server is running."),
                       "Check that latch\u{2011}server is running.")
    }

    // MARK: Permission

    /// A command is set in monospace, and details that only repeat it are not shown.
    func testACommandRequestIsMonospacedWithoutRepeatingItself() async throws {
        let fixture = shown()
        await fixture.connect()
        fixture.type("Clean")
        fixture.screen.send()
        await waitUntil("the turn") { fixture.client.hasOpenTurn }
        fixture.client.requestPermission(title: "rm -rf .build && swift build", command: "rm -rf .build && swift build")
        await waitUntil("the sheet") { fixture.screen.permissionSheet != nil }
        let sheet = try XCTUnwrap(fixture.screen.permissionSheet)
        sheet.loadViewIfNeeded()
        XCTAssertTrue(sheet.isCommand)
        XCTAssertTrue(sheet.detailsRepeatTitle)
        let title = try XCTUnwrap(sheet.view.allLabels.first { $0.text == "rm -rf .build && swift build" })
        XCTAssertTrue(title.font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let spoken = try XCTUnwrap(title.accessibilityAttributedLabel)
        let command = (spoken.string as NSString).range(of: "rm -rf")
        XCTAssertEqual(spoken.attribute(.accessibilitySpeechPunctuation, at: command.location, effectiveRange: nil) as? Bool, true)
        let explanation = sheet.view.allLabels.first { $0.text?.hasPrefix("“Always”") == true }
        XCTAssertEqual(explanation?.text,
                       "“Always” is remembered by Claude Code, not by Latch. Cancel Request declines only this request; it doesn’t restrict the agent.")
        sheet.finish(nil)
        fixture.client.endTurn()
    }

    // MARK: Keyboard

    /// With suggestions up, the arrows move through them and Return takes the highlighted one;
    /// Escape puts them away until the draft changes.
    func testTheArrowsReturnAndEscapeDriveTheSlashSuggestions() async throws {
        let fixture = shown()
        await fixture.connect()
        fixture.client.availableCommands([("compact", "Summarise"), ("review", "Review the diff"), ("init", "Write a file")])
        await waitUntil("the commands") { fixture.model.commands.count == 3 }
        fixture.type("/")
        let text = fixture.screen.composer.textView
        let keys = Dictionary(uniqueKeysWithValues: (text.keyCommands ?? []).compactMap { key in key.input.map { ($0, key) } })
        let down = try XCTUnwrap(keys[UIKeyCommand.inputDownArrow]?.action)
        let returnKey = try XCTUnwrap(keys["\r"]?.action)
        let escape = try XCTUnwrap(keys[UIKeyCommand.inputEscape]?.action)
        XCTAssertTrue(text.canPerformAction(down, withSender: nil))
        text.perform(down)
        text.perform(down)
        XCTAssertEqual(fixture.screen.suggestions.highlighted?.name, "review")
        text.perform(returnKey)
        XCTAssertEqual(fixture.screen.composer.text, "/review ")
        XCTAssertTrue(fixture.screen.suggestions.isHidden)

        fixture.type("/")
        XCTAssertFalse(fixture.screen.suggestions.isHidden)
        text.perform(escape)
        XCTAssertTrue(fixture.screen.suggestions.isHidden)
        XCTAssertFalse(text.canPerformAction(down, withSender: nil), "Without suggestions the arrows move the cursor")
        fixture.type("/c")
        XCTAssertFalse(fixture.screen.suggestions.isHidden, "A new draft brings them back")
    }

    /// Photos past the fourth are refused, and the banner says why.
    func testMoreThanFourPhotosSaysSo() async throws {
        let fixture = shown()
        await fixture.connect()
        let images = try (0..<5).map {
            try XCTUnwrap(ComposerImage.make(from: SessionDetailViewControllerTests.pngData(width: 40, height: 40), name: "P\($0)"))
        }
        fixture.screen.add(images)
        XCTAssertEqual(fixture.screen.composer.attachments.count, 4)
        XCTAssertEqual(fixture.screen.currentBanner?.title, "You can send up to 4 photos at a time.")
    }

    // MARK: Naming

    func testASessionCanBeRenamedFromItsScreen() async throws {
        let fixture = shown()
        var names: [String] = []
        fixture.screen.context.onRename = { names.append($0) }
        XCTAssertTrue(fixture.screen.navigationItem.renameDelegate === fixture.screen)
        XCTAssertTrue(fixture.screen.navigationItemShouldBeginRenaming(fixture.screen.navigationItem))
        fixture.screen.navigationItem(fixture.screen.navigationItem, didEndRenamingWith: "Flaky test")
        XCTAssertEqual(names, ["Flaky test"])
        XCTAssertTrue(fixture.screen.canPerformAction(#selector(SessionDetailViewController.renameCommand), withSender: nil))
    }

    func testRenamingKeepsTheNameUntilTheNextRename() {
        let session = PhoneSession(serverID: UUID(), path: "/srv", agent: .codex, customCommand: "", connector: FakeConnector())
        session.rename(to: "  Release notes  ")
        XCTAssertEqual(session.title, "Release notes")
        session.rename(to: "   ")
        XCTAssertEqual(session.title, "Release notes", "A blank name changes nothing")
        XCTAssertEqual(session.savedSession.title, "Release notes")
    }

    // MARK: The list

    private func list(runtimes: [LatchRemoteRuntimeSummary]) async -> (SessionsViewController, SessionLibrary, ServerProfile) {
        let vps = Fake.server("vps")
        let library = SessionLibrary(servers: InMemoryServerStore([vps]), connector: FakeConnector(), store: nil,
                                     listRuntimes: { _ in runtimes })
        let list = SessionsViewController(library: library, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        library.onChange = { [weak list] in list?.reload() }
        windows.append(Snapshot.host(list, appearance: .light))
        await library.refreshRuntimes()
        return (list, library, vps)
    }

    /// A decision waiting in "On <server>" shows on the closed group, which opens for it once.
    func testARuntimeWaitingForADecisionOpensItsGroup() async throws {
        let (list, _, vps) = await list(runtimes: [Fake.summary(workspace: "/srv/api", working: true),
                                                   Fake.summary(workspace: "/srv/dotfiles", approvals: 1)])
        let group = SessionsViewController.Item.runtimes(serverID: vps.id)
        let snapshot = list.dataSource.snapshot(for: .server(vps.id))
        XCTAssertTrue(snapshot.isExpanded(group), "Opened for the decision")
        let path = try XCTUnwrap(list.dataSource.indexPath(for: group))
        list.collectionView.layoutIfNeeded()
        let cell = try XCTUnwrap(list.collectionView.cellForItem(at: path) as? UICollectionViewListCell)
        XCTAssertEqual(cell.accessibilityValue, "2 agents, 1 needs approval")
        list.collectionView(list.collectionView, didSelectItemAt: path)
        list.reload(animated: false)
        XCTAssertFalse(list.dataSource.snapshot(for: .server(vps.id)).isExpanded(group), "Closed again, it stays closed")
    }

    func testASessionsMenuGroupsNamingReadingAndLeaving() async throws {
        let (list, library, vps) = await list(runtimes: [])
        let session = library.create(serverID: vps.id, path: "/srv", agent: .codex)
        await waitUntil("the agent to start") { session.canStop }
        list.reload(animated: false)
        var renamed: [UUID] = []
        list.rename = { renamed.append($0.id) }
        let path = try XCTUnwrap(list.dataSource.indexPath(for: .session(session.id)))
        XCTAssertNotNil(list.collectionView(list.collectionView, contextMenuConfigurationForItemsAt: [path], point: .zero))
        let menu = list.menu(for: session)
        let groups = menu.children.compactMap { ($0 as? UIMenu)?.children.compactMap { ($0 as? UIAction)?.title } }
        XCTAssertEqual(groups, [["Rename…", "Copy Path"], ["Mark as Unread"], ["Remove from \(UIDevice.current.model)", "Stop Agent"]])
        ((menu.children[1] as? UIMenu)?.children.first as? UIAction)?.performWithSender(nil, target: nil)
        XCTAssertTrue(session.hasUnseenReply)
        ((menu.children[0] as? UIMenu)?.children.first as? UIAction)?.performWithSender(nil, target: nil)
        XCTAssertEqual(renamed, [session.id])
    }
}

private extension UIView {
    var allLabels: [UILabel] { subviews.compactMap { $0 as? UILabel } + subviews.flatMap(\.allLabels) }
}
