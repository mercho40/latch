import LatchRemoteProtocol
import LatchSessionKit
import UIKit

/// What the root asks of whoever owns the servers. Nothing on this screen adds a server
/// itself: the delegate presents the Add Server sheet, and it is the only place one is added.
@MainActor
public protocol RootViewControllerDelegate: AnyObject {
    /// The user tapped Add Server. The delegate presents the sheet, empty.
    func rootViewControllerDidRequestAddServer(_ root: RootViewController)
    /// The app was opened with a `latch://` link. The delegate presents the Add Server sheet
    /// filled in from a pairing and asks the user to confirm it, or says why the link is not
    /// one; a server is never added without that confirmation.
    func rootViewController(_ root: RootViewController,
                            didOpenPairingLink link: Result<LatchRemotePairing, LatchRemotePairingError>)
}

/// Makes the screen that shows one session in the secondary column. The root is passed for
/// what the screen offers beyond its session: the library, and the server's settings.
typealias SessionViewControllerFactory = @MainActor (PhoneSession, RootViewController) -> UIViewController

/// The window's root: sessions in the primary column and the open session in the secondary.
/// On iPhone and in compact width the columns collapse into one navigation stack, which
/// starts at the sessions list.
public final class RootViewController: UISplitViewController, UISplitViewControllerDelegate {
    let sessions: SessionsViewController
    /// Replaced rather than reused: the split view wraps a column's controller in a navigation
    /// controller that keeps it, and asserts when it is set again.
    private(set) var placeholder = SessionPlaceholderViewController()
    let library: SessionLibrary
    let servers: any PhoneServerStore
    let check: ServerCheck
    /// Each server's home folder and where removed servers were.
    let memory: ServerMemory
    private let makeSessionViewController: SessionViewControllerFactory
    private let badge: ApprovalBadge?
    /// The session in the secondary column, and the screen showing it.
    private(set) var shown: (session: PhoneSession, controller: UIViewController)?
    private(set) lazy var banners = AttentionBannerPresenter(host: view)

    /// Set by the scene before it opens any link. A link that arrives while this is `nil`
    /// waits here and is handed over as soon as it is set, so one that launched the app is
    /// not lost to the order things start in.
    public weak var serverDelegate: (any RootViewControllerDelegate)? {
        didSet { deliverPendingLink() }
    }
    private var pendingLink: Result<LatchRemotePairing, LatchRemotePairingError>?

    /// Servers in memory and nothing saved, for previews and tests.
    public convenience init() {
        let servers = InMemoryServerStore()
        self.init(library: SessionLibrary(servers: servers, connector: ChannelRemoteSessionConnector(servers: servers),
                                          store: nil),
                  servers: servers, check: ServerCheckText.live, badge: nil)
    }

    /// `makeSessionViewController` builds the screen for a session; tests pass their own.
    init(library: SessionLibrary, servers: any PhoneServerStore, check: @escaping ServerCheck, badge: ApprovalBadge?,
         defaults: UserDefaults = .standard, memory: ServerMemory? = nil,
         makeSessionViewController: @escaping SessionViewControllerFactory = SessionDetailViewController.make) {
        let memory = memory ?? ServerMemory(defaults: defaults)
        self.library = library
        self.servers = servers
        self.memory = memory
        // Every check of a saved server, from any screen, leaves its home for the paths shown on it.
        self.check = memory.recording(check, savedIn: servers)
        self.badge = badge
        self.makeSessionViewController = makeSessionViewController
        sessions = SessionsViewController(library: library, defaults: defaults)
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        // UIKit wraps each column in its own navigation controller.
        setViewController(sessions, for: .primary)
        setViewController(makePlaceholder(), for: .secondary)
        wire()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func wire() {
        sessions.onAddServer = { [weak self] in
            guard let self else { return }
            serverDelegate?.rootViewControllerDidRequestAddServer(self)
        }
        sessions.onScan = { [weak self] in self?.presentScanner() }
        sessions.onNewSession = { [weak self] serverID in self?.presentNewSession(serverID: serverID) }
        sessions.onShowServers = { [weak self] in self?.presentServers() }
        sessions.onServerSettings = { [weak self] id in self?.presentServerEditor(serverID: id) }
        sessions.onOpen = { [weak self] session in self?.show(session) }
        sessions.onShownAlone = { [weak self] in self?.listShownAlone() }
        sessions.confirm = { [weak self] confirmation, go in self?.confirm(confirmation, go) }
        sessions.rename = { [weak self] session in
            self?.presentOnTop(SessionDetailViewController.renameAlert(title: session.title) { [weak session] name in
                session?.rename(to: name)
            })
        }
        library.onServerRemoved = { [weak self] server in self?.memory.recordRemoval(of: server) }
        // A fork shares its messages, and their pictures, with the session it was copied from.
        library.onForget = { [weak library] session in
            let kept = Set(library?.sessions.flatMap { $0.model.messages.map(\.id) } ?? [])
            SentImageCache.shared.remove(session.model.messages.map(\.id).filter { !kept.contains($0) })
        }
        library.isSessionVisible = { [weak self] id in self?.isShowing(id) ?? false }
        library.onChange = { [weak self] in self?.libraryChanged() }
        library.onSessionChange = { [weak self] session in self?.sessions.sessionChanged(session) }
        library.onAttention = { [weak self] session, attention in self?.announce(session, attention) }
        library.onApprovalCountChange = { [weak self] count in
            guard let self else { return }
            // Only for a request or question the user cannot see: over one on screen, the
            // system's question about badges would come with no context, in front of it.
            let unseen = library.sessions.contains { $0.waitsForUser && !isShowing($0.id) }
            badge?.update(count, mayAsk: unseen)
        }
    }

    // MARK: Links

    /// Forwards the first `latch://` link among `urls`: the Add Server sheet confirms one
    /// server at a time. Any other scheme is ignored.
    func open(_ urls: [URL]) {
        guard let link = urls.lazy.compactMap(PairingLink.parse).first else { return }
        pendingLink = link
        deliverPendingLink()
    }

    /// Scan Pairing Code. A code read in Latch is a link opened from the Camera app, without
    /// leaving Latch: the delegate takes it as one, after the scanner has gone.
    func presentScanner() {
        presentOnTop(PairingScannerViewController.sheet { [weak self] pairing in
            guard let self else { return }
            pendingLink = .success(pairing)
            deliverPendingLink()
        })
    }

    private func deliverPendingLink() {
        guard let serverDelegate, let link = pendingLink else { return }
        pendingLink = nil
        serverDelegate.rootViewController(self, didOpenPairingLink: link)
    }

    /// Collapsing, as on a rotation or a narrower window, keeps the open session on top of the
    /// list, and shows the list when none is open rather than an empty session.
    public func splitViewController(_ svc: UISplitViewController,
                                    topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column)
        -> UISplitViewController.Column {
        shown == nil ? .primary : .secondary
    }

    /// Expanding again, the open session is beside the list, so it is the one selected.
    public func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        if let shown { library.open(shown.session) }
        sessions.reload(animated: false)
        sessions.selectShownSession()
    }

    /// Collapsed, the list is all there is, so it explains pairing itself.
    public func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
        sessions.reload(animated: false)
    }

    /// Back at the list on iPhone: no session is open, so a relaunch starts at the list too.
    private func listShownAlone() {
        guard isCollapsed, shown != nil else { return }
        library.deselect()
    }

    // MARK: Sessions

    /// Opens a session in the secondary column, pushed over the list when collapsed.
    func show(_ session: PhoneSession) {
        if let presented = presentedViewController, !presented.isBeingDismissed {
            // A banner tapped over a sheet: the sheet goes, then the session shows.
            return dismiss(animated: true) { [weak self] in self?.show(session) }
        }
        library.open(session)
        if shown?.session !== session {
            let controller = makeSessionViewController(session, self)
            shown = (session, controller)
            setViewController(controller, for: .secondary)
        }
        show(.secondary)
        sessions.selectShownSession()
    }

    /// Shows what was on screen when the app last closed: beside the list, or pushed over it
    /// on iPhone.
    func restoreSelection() {
        guard shown == nil, presentedViewController == nil,
              let id = library.selectedSessionID, let session = library.session(id: id) else { return }
        show(session)
    }

    /// Whether the user can see the session: its screen is in a window, not popped off the
    /// stack or behind the list.
    func isShowing(_ id: UUID) -> Bool {
        guard let shown, shown.session.id == id else { return false }
        return shown.controller.viewIfLoaded?.window != nil
    }

    private func libraryChanged() {
        sessions.reload()
        placeholder.hasServers = !servers.servers.isEmpty
        // A renamed server's name, in the open session's title, and a removed one's notice.
        if let shown, let screen = shown.controller as? SessionDetailViewController {
            screen.follow(shown.session, in: self)
            screen.modelDidChange()
        }
        // A removed session's screen goes with it, once any push or pop has finished: the split
        // view asserts when its columns change in the middle of one.
        guard let shown, library.session(id: shown.session.id) !== shown.session else { return }
        if let transition = shown.controller.transitionCoordinator ?? sessions.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.libraryChanged() }
            return
        }
        self.shown = nil
        // Made anew, as when its server's token was entered again: the new one's screen takes
        // the old one's place in the column, on screen or not, so expanding never shows the
        // old one. Not through `show`, which opens a session the user chose and would take down
        // the sheet they entered the token in.
        if let replacement = library.session(id: shown.session.id) {
            let onScreen = shown.controller.viewIfLoaded?.window != nil
            let controller = makeSessionViewController(replacement, self)
            self.shown = (replacement, controller)
            setViewController(controller, for: .secondary)
            if onScreen {
                library.open(replacement)
            } else if isCollapsed {
                // The list the user went back to stays on top, should setting the column push it.
                show(.primary)
            }
            return
        }
        setViewController(makePlaceholder(), for: .secondary)
        if isCollapsed { show(.primary) }
    }

    private func makePlaceholder() -> SessionPlaceholderViewController {
        placeholder = SessionPlaceholderViewController()
        placeholder.hasServers = !servers.servers.isEmpty
        placeholder.onAddServer = { [weak self] in self?.sessions.addServer() }
        placeholder.onScan = { [weak self] in self?.presentScanner() }
        placeholder.onNewSession = { [weak self] in self?.presentNewSession() }
        return placeholder
    }

    /// ⌥⌘↑ and ⌥⌘↓, or ⌘[ and ⌘]: the next session in the list's order.
    func step(by offset: Int) {
        let ordered = library.orderedSessions
        guard !ordered.isEmpty else { return }
        let current = shown.flatMap { shown in ordered.firstIndex { $0 === shown.session } }
        let next = current.map { ($0 + offset + ordered.count) % ordered.count } ?? (offset > 0 ? 0 : ordered.count - 1)
        show(ordered[next])
    }

    // MARK: Sheets

    /// Presents over whatever is already presented, so a link or a key command works with a
    /// sheet open.
    func presentOnTop(_ controller: UIViewController) {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(controller, animated: true)
    }

    func presentNewSession(serverID: UUID? = nil) {
        guard let sheet = newSessionSheet(serverID: serverID) else {
            serverDelegate?.rootViewControllerDidRequestAddServer(self)
            return
        }
        presentOnTop(sheet)
    }

    /// New Session in its sheet, or nil with no server to start one on.
    func newSessionSheet(serverID: UUID? = nil) -> UINavigationController? {
        guard !servers.servers.isEmpty else { return nil }
        let controller = NewSessionViewController(servers: servers.servers, serverID: serverID, check: check, memory: memory) {
            [weak library] id in
            // Adopted sessions count too: they name the agent and folder that are in use there.
            library?.sessions(on: id).first.map { .init(serverID: id, path: $0.path, agent: $0.agent) }
        }
        controller.recentFolders = { [weak library] id in library?.recentFolders(on: id) ?? [] }
        controller.onCreate = { [weak self] choice in
            guard let self else { return }
            let session = library.create(serverID: choice.serverID, path: choice.path, agent: choice.agent)
            show(session)
            // Started from New Session, the next thing is the first prompt.
            (shown?.controller as? SessionDetailViewController)?.focusComposerOnAppear()
        }
        let navigation = UINavigationController(rootViewController: controller)
        if traitCollection.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .formSheet
            // As tall as the form, which the sheet sets from its table; a full form sheet
            // would be mostly empty at the default text size.
            navigation.preferredContentSize = CGSize(width: 540, height: 400)
        } else if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            // At accessibility sizes the medium detent shows only the menus, not the folder.
            if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
                sheet.selectedDetentIdentifier = .large
            }
        }
        return navigation
    }

    func presentServers() { presentOnTop(serversSheet()) }

    /// Servers in its sheet, with Done; its editor opens over it.
    func serversSheet() -> UINavigationController {
        let controller = ServersViewController(store: servers, check: check)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        controller.onEdit = { [weak navigation] editor in
            navigation?.present(ServerEditorViewController.sheet(editor), animated: true)
        }
        controller.onScan = { [weak self] in self?.presentScanner() }
        return navigation
    }

    /// Whether Servers has the server, or keeps it while its token is entered again.
    func hasServer(_ id: UUID) -> Bool {
        servers.server(id: id) != nil || servers.missingTokens.contains { $0.id == id }
    }

    func presentServerEditor(serverID: UUID? = nil, pairing: LatchRemotePairing? = nil) {
        presentOnTop(serverEditorSheet(serverID: serverID, pairing: pairing))
    }

    /// Add Server, or Edit Server for `serverID`, filled in from `pairing` when there is one.
    /// A server whose token is missing is edited under its own ID, so its sessions come back.
    func serverEditorSheet(serverID: UUID? = nil, pairing: LatchRemotePairing? = nil) -> UINavigationController {
        let editor = if let serverID, let server = servers.server(id: serverID) {
            ServerEditorViewController(store: servers, editing: server, pairing: pairing, check: check)
        } else if let serverID, let stored = servers.missingTokens.first(where: { $0.id == serverID }) {
            ServerEditorViewController(store: servers, restoring: stored, pairing: pairing, check: check)
        } else {
            ServerEditorViewController(store: servers, pairing: pairing, check: check)
        }
        let isNew = serverID == nil
        editor.onSave = { [weak self] server in
            guard let self else { return }
            guard isNew else {
                Task { await self.library.refreshRuntimes(for: [server.id]) }
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            afterPresentationsSettle { [weak self] in self?.serverAdded(server) }
        }
        return ServerEditorViewController.sheet(editor)
    }

    /// Runs `body` once nothing is on its way on or off screen: nothing can be presented
    /// while a sheet is still going.
    private func afterPresentationsSettle(_ body: @escaping () -> Void) {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        if (top.isBeingDismissed || top.isBeingPresented), let transition = top.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in body() }
        } else {
            body()
        }
    }

    /// A server just added: sessions left from when it was removed are offered back, and
    /// otherwise the next step is shown, which is the agents it already runs, or New Session.
    private func serverAdded(_ server: ServerProfile) {
        let left = library.orphanedSessions.filter { memory.removedServer(id: $0.serverID)?.address == server.address }
        if !left.isEmpty { return offerReconnection(left, to: server) }
        Task {
            await library.refreshRuntimes(for: [server.id])
            guard presentedViewController == nil, servers.server(id: server.id) != nil else { return }
            if !library.adoptableRuntimes(on: server.id).isEmpty {
                sessions.expandRuntimes(on: server.id)
                sessions.scrollToServer(server.id)
            } else if library.sessions(on: server.id).isEmpty {
                presentNewSession(serverID: server.id)
            }
        }
    }

    private func offerReconnection(_ left: [PhoneSession], to server: ServerProfile) {
        let device = UIDevice.current.model
        let formerName = memory.removedServer(id: left[0].serverID)?.name ?? server.name
        let count = left.count == 1 ? "1 session" : "\(left.count) sessions"
        let alert = UIAlertController(
            title: "Reconnect \(count) on “\(server.name)”?",
            message: "“\(formerName)” had \(count) on this \(device) when it was removed. Reconnected, "
                + (left.count == 1 ? "it picks up its agent" : "they pick up their agents") + " if still running there.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
            Task { await self?.library.refreshRuntimes(for: [server.id]) }
        })
        let reconnect = UIAlertAction(title: "Reconnect", style: .default) { [weak self] _ in
            guard let self else { return }
            let formerIDs = Set(left.map(\.serverID))
            library.move(left, to: server.id)
            formerIDs.forEach(memory.forgetRemoval)
            Task { await self.library.refreshRuntimes(for: [server.id]) }
        }
        alert.addAction(reconnect)
        alert.preferredAction = reconnect
        presentOnTop(alert)
    }

    private func confirm(_ confirmation: SessionsViewController.Confirmation, _ go: @escaping () -> Void) {
        let device = UIDevice.current.model
        let alert: UIAlertController
        switch confirmation {
        case let .remove(title, server, agentRuns: true):
            alert = UIAlertController(
                title: "Remove “\(title)” from this \(device)?",
                message: "The agent keeps running on \(server). To open it again, find it under “On \(server)”.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Remove", style: .default) { _ in go() })
        case let .remove(title, _, agentRuns: false):
            alert = UIAlertController(
                title: "Remove “\(title)” from this \(device)?",
                message: "The agent is stopped, so nothing on the server keeps this conversation. It will be gone from this \(device).",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in go() })
        case let .stop(agent, server):
            alert = SessionDetailViewController.stopConfirmation(agentTitle: agent, serverName: server, device: device,
                                                                 style: .alert, go: go)
        }
        presentOnTop(alert)
    }

    // MARK: Attention

    private func announce(_ session: PhoneSession, _ attention: SessionLibrary.Attention) {
        let waiting = SessionStatusView.mark(for: .waiting)
        let agent = session.agentTitle
        let server = servers.server(id: session.serverID)?.name ?? "its server"
        let (message, symbol, tint): (String, String, UIColor) = switch attention {
        case .needsApproval:
            ("\(agent) on \(server) needs approval" + (session.pendingRequestTitle.map { ": \($0)" } ?? "."),
             waiting?.symbol ?? "exclamationmark.circle.fill", waiting?.color ?? .systemOrange)
        case .asksQuestion:
            ("\(agent) on \(server) asks" + (session.pendingQuestion.map { ": \($0)" } ?? " a question."),
             "questionmark.circle.fill", waiting?.color ?? .systemOrange)
        case .finished: ("\(agent) finished.", "checkmark.circle.fill", .systemGreen)
        case .stoppedOnServer: ("\(agent) was stopped on \(server).", "stop.circle.fill", .secondaryLabel)
        }
        banners.show(title: session.title, message: message, symbol: symbol, tint: tint,
                     urgent: attention == .needsApproval || attention == .asksQuestion) { [weak self, weak session] in
            guard let self, let session, self.library.session(id: session.id) != nil else { return }
            self.show(session)
        }
    }

    var attentionBanner: AttentionBannerView? { banners.current }

    /// Under the navigation bar's buttons, never over them. Beside a sidebar, across the
    /// session's column, so the sidebar's own buttons stay in reach.
    private func bannerPlacement() -> (top: CGFloat, column: CGRect)? {
        guard view.bounds.width > 0 else { return nil }
        if !isCollapsed, let navigation = viewController(for: .secondary)?.navigationController, navigation.view.window != nil {
            let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: view)
            var column = navigation.view.convert(navigation.view.bounds, to: view)
            // The session's column runs under the sidebar: the banner keeps to the part beside it.
            if let sidebar = viewController(for: .primary)?.navigationController?.view, sidebar.window != nil, !sidebar.isHidden {
                let edge = sidebar.convert(sidebar.bounds, to: view).maxX
                if edge > column.minX, edge < column.maxX { column = CGRect(x: edge, y: column.minY, width: column.maxX - edge, height: column.height) }
            }
            return (bar.maxY + 8, column)
        }
        // Under the bar's row of buttons, over the large title if one shows. With the title
        // inline, as in landscape, the bar is only its row, however tall that is.
        let row: CGFloat = 44
        if let navigation = viewController(for: .primary)?.navigationController, navigation.view.window != nil {
            let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: view)
            return (min(bar.maxY, bar.minY + row) + 8, view.bounds)
        }
        return (view.safeAreaInsets.top + row + 8, view.bounds)
    }

    // MARK: Keyboard

    public override func viewDidLoad() {
        super.viewDidLoad()
        banners.placement = { [weak self] in self?.bannerPlacement() }
    }

    public override var canBecomeFirstResponder: Bool { true }
    private var didAppear = false

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // So the key commands work before anything else takes the keyboard.
        if !didAppear { becomeFirstResponder() }
        didAppear = true
    }

    // The menu bar's commands, which `LatchAppDelegate.buildMenu(with:)` lists: they reach
    // here through the responder chain, and the open session's through its screen.

    @objc func newSessionCommand() { presentNewSession() }
    @objc func serversCommand() { presentServers() }
    @objc func previousSessionCommand() { step(by: -1) }
    @objc func nextSessionCommand() { step(by: 1) }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(newSessionCommand): !servers.servers.isEmpty && presentedViewController == nil
        case #selector(serversCommand): presentedViewController == nil
        case #selector(previousSessionCommand), #selector(nextSessionCommand):
            !library.orderedSessions.isEmpty && presentedViewController == nil
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    /// The open session's commands work from the menu bar wherever the keyboard is, as long
    /// as nothing is presented over it: the session screen may not be in the responder chain,
    /// as when the list has the focus.
    public override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if SessionDetailViewController.menuActions.contains(action), presentedViewController == nil,
           let screen = shown?.controller as? SessionDetailViewController, screen.viewIfLoaded?.window != nil,
           screen.canPerformAction(action, withSender: sender) {
            return screen
        }
        return super.target(forAction: action, withSender: sender)
    }
}

/// The secondary column before a session is chosen. Never seen on iPhone, where the
/// collapsed stack starts at the sessions list. While there is no server it explains
/// pairing, alone: the sidebar beside it stays empty rather than say it twice.
final class SessionPlaceholderViewController: UIViewController {
    var hasServers = true {
        didSet { if hasServers != oldValue, isViewLoaded { refresh() } }
    }
    var onAddServer: () -> Void = {}
    var onScan: () -> Void = {}
    var onNewSession: () -> Void = {}

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        refresh()
    }

    private func refresh() {
        guard hasServers else {
            return contentUnavailableConfiguration = SessionsViewController.noServers(
                scan: { [weak self] in self?.onScan() }, addServer: { [weak self] in self?.onAddServer() })
        }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "bubble.left.and.text.bubble.right")
        configuration.text = "No Session Selected"
        configuration.secondaryText = "Choose a session, or start one on a server."
        var button = UIButton.Configuration.gray()
        button.title = "New Session"
        button.cornerStyle = .capsule
        configuration.button = button
        configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onNewSession() }
        contentUnavailableConfiguration = configuration
    }
}
