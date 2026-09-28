import LatchACP
import LatchSessionKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// What the session screen shows about its session besides the model, and what it asks of
/// whoever hosts it. The screen never connects, stops or saves anything itself: those go
/// through these closures, so the host keeps the session's lifecycle in one place.
@MainActor
struct SessionDetailContext {
    /// The session's title, from its first prompt.
    var title: String
    /// The server's name as the Servers list has it now.
    var serverName: String
    /// The folder on the server, whole: Copy Path copies it and VoiceOver reads it.
    var folderPath: String
    /// The folder as the reader should see it, with the server's home as `~`, such as
    /// `~/project`: the subtitle and the empty page show it. The whole path until the home is known.
    var displayPath = ""
    /// The agent's name, such as "Claude Code".
    var agentTitle: String
    /// The draft the composer starts with.
    var draft = ""
    /// Retry after a failure, or connect a session that is not connected.
    var onRetry: () -> Void = {}
    /// Stop the agent on its server; the user has already confirmed.
    var onStopAgent: () -> Void = {}
    /// Open the Servers settings on this session's server.
    var onServerSettings: () -> Void = {}
    /// The draft changed, to be saved with the session. Empty once a draft is sent.
    var onDraftChange: (String) -> Void = { _ in }
    /// Whether Stop Agent has a runtime to stop, when the host knows better than the model,
    /// such as while an adoption is still attaching.
    var canStopAgent: (() -> Bool)?
    /// Stop Agent was chosen for this session, and nothing has connected since.
    var isStopped: () -> Bool = { false }
    /// Whether the session's server is still in Servers, so its settings can be opened and
    /// its agent started again.
    var hasServer: () -> Bool = { true }
    /// The user named the session.
    var onRename: ((String) -> Void)?

    /// The folder to show: `displayPath`, or the whole path while there is none.
    var shownPath: String { displayPath.isEmpty ? folderPath : displayPath }
}

/// One session: its conversation, a composer pinned above the keyboard, a banner for the
/// link and failures, the agent's permission requests as sheets, and a menu for the
/// agent's settings. It drops into the split view's secondary column.
///
/// The host owns `model.onChange` and `model.onTranscriptChange`, because it needs them
/// while no session screen is open, and passes each on to the screen that shows the model:
///
///     model.onChange = { [weak screen] in screen?.modelDidChange() }
///     model.onTranscriptChange = { [weak screen] in screen?.transcriptDidChange() }
final class SessionDetailViewController: UIViewController, PHPickerViewControllerDelegate, UINavigationItemRenameDelegate,
    UIDropInteractionDelegate {
    let model: SessionModel
    var context: SessionDetailContext {
        didSet { contextChanged() }
    }

    let transcript = TranscriptController()
    let composer = SessionComposerView()
    let banner = SessionStatusBannerView()
    let suggestions = SlashCommandSuggestionsView()
    let jumpButton = UIButton(type: .system)
    private let emptyView = UIContentUnavailableView(configuration: .empty())
    private let composerBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private(set) var menuButton: UIBarButtonItem!
    private var renderedMenu: MenuState?
    private lazy var renderScheduler = TranscriptRenderScheduler(wait: {
        try await Task.sleep(for: .milliseconds(50))
    }, render: { [weak self] in self?.renderTranscript() })
    private(set) var attachments: [ComposerImage] = []
    /// A refused photo, said once in the banner until the draft changes.
    private var attachmentNotice: (id: UUID, title: String, message: String)?
    private var announcedTurns: Int
    /// The permission sheet on screen, or on its way on or off.
    private(set) var permissionSheet: PermissionRequestViewController?
    private var permissionTransition = false
    /// A look again soon, while something else on screen keeps the sheet from showing.
    private var permissionRetry: Task<Void, Never>?
    /// How much of the page's end the composer covers.
    private var composerOverlap: CGFloat = 0
    /// How the permission sheet comes and goes, each calling back when its transition ends.
    /// Tests replace them: a test host never finishes a sheet's transition.
    lazy var presentSheet: (UIViewController, @escaping () -> Void) -> Void = { [weak self] sheet, done in
        self?.topPresenter.present(sheet, animated: true, completion: done)
    }
    lazy var dismissSheet: (UIViewController, @escaping () -> Void) -> Void = { sheet, done in
        sheet.dismiss(animated: true, completion: done)
    }
    /// Copy Path writes here. Tests substitute a pasteboard of their own.
    var pasteboard = UIPasteboard.general
    /// Keeps the photos sent from here, so a prompt shows them rather than their names.
    var sentImages = SentImageCache.shared
    /// Thumbnails of the last prompt sent, until the transcript shows the message they went with.
    private var pendingThumbnails: (names: [String], images: [UIImage?], after: Set<UUID>)?
    /// Opened from New Session: the composer takes the keyboard once the screen is up.
    private var focusesComposer = false
    /// The slash suggestions were dismissed with Escape, until the draft changes.
    private var suggestionsDismissed = false

    init(model: SessionModel, context: SessionDetailContext) {
        self.model = model
        self.context = context
        announcedTurns = model.turnsEnded
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.renameDelegate = self
        navigationItem.titleMenuProvider = { [weak self] suggested in self?.titleMenu(suggested) }
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The model's state changed: phase, link, permissions, configuration or an error.
    func modelDidChange() { refresh() }

    /// The transcript changed. Coalesced, so a streaming reply renders at most every 50 ms.
    func transcriptDidChange() { renderScheduler.request() }

    /// Puts the keyboard in the composer when the screen next appears, as after New Session.
    func focusComposerOnAppear() {
        focusesComposer = true
        if viewIfLoaded?.window != nil { focusComposer() }
    }

    private func focusComposer() {
        focusesComposer = false
        guard composer.isEditable else { return }
        // VoiceOver moves its cursor to the field instead of raising a keyboard over the page.
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .screenChanged, argument: composer.textView)
        } else {
            composer.textView.becomeFirstResponder()
        }
    }

    // MARK: Building

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        transcript.agentTitle = context.agentTitle
        transcript.sentImages = sentImages
        let collection = transcript.collectionView
        collection.backgroundView = emptyView
        transcript.onScroll = { [weak self] in self?.refreshJumpButton() }

        // Bar buttons sit in a glass capsule from iOS 26, which is the circle.
        let menuSymbol = if #available(iOS 26.0, *) { "ellipsis" } else { "ellipsis.circle" }
        menuButton = UIBarButtonItem(image: UIImage(systemName: menuSymbol), menu: nil)
        menuButton.accessibilityLabel = "Session Options"
        navigationItem.rightBarButtonItem = menuButton

        composer.text = context.draft
        composer.directionalLayoutMargins = .init(top: 8, leading: 0, bottom: 8, trailing: 0)
        composer.onTextChange = { [weak self] text in
            guard let self else { return }
            attachmentNotice = nil
            suggestionsDismissed = false
            context.onDraftChange(text)
            // A keystroke changes what the composer offers, never the conversation.
            banner.show(currentBanner)
            refreshComposer()
        }
        composer.onSend = { [weak self] in self?.send() }
        composer.onStop = { [weak self] in self?.stop() }
        composer.onAttach = { [weak self] in self?.chooseImages() }
        composer.onRemoveAttachment = { [weak self] id in self?.removeAttachment(id) }
        composer.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
        composer.onPasteImages = { [weak self] providers in self?.load(providers) }
        composer.canHandleKey = { [weak self] key in self?.canHandle(key) ?? false }
        composer.onKey = { [weak self] key in self?.handle(key) }
        suggestions.onChoose = { [weak self] command in self?.choose(command) }
        suggestions.isHidden = true
        banner.onAction = { [weak self] id in self?.bannerAction(id) }
        banner.onLayoutChange = { [weak self] in self?.view.setNeedsLayout() }
        banner.directionalLayoutMargins = .zero

        var jump: UIButton.Configuration
        if #available(iOS 26.0, *) {
            jump = .glass()
        } else {
            jump = .gray()
            jump.background.visualEffect = UIBlurEffect(style: .systemThickMaterial)
        }
        jump.image = UIImage(systemName: "arrow.down")
        jump.preferredSymbolConfigurationForImage = .init(pointSize: 15, weight: .semibold)
        jump.cornerStyle = .capsule
        jump.baseForegroundColor = .label
        jumpButton.configuration = jump
        jumpButton.accessibilityLabel = "Jump to Latest"
        jumpButton.showsLargeContentViewer = true
        jumpButton.largeContentTitle = "Jump to Latest"
        jumpButton.addAction(UIAction { [weak self] _ in self?.transcript.scrollToBottom(animated: true) }, for: .primaryActionTriggered)
        jumpButton.isPointerInteractionEnabled = true
        jumpButton.alpha = 0
        jumpButton.isHidden = true

        let hasGlass: Bool = if #available(iOS 26.0, *) { true } else { false }
        composerBar.isHidden = hasGlass
        for subview in [collection, composerBar, banner, composer, suggestions, jumpButton] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.readableContentGuide
        // The banner, composer and suggestions run the conversation's column: the readable
        // width, no wider than the transcript's cap, centred.
        for column in [banner, composer, suggestions] as [UIView] {
            let leading = column.leadingAnchor.constraint(equalTo: guide.leadingAnchor)
            let trailing = column.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
            leading.priority = .defaultHigh
            trailing.priority = .defaultHigh
            NSLayoutConstraint.activate([
                leading, trailing,
                column.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),
                column.widthAnchor.constraint(lessThanOrEqualToConstant: TranscriptController.maximumColumnWidth),
                column.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.topAnchor.constraint(equalTo: view.topAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            composer.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor),
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBar.topAnchor.constraint(equalTo: composer.topAnchor),
            composerBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            suggestions.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -2),
            jumpButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10),
            jumpButton.widthAnchor.constraint(equalToConstant: 44),
            jumpButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // The navigation bar's edge follows the conversation, which is not this view.
        setContentScrollView(collection, for: .top)
        if #available(iOS 26.0, *) {
            // The page's soft edges run under what floats over it: the composer at the bottom,
            // and the banner at the top, so nothing scrolled under the bar peeks round the card.
            collection.topEdgeEffect.style = .soft
            for (floating, edge) in [(composer, UIRectEdge.bottom), (banner, .top)] as [(UIView, UIRectEdge)] {
                let interaction = UIScrollEdgeElementContainerInteraction()
                interaction.scrollView = collection
                interaction.edge = edge
                floating.addInteraction(interaction)
            }
        }
        // Photos dropped anywhere on the page go in the composer, as the Mac's window takes them.
        view.addInteraction(UIDropInteraction(delegate: self))
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: SessionDetailViewController, _) in
            controller.renderedMenu = nil
            controller.refresh()
        }
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let collection = transcript.collectionView
        // The composer floats over the end of the conversation and the banner over its start;
        // the transcript makes room for both.
        let bottom = max(0, view.bounds.maxY - composer.frame.minY - view.safeAreaInsets.bottom)
        let top = banner.isShowing ? banner.frame.height : 0
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if collection.contentInset != insets {
            transcript.autoScroll {
                collection.contentInset = insets
                collection.verticalScrollIndicatorInsets = insets
            }
        }
        // The conversation runs the composer's column, in the content's coordinates.
        if composer.frame.width > 0 {
            let column = collection.convert(composer.frame, from: view)
            let width = collection.bounds.width - collection.adjustedContentInset.left - collection.adjustedContentInset.right
            transcript.collectionView.column = (column.minX.rounded(), (width - column.maxX).rounded())
        }
        if abs(composerOverlap - bottom) > 0.5 {
            composerOverlap = bottom
            refreshEmptyState()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A request that arrived while another session was on screen waits for this one.
        refresh()
        if focusesComposer, presentedViewController == nil { focusComposer() }
    }

    // MARK: Refreshing

    private func contextChanged() {
        refreshTitle()
        guard isViewLoaded else { return }
        transcript.agentTitle = context.agentTitle
        renderedMenu = nil
        refresh()
    }

    private func refreshTitle() {
        title = context.title
        let subtitle = [context.serverName, context.shownPath].filter { !$0.isEmpty }.joined(separator: " · ")
        if #available(iOS 26.0, *) {
            navigationItem.subtitle = subtitle
        } else {
            let spoken = [context.serverName, context.folderPath].filter { !$0.isEmpty }.joined(separator: ", ")
            // The system draws its title menu only for its own title, so this one carries it,
            // with Rename… in place of renaming in the bar.
            let rename = UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.beginRenaming() }
            let menu = UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.titleMenu(self?.context.onRename == nil ? [] : [rename])?.children ?? [])
            }
            navigationItem.titleView = SessionTitleView(title: context.title, subtitle: subtitle, spoken: spoken,
                                                        menu: UIMenu(children: [menu]))
        }
    }

    // MARK: Renaming

    /// Tapping the title offers Rename, and what the session menu offers about the folder.
    private func titleMenu(_ suggested: [UIMenuElement]) -> UIMenu? {
        let copyPath = UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc"),
                                attributes: context.folderPath.isEmpty ? .disabled : []) { [weak self] _ in self?.copyPath() }
        var items = suggested
        items.append(copyPath)
        if context.hasServer() {
            items.append(UIAction(title: "Server Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.context.onServerSettings()
            })
        }
        return UIMenu(children: items)
    }

    func navigationItem(_ navigationItem: UINavigationItem, didEndRenamingWith title: String) {
        context.onRename?(title)
    }

    func navigationItemShouldBeginRenaming(_ navigationItem: UINavigationItem) -> Bool {
        context.onRename != nil
    }

    /// Rename… from the menus asks for the name; tapping the title renames it in place.
    func beginRenaming() {
        guard context.onRename != nil else { return }
        present(Self.renameAlert(title: context.title) { [weak self] name in self?.context.onRename?(name) }, animated: true)
    }

    /// Rename…'s question, the same from the session's menus and from the list.
    static func renameAlert(title: String, rename: @escaping (String) -> Void) -> UIAlertController {
        let alert = UIAlertController(title: "Rename Session", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
            field.accessibilityLabel = "Name"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let action = UIAlertAction(title: "Rename", style: .default) { [weak alert] _ in
            guard let name = alert?.textFields?.first?.text else { return }
            rename(name)
        }
        alert.addAction(action)
        alert.preferredAction = action
        return alert
    }

    private func copyPath() {
        guard !context.folderPath.isEmpty else { return }
        pasteboard.string = context.folderPath
    }

    /// Everything but the transcript's text follows the model at once; the text follows too,
    /// so a state change never shows an older frame of it.
    private func refresh() {
        guard isViewLoaded else { return }
        banner.show(currentBanner)
        refreshComposer()
        refreshMenu()
        refreshEmptyState()
        refreshPermission()
        announceTurnEnd()
        renderScheduler.cancel()
        renderTranscript()
    }

    private func renderTranscript() {
        guard isViewLoaded else { return }
        keepPendingThumbnails()
        transcript.update(messages: model.messages, isWorking: model.phase == .prompting,
                          isStopping: model.cancellationRequested)
        refreshEmptyState()
    }

    /// The photos just sent go with the first prompt after the send whose attachments they
    /// are, once the transcript has it.
    private func keepPendingThumbnails() {
        guard let pending = pendingThumbnails else { return }
        guard let message = model.messages.first(where: {
            $0.role == .user && !pending.after.contains($0.id) && $0.attachments.map(\.name) == pending.names
        }) else { return }
        pendingThumbnails = nil
        sentImages.store(pending.images, for: message.id)
    }

    private var isReadOnly: Bool { model.archivedWithoutContext && model.phase == .disconnected }

    private var hasSomethingToSend: Bool {
        !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Only a ready session takes a prompt, and not while a change of model or mode is on its way.
    var canSend: Bool {
        model.phase == .ready && !model.isChangingConfiguration && hasSomethingToSend
    }

    var canStop: Bool { model.phase == .prompting && !model.cancellationRequested }

    private func refreshComposer() {
        composer.isEditable = !isReadOnly
        // Nothing else on the screen names the agent, so the placeholder does at every size.
        composer.placeholder = isReadOnly ? "This conversation is read-only" : "Ask \(context.agentTitle)…"
        composer.canAttach = !isReadOnly && attachments.count < ComposerImage.maximumCount
        if model.phase == .prompting {
            composer.setAction(.stop(enabled: canStop))
        } else {
            composer.setAction(.send(enabled: canSend))
        }
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        let open = composer.isEditable && !model.commands.isEmpty && !suggestionsDismissed
            && SlashCommandSuggestionsView.query(in: composer.text).map { suggestions.show(model.commands, query: $0) } == true
        guard open == suggestions.isHidden else { return }
        suggestions.isHidden = !open
        if open {
            let count = suggestions.matches.count
            UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                string: count == 1 ? "1 command" : "\(count) commands",
                attributes: [.accessibilitySpeechQueueAnnouncement: true]))
        }
        refreshEmptyState()
    }

    // MARK: Hardware keyboard

    /// Return sends, as in Messages; with the slash suggestions up, the arrows move through
    /// them, Tab or Return takes one, and Escape puts them away.
    private func canHandle(_ key: SessionComposerView.Key) -> Bool {
        let suggesting = !suggestions.isHidden
        return switch key {
        case .return: suggesting || canSend
        case .up, .down, .tab, .escape: suggesting
        }
    }

    private func handle(_ key: SessionComposerView.Key) {
        switch key {
        case .return where suggestions.isHidden: send()
        case .return, .tab: if let command = suggestions.highlighted { choose(command) }
        case .up: suggestions.moveHighlight(by: -1)
        case .down: suggestions.moveHighlight(by: 1)
        case .escape:
            suggestionsDismissed = true
            refreshSuggestions()
        }
    }

    private func choose(_ command: ACPAvailableCommand) {
        composer.text = "/\(command.name) "
        context.onDraftChange(composer.text)
        refresh()
        composer.textView.becomeFirstResponder()
    }

    private var jumpShown = false

    /// Offered whenever the reader has left the end and the end is out of sight.
    private func refreshJumpButton() {
        let show = !transcript.isPinned && transcript.distanceFromBottom > 44
        guard show != jumpShown else { return }
        jumpShown = show
        if show { jumpButton.isHidden = false }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2, animations: {
            self.jumpButton.alpha = show ? 1 : 0
        }, completion: { _ in
            if !self.jumpShown { self.jumpButton.isHidden = true }
        })
    }

    private func refreshEmptyState() {
        // Slash suggestions take the empty page's place, rather than showing through it.
        guard model.messages.isEmpty, suggestions.isHidden else {
            emptyView.isHidden = true
            return
        }
        var configuration: UIContentUnavailableConfiguration
        switch model.phase {
        case .connecting:
            configuration = .loading()
            configuration.text = model.status == "Resuming…" ? "Resuming…" : "Connecting to \(serverName)…"
        case .ready, .prompting:
            configuration = .empty()
            configuration.image = UIImage(systemName: "text.bubble")
            configuration.text = "Ask \(context.agentTitle)"
            configuration.secondaryText = context.shownPath.isEmpty
                ? "Works on \(serverName)." : "Works in \(context.shownPath) on \(serverName)."
        case .disconnected, .stopping:
            // The banner says what went wrong, and offers what fixes it.
            guard model.errorMessage == nil, !banner.isShowing else {
                emptyView.isHidden = true
                return
            }
            configuration = .empty()
            configuration.image = UIImage(systemName: "bolt.horizontal.circle")
            configuration.text = "Not Connected"
            configuration.secondaryText = context.hasServer()
                ? "\(context.agentTitle) runs on \(serverName)." : "\(serverName) is no longer in Servers."
            if model.phase == .disconnected, context.hasServer() {
                // Retry, as the banner and the menu name the same action.
                var button = UIButton.Configuration.filled()
                button.title = "Retry"
                button.cornerStyle = .capsule
                configuration.button = button
                configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.context.onRetry() }
            }
        }
        // Centred in the part of the page the composer leaves open.
        configuration.directionalLayoutMargins.bottom = composerOverlap
        emptyView.isHidden = false
        if configuration != emptyView.configuration as? UIContentUnavailableConfiguration {
            emptyView.configuration = configuration
        }
    }

    private var serverName: String { context.serverName.isEmpty ? "the server" : context.serverName }

    /// Said only while the screen is on show: a screen popped off the stack still hears its
    /// model, and the list's banner speaks for it then. Queued behind whatever VoiceOver is
    /// reading, rather than cutting it off.
    private func announceTurnEnd() {
        guard model.turnsEnded != announcedTurns else { return }
        announcedTurns = model.turnsEnded
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let words = model.lastTurnEndedByStop ? "\(context.agentTitle) stopped." : "\(context.agentTitle) finished."
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: words, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
    }

    // MARK: Banner

    /// "Reconnecting to vps…" while a live session's server is out of reach. Named as the
    /// Servers list has the server now, in case it was renamed.
    private var reconnectingTitle: String? {
        guard case let .reconnecting(server, _) = model.linkState, model.phase != .disconnected else { return nil }
        let name = context.serverName.isEmpty ? server : context.serverName
        return model.phase == .connecting ? "Connecting to \(name)…" : "Reconnecting to \(name)…"
    }

    /// The one place the session's state is reported, in the Mac's order: waiting for the
    /// server outranks an earlier failure, a refused photo is said only when nothing failed,
    /// a read-only conversation is a state rather than a failure, then the failure itself.
    var currentBanner: SessionBanner? {
        if let title = reconnectingTitle, case let .reconnecting(_, since) = model.linkState {
            let message = switch model.phase {
            case .connecting: "It has not answered yet. Latch keeps trying for a few seconds."
            case .prompting: "The agent keeps working on the server. Latch catches up once it answers again."
            default: "The agent is still running there. Latch reconnects on its own."
            }
            return SessionBanner(key: "link\u{0}\(since.timeIntervalSinceReferenceDate)\u{0}\(message)", title: title,
                                 message: message, severity: .info, isWaiting: true,
                                 actions: model.phase == .connecting ? [Self.serverSettingsAction] : [])
        }
        if let notice = attachmentNotice, model.errorMessage == nil {
            return SessionBanner(key: "attachments\u{0}\(notice.id)", title: notice.title, message: notice.message,
                                 severity: .warning, takesFocus: false)
        }
        let disconnected = model.phase == .disconnected
        if disconnected, model.archivedWithoutContext, model.errorMessage == nil {
            return SessionBanner(
                key: "archive", title: "This conversation is read-only",
                message: "It was saved without the agent’s context, so it can’t be picked up where it left off. Its history stays here.",
                severity: .info)
        }
        guard let error = model.errorMessage else { return disconnected ? idleBanner : nil }
        // Monospace is for what the agent said; Latch's own sentences read as its advice.
        var detail = ""
        var message: String
        let advice = model.errorAdvice.map { " " + $0 } ?? ""
        if model.stoppedOnServer {
            message = "Another device or the server stopped it. Retry starts it again."
        } else if let status = exitStatus {
            message = "It exited with status \(status). Retry starts it again."
        } else if model.errorIsConnectionFailure {
            // Retry is on the banner: the Mac's advice to retry would only say it again.
            message = Self.iOSWords(error) + (disconnected && context.hasServer() ? Self.withoutRetryAdvice(advice) : advice)
        } else {
            detail = Self.agentWords(Self.iOSWords(error))
            message = model.errorAdvice ?? ""
        }
        if !context.hasServer() { message = "\(serverName) is no longer in Servers." }
        var actions: [SessionBanner.Action] = []
        if disconnected, context.hasServer() { actions.append(Self.retryAction) }
        if model.errorIsConnectionFailure, context.hasServer() { actions.append(Self.serverSettingsAction) }
        return SessionBanner(
            key: "\(model.phase)\u{0}\(model.connectionAttempts)\u{0}\(detail)\u{0}\(message)",
            title: failureTitle(disconnected: disconnected), message: message, detail: detail,
            // An agent stopped on purpose, by another device or the server, is not a fault.
            severity: disconnected && !model.stoppedOnServer ? .error : .warning,
            actions: actions)
    }

    /// A session with no agent and nothing wrong: stopped from here, or left without a server.
    /// An empty one shows the empty page instead, which says the same.
    private var idleBanner: SessionBanner? {
        guard !model.messages.isEmpty, !isReadOnly else { return nil }
        if !context.hasServer() {
            return SessionBanner(key: "serverRemoved", title: "\(serverName) is no longer in Servers",
                                 message: "The conversation stays on this \(device), but it can’t reach its agent again.",
                                 severity: .info, symbol: "xmark.circle")
        }
        guard context.isStopped() else { return nil }
        return SessionBanner(key: "stopped\u{0}\(model.connectionAttempts)", title: "\(context.agentTitle) is stopped",
                             message: "Start it again to carry on the conversation where it left off.",
                             severity: .info, symbol: "stop.circle", actions: [Self.startAction])
    }

    private var device: String { traitCollection.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    /// The status of an agent process that ended by itself, such as "3".
    private var exitStatus: String? {
        let prefix = "Agent exited ("
        guard model.phase == .disconnected, model.status.hasPrefix(prefix), model.status.hasSuffix(")") else { return nil }
        return String(model.status.dropFirst(prefix.count).dropLast())
    }

    /// The shared model's advice is written for the Mac, where an agent is picked again from
    /// a menu; here Retry does that. The server's name never breaks at its hyphen.
    static func iOSWords(_ message: String) -> String {
        message.replacingOccurrences(of: " Select the agent again to reconnect.", with: " Retry starts it again.")
            .replacingOccurrences(of: "latch-server", with: "latch\u{2011}server")
    }

    /// The model's reassurance after a failed resume, which ends by offering the Retry the
    /// banner already shows.
    static func withoutRetryAdvice(_ advice: String) -> String {
        advice.replacingOccurrences(of: " Your saved history is unchanged. Retry, or start a new session.", with: "")
    }

    private static let retryAction = SessionBanner.Action(title: "Retry", id: "retry")
    private static let startAction = SessionBanner.Action(title: "Start Agent", id: "retry")
    private static let serverSettingsAction = SessionBanner.Action(title: "Server Settings", id: "serverSettings")

    /// Whose failure it is: an unreachable server is not the agent's fault.
    private func failureTitle(disconnected: Bool) -> String {
        let agent = context.agentTitle
        if model.status == "Sign-in required" { return "\(agent) isn’t signed in on \(serverName)" }
        if model.errorIsConnectionFailure { return "Can’t connect to \(serverName)" }
        if disconnected, model.stoppedOnServer { return "\(agent) stopped on \(serverName)" }
        if disconnected, case .failed(_, _, runtimeGone: true) = model.linkState { return "\(agent) stopped on \(serverName)" }
        if exitStatus != nil { return "\(agent) quit unexpectedly on \(serverName)" }
        return disconnected ? "\(agent) can’t start on \(serverName)" : "\(agent) reported a problem"
    }

    /// The title already names the agent, so the service's "Agent reported:" prefix would
    /// only repeat it.
    static func agentWords(_ message: String) -> String {
        let prefix = "Agent reported: "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
    }

    private func bannerAction(_ id: String) {
        switch id {
        case Self.retryAction.id:
            banner.resetDismissal()
            context.onRetry()
        case Self.serverSettingsAction.id:
            context.onServerSettings()
        default:
            break
        }
    }

    // MARK: Menu

    private struct MenuState: Equatable {
        let configuration: SessionConfiguration
        let editable: Bool
        let canStartAgent: Bool
        let canStopAgent: Bool
        let folderPath: String
        let canRename: Bool
    }

    private var canStartAgent: Bool { model.phase == .disconnected && !isReadOnly && context.hasServer() }
    private var canStopAgent: Bool {
        context.canStopAgent?() ?? (model.phase != .disconnected || model.remoteBinding != nil)
    }

    private func refreshMenu() {
        let state = MenuState(
            configuration: model.configuration,
            editable: model.phase == .ready && !model.isChangingConfiguration,
            canStartAgent: canStartAgent, canStopAgent: canStopAgent,
            folderPath: context.folderPath, canRename: context.onRename != nil)
        guard state != renderedMenu else { return }
        renderedMenu = state
        menuButton.menu = makeMenu(state)
    }

    private func makeMenu(_ state: MenuState) -> UIMenu {
        let pickers: [(SessionPicker.Kind, String, String)] = [
            (.model, "Model", "cpu"),
            (.effort, "Effort", "gauge.with.dots.needle.50percent"),
            (.permissionMode, "Permission Mode", "lock.shield"),
        ]
        let settings = pickers.compactMap { kind, title, symbol -> UIMenu? in
            guard let picker = state.configuration[kind], !picker.choices.isEmpty else { return nil }
            return pickerMenu(kind, picker: picker, title: title, symbol: symbol, enabled: state.editable)
        }
        let copyPath = UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc"),
                                attributes: state.folderPath.isEmpty ? .disabled : []) { [weak self] _ in
            self?.copyPath()
        }
        let rename = UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.beginRenaming()
        }
        let stop = UIAction(title: "Stop Agent", image: UIImage(systemName: "stop.circle"),
                            attributes: state.canStopAgent ? .destructive : [.destructive, .disabled]) { [weak self] _ in
            self?.confirmStopAgent()
        }
        let start = UIAction(title: "Start Agent", image: UIImage(systemName: "play.circle")) { [weak self] _ in
            self?.banner.resetDismissal()
            self?.context.onRetry()
            self?.refresh()
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: settings),
            UIMenu(options: .displayInline, children: state.canRename ? [rename, copyPath] : [copyPath]),
            UIMenu(options: .displayInline, children: state.canStartAgent ? [start, stop] : [stop]),
        ])
    }

    /// The agent's choices in its order and groups, the current one checked. Nothing is
    /// checked ahead of the agent: the mark moves when it confirms the change.
    private func pickerMenu(_ kind: SessionPicker.Kind, picker: SessionPicker, title: String, symbol: String,
                            enabled: Bool) -> UIMenu {
        var children: [UIMenuElement] = []
        var group: (name: String, actions: [UIAction])?
        func closeGroup() {
            if let open = group { children.append(UIMenu(title: open.name, options: .displayInline, children: open.actions)) }
            group = nil
        }
        for choice in picker.choices {
            let action = UIAction(title: choice.name, subtitle: choice.description,
                                  attributes: enabled ? [] : .disabled,
                                  state: choice.value == picker.currentValue ? .on : .off) { [weak self] _ in
                guard let self else { return }
                Task { await self.model.select(kind, value: choice.value) }
            }
            if let name = choice.group {
                if group?.name != name { closeGroup(); group = (name, []) }
                group?.actions.append(action)
            } else {
                closeGroup()
                children.append(action)
            }
        }
        closeGroup()
        let current = picker.choices.first { $0.value == picker.currentValue }?.name
        if current == nil {
            children.insert(UIAction(title: "Current: \(picker.currentValue)", attributes: .disabled, state: .on) { _ in }, at: 0)
        }
        return UIMenu(title: title, subtitle: current ?? picker.currentValue, image: UIImage(systemName: symbol),
                      children: children)
    }

    private func confirmStopAgent() {
        let alert = Self.stopConfirmation(agentTitle: context.agentTitle, serverName: serverName, device: device,
                                          style: .actionSheet, go: { [weak self] in
            self?.context.onStopAgent()
            self?.refresh()
        }, cancel: { [weak self] in self?.refresh() })
        alert.popoverPresentationController?.sourceItem = menuButton
        present(alert, animated: true)
    }

    /// Stop Agent's question, the same from the session's menu and from the list.
    static func stopConfirmation(agentTitle: String, serverName: String, device: String,
                                 style: UIAlertController.Style, go: @escaping () -> Void,
                                 cancel: @escaping () -> Void = {}) -> UIAlertController {
        let alert = UIAlertController(
            title: "Stop \(agentTitle) on \(serverName)?",
            message: "Anything it is doing stops. The conversation stays on this \(device).",
            preferredStyle: style)
        alert.addAction(UIAlertAction(title: "Stop Agent", style: .destructive) { _ in go() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cancel() })
        return alert
    }

    // MARK: Sending

    func send() {
        guard canSend else { return }
        // An image added before the agent said it takes none: take it out and keep the draft,
        // so the rest can go as it is.
        let refused = attachments.filter { model.refusesRemotely($0.prompt) }
        guard refused.isEmpty else {
            attachments.removeAll { model.refusesRemotely($0.prompt) }
            composer.setAttachments(attachments)
            return refuseImages()
        }
        let draft = composer.text
        let sent = attachments.map(\.prompt)
        pendingThumbnails = sent.isEmpty ? nil
            : (sent.map(\.name), attachments.map(\.thumbnail), Set(model.messages.map(\.id)))
        composer.text = ""
        attachments = []
        composer.setAttachments([])
        attachmentNotice = nil
        context.onDraftChange("")
        transcript.scrollToBottom(animated: false)
        Task { await model.send(draft, attachments: sent) }
        refresh()
    }

    func stop() {
        guard canStop else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await model.cancel() }
    }

    // MARK: Menu bar

    // The Session menu's commands, which `LatchAppDelegate.buildMenu(with:)` lists. They find
    // this screen through the responder chain, or through the root when the list has focus.

    @objc func sendCommand() { send() }
    @objc func stopCommand() { stop() }
    @objc func addPhotosCommand() { chooseImages() }
    @objc func copyPathCommand() { copyPath() }
    @objc func renameCommand() { beginRenaming() }
    @objc func stopAgentCommand() { confirmStopAgent() }
    @objc func startAgentCommand() {
        banner.resetDismissal()
        context.onRetry()
        refresh()
    }
    @objc func jumpToLatestCommand() { transcript.scrollToBottom(animated: true) }

    static let menuActions: Set<Selector> = [
        #selector(sendCommand), #selector(stopCommand), #selector(addPhotosCommand), #selector(copyPathCommand),
        #selector(renameCommand), #selector(stopAgentCommand), #selector(startAgentCommand), #selector(jumpToLatestCommand),
    ]

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let free = presentedViewController == nil
        switch action {
        case #selector(sendCommand): return canSend
        case #selector(stopCommand): return canStop
        case #selector(addPhotosCommand): return free && composer.canAttach
        case #selector(copyPathCommand): return !context.folderPath.isEmpty
        case #selector(renameCommand): return free && context.onRename != nil
        case #selector(stopAgentCommand): return free && canStopAgent
        case #selector(startAgentCommand): return free && canStartAgent
        case #selector(jumpToLatestCommand): return jumpShown
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    // MARK: Photos

    /// A photo the agent would refuse is refused before the picker opens, with the reason.
    private var refusesImages: Bool {
        model.refusesRemotely(PromptAttachment(name: "", content: .image(data: Data(), mimeType: "image/jpeg", source: nil)))
    }

    func chooseImages() {
        guard composer.canAttach, presentedViewController == nil else { return }
        guard !refusesImages else { return refuseImages() }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = ComposerImage.maximumCount - attachments.count
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in self?.refresh() }
        let providers = results.map(\.itemProvider)
        guard !providers.isEmpty else { return }
        Task { [weak self] in
            var images: [ComposerImage] = []
            for provider in providers {
                if let image = await ComposerImage.load(from: provider) { images.append(image) }
            }
            self?.add(images)
        }
    }

    /// Up to the limit. A remote agent that takes no images refuses them all, and says why.
    func add(_ images: [ComposerImage]) {
        guard !images.isEmpty else { return }
        if images.contains(where: { model.refusesRemotely($0.prompt) }) { return refuseImages() }
        let room = max(0, ComposerImage.maximumCount - attachments.count)
        attachments += images.prefix(room)
        attachmentNotice = nil
        if images.count > room {
            composer.setAttachments(attachments)
            return refuseMore()
        }
        composer.setAttachments(attachments)
        refresh()
    }

    /// Pasted or dropped photos, read off the main thread, as picked ones are.
    func load(_ providers: [NSItemProvider]) {
        let images = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard !images.isEmpty else { return }
        guard composer.canAttach else { return refuseMore() }
        Task { [weak self] in
            var loaded: [ComposerImage] = []
            for provider in images {
                if let image = await ComposerImage.load(from: provider) { loaded.append(image) }
            }
            self?.add(loaded)
        }
    }

    private func refuseMore() {
        attachmentNotice = (UUID(), "You can send up to \(ComposerImage.maximumCount) photos at a time.",
                            "Send these first, or remove one to add another.")
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        refresh()
    }

    // MARK: Dropping

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        !isReadOnly && session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: composer.canAttach ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        composer.isDropTarget = composer.canAttach
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        composer.isDropTarget = false
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        composer.isDropTarget = false
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        composer.isDropTarget = false
        load(session.items.map(\.itemProvider))
    }

    private func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        composer.setAttachments(attachments)
        refresh()
    }

    private func refuseImages() {
        attachmentNotice = (UUID(), "\(context.agentTitle) on \(serverName) can’t receive images.",
                            "Send your message without the image, or start a session with an agent that accepts images.")
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        refresh()
    }

    // MARK: Permission

    /// One request at a time, as a sheet over this screen, or over whatever this screen has
    /// on top of it. A sheet whose request closed on its own, or was decided, goes, and the
    /// next one waiting follows it. UIKit drops a dismissal asked for while the sheet is still
    /// arriving, so nothing starts until the transition before it has ended, and each end
    /// looks again. While another presentation is coming or going, it looks again shortly:
    /// an agent waiting on a decision sends nothing else that would.
    private func refreshPermission() {
        guard !permissionTransition else { return }
        let pending = model.permissions.current
        if let sheet = permissionSheet {
            guard sheet.promptID != pending?.id else { return }
            permissionTransition = true
            dismissSheet(sheet) { [weak self] in
                self?.permissionTransition = false
                self?.permissionSheet = nil
                self?.refreshPermission()
            }
            return
        }
        guard let pending, viewIfLoaded?.window != nil else { return }
        let presenter = topPresenter
        // An alert, such as Stop Agent's confirmation, is answered first: nothing is presented
        // over one. On iPad it can go with a tap outside its popover, which calls no action.
        guard !presenter.isBeingPresented, !presenter.isBeingDismissed, !(presenter is UIAlertController) else {
            return schedulePermissionRetry()
        }
        let sheet = PermissionRequestViewController(prompt: pending, agentTitle: context.agentTitle) { [weak self] optionID in
            guard let self else { return }
            model.permissions.resolve(id: pending.id, optionID: optionID)
            refresh()
        }
        // Taken down by something else, such as the host showing another session: shown
        // again when this screen is next on screen, if the request is still open.
        sheet.onDismissedElsewhere = { [weak self, weak sheet] in
            guard let self, let sheet, permissionSheet === sheet, !permissionTransition else { return }
            permissionSheet = nil
            refreshPermission()
        }
        permissionSheet = sheet
        permissionTransition = true
        presentSheet(sheet) { [weak self] in
            self?.permissionTransition = false
            self?.refreshPermission()
        }
        // The sheet says what is asked when it takes VoiceOver's focus.
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func schedulePermissionRetry() {
        guard permissionRetry == nil else { return }
        permissionRetry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.permissionRetry = nil
            self?.refreshPermission()
        }
    }

    /// The controller at the top of what this screen's window shows.
    private var topPresenter: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, next !== permissionSheet { top = next }
        return top
    }
}

/// The title and `server · folder` on two lines, for systems without a navigation subtitle.
/// Tapping it opens the title menu, as the system's title does. VoiceOver hears the whole path.
private final class SessionTitleView: UIButton {
    init(title: String, subtitle: String, spoken: String, menu: UIMenu) {
        super.init(frame: .zero)
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.isHidden = subtitle.isEmpty
        let chevron = UIImageView(image: UIImage(systemName: "chevron.down.circle.fill"))
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, chevron])
        titleRow.spacing = 4
        titleRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        self.menu = menu
        showsMenuAsPrimaryAction = true
        isPointerInteractionEnabled = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityValue = spoken
        accessibilityTraits = [.header, .button]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
