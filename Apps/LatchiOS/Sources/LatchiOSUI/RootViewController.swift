import LatchRemoteProtocol
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

/// The window's root: sessions in the primary column and the open session in the secondary.
/// On iPhone and in compact width the columns collapse into one navigation stack, which
/// starts at the sessions list.
public final class RootViewController: UISplitViewController, UISplitViewControllerDelegate {
    let sessions = SessionsViewController()
    let placeholder = SessionPlaceholderViewController()

    /// Set by the scene before it opens any link. A link that arrives while this is `nil`
    /// waits here and is handed over as soon as it is set, so one that launched the app is
    /// not lost to the order things start in.
    public weak var serverDelegate: (any RootViewControllerDelegate)? {
        didSet { deliverPendingLink() }
    }
    private var pendingLink: Result<LatchRemotePairing, LatchRemotePairingError>?

    public init() {
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        // UIKit wraps each column in its own navigation controller.
        setViewController(sessions, for: .primary)
        setViewController(placeholder, for: .secondary)
        sessions.onAddServer = { [weak self] in
            guard let self else { return }
            serverDelegate?.rootViewControllerDidRequestAddServer(self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    /// Collapsing shows the sessions list, not an empty session.
    public func splitViewController(_ svc: UISplitViewController,
                                    topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column)
        -> UISplitViewController.Column {
        .primary
    }
}
