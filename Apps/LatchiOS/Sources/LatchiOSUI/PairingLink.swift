import Foundation
import LatchRemoteProtocol

/// A `latch://host:port?token=…` URL the system opened the app with: from the Camera app
/// reading a QR code, from AirDrop, or a tapped link.
enum PairingLink {
    static let scheme = "latch"

    /// What the URL says, or why it is not a server Latch can add; `nil` when it is not a
    /// `latch://` URL at all, which Latch leaves alone.
    static func parse(_ url: URL) -> Result<LatchRemotePairing, LatchRemotePairingError>? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        do {
            return .success(try LatchRemotePairing(parsing: url.absoluteString))
        } catch let error as LatchRemotePairingError {
            return .failure(error)
        } catch {
            // `init(parsing:)` throws nothing else.
            return .failure(.invalidScheme)
        }
    }
}
