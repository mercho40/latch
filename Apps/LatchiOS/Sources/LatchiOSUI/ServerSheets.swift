import LatchRemoteProtocol
import UIKit

/// The root's server delegate in the app: Add Server opens the editor, and a pairing link
/// opens it filled in. A link to a server already added offers to update that server's
/// token instead of adding it twice, and one to a server whose token is missing fills that
/// server in. Either way nothing is saved until the user taps Save.
@MainActor
final class ServerSheets: RootViewControllerDelegate {
    func rootViewControllerDidRequestAddServer(_ root: RootViewController) {
        root.presentServerEditor()
    }

    func rootViewController(_ root: RootViewController,
                            didOpenPairingLink link: Result<LatchRemotePairing, LatchRemotePairingError>) {
        switch link {
        case let .failure(error):
            let alert = UIAlertController(title: "This link can’t add a server", message: Self.explanation(error),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            root.presentOnTop(alert)
        case let .success(pairing):
            let matches = { (host: String, port: UInt16) in host.lowercased() == pairing.host.lowercased() && port == pairing.port }
            // A server saved without its token, as after a backup restored onto a new device,
            // takes the link's token under its own ID, so its sessions come back.
            if let missing = root.servers.missingTokens.first(where: { matches($0.host, $0.port) }) {
                return root.presentServerEditor(serverID: missing.id, pairing: pairing)
            }
            guard let existing = root.servers.servers.first(where: { matches($0.host, $0.port) }) else {
                return root.presentServerEditor(pairing: pairing)
            }
            let alert = UIAlertController(
                title: "“\(existing.name)” is already added",
                message: "A server at \(existing.address) is already in Servers. Update its token, or add the link as another server.",
                preferredStyle: .alert)
            let update = UIAlertAction(title: "Update Token", style: .default) { _ in
                root.presentServerEditor(serverID: existing.id, pairing: pairing)
            }
            alert.addAction(update)
            alert.addAction(UIAlertAction(title: "Add as New Server", style: .default) { _ in
                root.presentServerEditor(pairing: pairing)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.preferredAction = update
            root.presentOnTop(alert)
        }
    }

    static func explanation(_ error: LatchRemotePairingError) -> String {
        switch error {
        case .invalidScheme: "It is not a Latch pairing link."
        case .invalidHost: "Its host is not a DNS name or an IP address."
        case .invalidPort: "Its port must be a number from 1 to 65535."
        case .missingToken: "It has no token. Run “latch-server pair” on the server for a complete link."
        case .invalidToken: "Its token is not a Latch token. Run “latch-server pair” on the server for a new link."
        }
    }
}
