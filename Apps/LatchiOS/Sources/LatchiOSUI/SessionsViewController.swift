import UIKit

/// The primary column: every session on every server. With no server added it explains how
/// to pair one and offers Add Server.
final class SessionsViewController: UICollectionViewController {
    /// Called when the user taps Add Server; the root forwards it to its server delegate.
    var onAddServer: (() -> Void)?

    init() {
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout { _, environment in
            // A sidebar beside the session on iPad; grouped rows when the list fills the screen.
            let appearance: UICollectionLayoutListConfiguration.Appearance =
                environment.traitCollection.userInterfaceIdiom == .pad ? .sidebar : .insetGrouped
            return .list(using: UICollectionLayoutListConfiguration(appearance: appearance),
                         layoutEnvironment: environment)
        })
        title = "Sessions"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        contentUnavailableConfiguration = Self.noServers { [weak self] in self?.addServer() }
    }

    func addServer() {
        onAddServer?()
    }

    static func noServers(addServer: @escaping () -> Void) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "server.rack")
        configuration.text = "No servers yet"
        configuration.secondaryText = """
            Run latch-server pair --host <name> on the machine your agents run on, \
            then add the server it prints.
            """
        var button = UIButton.Configuration.filled()
        button.title = "Add Server"
        configuration.button = button
        configuration.buttonProperties.primaryAction = UIAction { _ in addServer() }
        return configuration
    }
}

/// The secondary column before a session is chosen. Never seen on iPhone, where the
/// collapsed stack starts at the sessions list.
final class SessionPlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = "No Session Selected"
        contentUnavailableConfiguration = configuration
    }
}
