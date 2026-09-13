import Foundation
import LatchAgentCore

/// Listener delegate that hosts one `LatchAgentService` for authorized XPC peers.
///
/// Every accepted connection shares the service, its runtimes, and the event hub.
/// The host never shuts the service down on its own; call `shutdown` before exit.
public final class LatchAgentXPCHost: NSObject, NSXPCListenerDelegate, Sendable {
    public typealias Authorization = @Sendable (NSXPCConnection) -> Bool

    public let service: LatchAgentService
    private let hub: LatchAgentXPCEventHub
    private let adapter: LatchAgentXPCAdapter
    private let authorize: Authorization
    private let codeSigningRequirement: String?

    /// - Parameters:
    ///   - authorize: Synchronous admission check run before any interface is exported.
    ///   - codeSigningRequirement: Optional requirement applied to every accepted peer
    ///     before it is resumed, so unqualified callers cannot invoke the service.
    public init(
        service: LatchAgentService = LatchAgentService(),
        codeSigningRequirement: String? = nil,
        authorize: @escaping Authorization = LatchAgentXPCHost.sameUser
    ) {
        self.service = service
        self.hub = LatchAgentXPCEventHub(events: service.events)
        self.adapter = LatchAgentXPCAdapter(service: service)
        self.authorize = authorize
        self.codeSigningRequirement = codeSigningRequirement
        super.init()
    }

    /// Only the invoking user's processes may connect.
    public static let sameUser: Authorization = { $0.effectiveUserIdentifier == geteuid() }

    /// Start consuming service events. Call once before resuming the listener.
    public func start() async { await hub.start() }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard authorize(connection) else { return false }
        if let codeSigningRequirement {
            connection.setCodeSigningRequirement(codeSigningRequirement)
        }
        connection.exportedInterface = LatchAgentXPCAdapter.interface()
        connection.exportedObject = adapter
        // Objective-C does not express ownership transfer; the host never touches it again.
        nonisolated(unsafe) let transferred = connection
        Task { [hub] in
            // Attach failures (hub stopped) invalidate the connection inside the hub.
            _ = try? await hub.attach(transferred)
        }
        return true
    }

    /// Stops every runtime, then disconnects all peers. The host cannot be restarted.
    public func shutdown() async {
        await service.shutdown()
        await hub.shutdown()
    }
}
