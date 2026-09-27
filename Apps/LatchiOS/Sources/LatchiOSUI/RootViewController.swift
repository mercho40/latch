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
         defaults: UserDefaults = .standard,
         makeSessionViewController: @escaping SessionViewControllerFactory = SessionDetailViewController.make) {
        self.library = library
        self.servers = servers
        self.check = check
        self.badge = badge
        self.makeSessionViewController = makeSessionViewController
        sessions = SessionsViewController(library: library, defaults: defaults)
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        // UIKit wraps each column in its own navigation controller.
        setViewController(sessions, for: .primary)
        placeholder.isEmpty = servers.servers.isEmpty
        setViewController(placeholder, for: .secondary)
        wire()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func wire() {
        sessions.onAddServer = { [weak self] in
            guard let self else { return }
            serverDelegate?.rootViewControllerDidRequestAddServer(self)
        }
        sessions.onNewSession = { [weak self] serverID in self?.presentNewSession(serverID: serverID) }
        sessions.onShowServers = { [weak self] in self?.presentServers() }
        sessions.onServerSettings = { [weak self] id in self?.presentServerEditor(serverID: id) }
        sessions.onOpen = { [weak self] session in self?.show(session) }
        sessions.confirm = { [weak self] confirmation, go in self?.confirm(confirmation, go) }
        library.isSessionVisible = { [weak self] id in self?.isShowing(id) ?? false }
        library.onChange = { [weak self] in self?.libraryChanged() }
        library.onSessionChange = { [weak self] session in self?.sessions.sessionChanged(session) }
        library.onAttention = { [weak self] session, attention in self?.announce(session, attention) }
        library.onApprovalCountChange = { [weak self] count in self?.badge?.update(count) }
    }

    // MARK: Links

    /// Forwards the first `latch://` link among `urls`: the Add Server sheet confirms one
    /// server at a time. Any other scheme is ignored.
    func open(_ urls: [URL]) {
        guard let link = urls.lazy.compactMap(PairingLink.parse).first else { return }
        pendingLink = link
        deliverPendingLink()
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

    /// Expanding again, the open session is selected beside it.
    public func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        sessions.selectShownSession()
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

    /// Shows what was on screen when the app last closed, where there is room beside the list.
    func restoreSelection() {
        guard traitCollection.horizontalSizeClass == .regular, shown == nil,
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
        placeholder.isEmpty = servers.servers.isEmpty
        // A renamed server's name, in the open session's title.
        if let shown, let screen = shown.controller as? SessionDetailViewController { screen.follow(shown.session, in: self) }
        // A removed session's screen goes with it, once any push or pop has finished: the split
        // view asserts when its columns change in the middle of one.
        guard let shown, library.session(id: shown.session.id) !== shown.session else { return }
        if let transition = shown.controller.transitionCoordinator ?? sessions.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.libraryChanged() }
            return
        }
        self.shown = nil
        // Made anew, as when its server's token was entered again: the new one takes its place
        // if it was on screen, and otherwise the next opening shows it.
        if let replacement = library.session(id: shown.session.id) {
            if shown.controller.viewIfLoaded?.window != nil { show(replacement) }
            return
        }
        placeholder = SessionPlaceholderViewController()
        placeholder.isEmpty = servers.servers.isEmpty
        setViewController(placeholder, for: .secondary)
        if isCollapsed { show(.primary) }
    }

    /// ⌘[ and ⌘]: the next session in the list's order.
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
        let controller = NewSessionViewController(servers: servers.servers, serverID: serverID, check: check)
        controller.onCreate = { [weak self] choice in
            guard let self else { return }
            show(library.create(serverID: choice.serverID, path: choice.path, agent: choice.agent))
        }
        let navigation = UINavigationController(rootViewController: controller)
        if traitCollection.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .formSheet
            // Three rows need no more than this; a full form sheet would be mostly empty.
            navigation.preferredContentSize = CGSize(width: 540, height: 400)
        } else if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
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
        return navigation
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
        editor.onSave = { [weak self] server in
            guard let self else { return }
            Task { await self.library.refreshRuntimes(for: [server.id]) }
        }
        return ServerEditorViewController.sheet(editor)
    }

    private func confirm(_ confirmation: SessionsViewController.Confirmation, _ go: @escaping () -> Void) {
        let device = UIDevice.current.model
        let alert: UIAlertController
        switch confirmation {
        case let .remove(title, server):
            alert = UIAlertController(
                title: "Remove “\(title)” from this \(device)?",
                message: "The agent keeps running on \(server). To open it again, find it under “On \(server)”.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Remove", style: .default) { _ in go() })
        case let .stop(title, server):
            alert = UIAlertController(
                title: "Stop the agent?",
                message: "The agent in “\(title)” stops on \(server), and a turn in progress ends. The conversation stays on this \(device).",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Stop Agent", style: .destructive) { _ in go() })
        }
        presentOnTop(alert)
    }

    // MARK: Attention

    private func announce(_ session: PhoneSession, _ attention: SessionLibrary.Attention) {
        let waiting = SessionStatusView.mark(for: .waiting)
        let (message, symbol, tint): (String, String, UIColor) = switch attention {
        case .needsApproval: ("The agent is waiting for a permission decision.",
                              waiting?.symbol ?? "exclamationmark.circle.fill", waiting?.color ?? .systemOrange)
        case .finished: ("The agent finished its turn.", "checkmark.circle.fill", .systemGreen)
        case .stoppedOnServer: ("The agent was stopped on its server.", "stop.circle.fill", .secondaryLabel)
        }
        banners.show(title: session.title, message: message, symbol: symbol, tint: tint) { [weak self, weak session] in
            guard let self, let session, self.library.session(id: session.id) != nil else { return }
            self.show(session)
        }
    }

    var attentionBanner: AttentionBannerView? { banners.current }

    // MARK: Keyboard

    public override var canBecomeFirstResponder: Bool { true }
    private var didAppear = false

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // So the key commands work before anything else takes the keyboard.
        if !didAppear { becomeFirstResponder() }
        didAppear = true
    }

    public override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "New Session", action: #selector(newSessionCommand), input: "n", modifierFlags: .command),
         UIKeyCommand(title: "Servers", action: #selector(serversCommand), input: ",", modifierFlags: .command),
         UIKeyCommand(title: "Previous Session", action: #selector(previousSessionCommand), input: "[", modifierFlags: .command),
         UIKeyCommand(title: "Next Session", action: #selector(nextSessionCommand), input: "]", modifierFlags: .command)]
    }

    @objc func newSessionCommand() { presentNewSession() }
    @objc func serversCommand() { presentServers() }
    @objc func previousSessionCommand() { step(by: -1) }
    @objc func nextSessionCommand() { step(by: 1) }
}

/// The secondary column before a session is chosen. Never seen on iPhone, where the
/// collapsed stack starts at the sessions list. Blank while there is no server: the list
/// beside it explains pairing, and there is nothing to select.
final class SessionPlaceholderViewController: UIViewController {
    var isEmpty = false {
        didSet { if isEmpty != oldValue, isViewLoaded { refresh() } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        refresh()
    }

    private func refresh() {
        guard !isEmpty else { return contentUnavailableConfiguration = nil }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = "No Session Selected"
        contentUnavailableConfiguration = configuration
    }
}
