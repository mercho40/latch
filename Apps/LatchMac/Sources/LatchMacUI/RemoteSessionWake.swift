import AppKit
import LatchRemoteClient
import LatchSessionKit

extension ChannelRemoteSessionConnector {
    /// A connector that also checks every link when this Mac wakes: one that slept has usually
    /// lost its connections without hearing so. `notificationCenter` is the one that posts
    /// `didWakeNotification`; tests pass their own.
    convenience init(servers: any ServerStore, backoff: LatchRemoteBackoff = LatchRemoteBackoff(),
                     firstConnectionLimit: Duration = .seconds(15), notificationCenter: NotificationCenter) {
        self.init(servers: servers, backoff: backoff, firstConnectionLimit: firstConnectionLimit)
        notificationCenter.addObserver(self, selector: #selector(probeAll),
                                       name: NSWorkspace.didWakeNotification, object: nil)
    }
}
