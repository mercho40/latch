import LatchSessionKit
import UIKit
import XCTest
@testable import LatchiOSUI

/// Renders the session screen's states to `/tmp/latch-ios-session` for design review, in
/// light, dark and an accessibility text size, on whichever device runs the tests. Run on an
/// iPhone and an iPad to see both. Skipped unless `LATCH_SNAPSHOTS` is set.
@MainActor
final class SessionSnapshotTests: XCTestCase {
    private static let task = "session"

    override func setUp() async throws {
        try Snapshot.skipUnlessEnabled()
    }

    private func render(_ name: String, holdLaunch: Bool = false, appearances: [Snapshot.Appearance] = Snapshot.Appearance.all,
                        _ scene: (SessionScreenFixture) async throws -> Void) async throws {
        for appearance in appearances {
            let fixture = SessionScreenFixture(client: ScriptedSessionClient(configOptions: ScriptedConfiguration.options,
                                                                             holdLaunch: holdLaunch))
            let window = Snapshot.host(fixture.screen, appearance: appearance)
            try await scene(fixture)
            try await Snapshot.write(window, task: Self.task, name: name, appearance: appearance)
            fixture.client.endTurn()
            fixture.client.releaseLaunch()
            Snapshot.tearDown(window)
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testConversation() async throws {
        try await render("conversation") { fixture in
            await fixture.resume(SampleConversation.messages)
            await waitUntil { fixture.transcript.order.count == SampleConversation.messages.count }
            fixture.transcript.scrollToBottom(animated: false)
        }
    }

    func testConversationWithMarkdownFromTheTop() async throws {
        try await render("markdown") { fixture in
            await fixture.resume([SampleConversation.prompt, SampleConversation.answer])
            await waitUntil { fixture.transcript.order.count == 2 }
            try await Task.sleep(for: .milliseconds(200))
            let collection = fixture.transcript.collectionView
            collection.setContentOffset(CGPoint(x: 0, y: -collection.adjustedContentInset.top), animated: false)
            fixture.transcript.scrollViewDidEndDragging(collection, willDecelerate: false)
        }
    }

    func testToolCallExpanded() async throws {
        try await render("tool-expanded") { fixture in
            await fixture.resume([SampleConversation.prompt, SampleConversation.read, SampleConversation.run])
            await waitUntil { fixture.transcript.order.count == 3 }
            fixture.cell(for: SampleConversation.run.id, as: ToolCallCell.self)?.header.sendActions(for: .primaryActionTriggered)
            fixture.cell(for: SampleConversation.read.id, as: ToolCallCell.self)?.header.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(300))
            fixture.transcript.scrollToBottom(animated: false)
        }
    }

    func testStreamingTurn() async throws {
        try await render("streaming", appearances: Snapshot.Appearance.all + [.largest]) { fixture in
            await fixture.resume([SampleConversation.prompt, SampleConversation.read])
            fixture.type("Now fix it, and run the test ten times to be sure.")
            fixture.screen.send()
            await waitUntil { fixture.client.hasOpenTurn }
            fixture.client.tool("edit", title: "Edit Tests/RemoteSessionLiveTests.swift", status: "completed")
            fixture.client.tool("run", title: "`swift test --filter RemoteSessionLiveTests`", status: "in_progress")
            fixture.client.chunk("I changed the restart to keep its port. Running the test ten times now; so far ")
            fixture.client.chunk("**7 of 10** passed without a retry, and")
            await waitUntil { fixture.model.messages.count == 6 }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    func testComposerWithPhotos() async throws {
        try await render("composer-photos") { fixture in
            await fixture.connect()
            let images = (0..<3).compactMap { index in
                ComposerImage.make(from: SessionDetailViewControllerTests.pngData(width: 400 + index * 100, height: 300),
                                   name: "Screenshot \(index + 1)")
            }
            fixture.screen.add(images)
            fixture.type("What is wrong with these three screens? The spacing looks off on the second.")
        }
    }

    func testSlashSuggestions() async throws {
        try await render("slash") { fixture in
            await fixture.connect()
            fixture.client.availableCommands([("compact", "Summarise the conversation to free up context"),
                                              ("review", "Review the current diff"), ("init", "Write a CLAUDE.md for this repository"),
                                              ("cost", "Show what this session has cost")])
            await waitUntil { fixture.model.commands.count == 4 }
            fixture.screen.composer.textView.becomeFirstResponder()
            fixture.type("/")
        }
    }

    /// The sheet as it sits over the session at the height that fits it and at its largest.
    /// The test host never finishes a sheet's transition, so the sheet's own view is placed
    /// where UIKit puts it.
    func testPermissionSheet() async throws {
        for detent in ["fit", "large"] {
            for appearance in Snapshot.Appearance.all + [.largest] {
                let fixture = SessionScreenFixture()
                let window = Snapshot.host(fixture.screen, appearance: appearance)
                await fixture.resume([SampleConversation.prompt])
                fixture.type("Clean the build folder and rebuild")
                fixture.screen.send()
                await waitUntil { fixture.client.hasOpenTurn }
                fixture.client.requestPermission(title: "rm -rf .build && swift build", command: "rm -rf .build && swift build")
                await waitUntil { fixture.screen.permissionSheet != nil }
                let sheet = try XCTUnwrap(fixture.screen.permissionSheet)
                let dim = UIView(frame: window.bounds)
                dim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
                window.addSubview(dim)
                sheet.traitOverrides.preferredContentSizeCategory = appearance.size
                let largest = window.bounds.height - window.safeAreaInsets.top - 10
                sheet.view.frame = CGRect(x: 0, y: window.bounds.height - largest, width: window.bounds.width, height: largest)
                window.addSubview(sheet.view)
                sheet.view.layoutIfNeeded()
                sheet.view.layoutIfNeeded()
                if detent == "fit" {
                    let height = min(largest, sheet.fittingHeight + window.safeAreaInsets.bottom)
                    sheet.view.frame = CGRect(x: 0, y: window.bounds.height - height, width: window.bounds.width, height: height)
                }
                sheet.view.layer.cornerRadius = 38
                sheet.view.layer.cornerCurve = .continuous
                sheet.view.clipsToBounds = true
                try await Snapshot.write(window, task: Self.task, name: "permission-\(detent)", appearance: appearance)
                sheet.view.removeFromSuperview()
                fixture.client.endTurn()
                Snapshot.tearDown(window)
            }
        }
    }

    func testReconnectingBanner() async throws {
        try await render("reconnecting") { fixture in
            await fixture.resume([SampleConversation.prompt, SampleConversation.read])
            fixture.type("Keep going")
            fixture.screen.send()
            await waitUntil { fixture.client.hasOpenTurn }
            fixture.client.chunk("Working through the remaining failures")
            fixture.client.emit(.link(.reconnecting(server: "vps", since: Date())))
            await waitUntil { fixture.screen.banner.isShowing }
        }
    }

    func testErrorBanner() async throws {
        try await render("error") { fixture in
            fixture.client.failNextLaunch(with: UnreachableServer(
                message: "vps refused the connection at vps.example.com:7800. Check that latch-server is running."))
            await fixture.connect()
            await waitUntil { fixture.screen.banner.isShowing }
        }
    }

    func testConnecting() async throws {
        try await render("connecting", holdLaunch: true) { fixture in
            Task { await fixture.connect() }
            await waitUntil { fixture.model.phase == .connecting }
        }
    }

    func testReadyAndEmpty() async throws {
        try await render("empty") { fixture in
            await fixture.connect()
        }
    }
}
