import Foundation
import LatchAgentXPC

/// Entry point for the XPC service embedded in Latch.app.
///
/// One service process hosts every runtime for the containing application. Peers must run as
/// the same user and satisfy the application's code-signing identifier. The service exits when
/// the application does; runtimes are stopped by explicit commands before that.
public enum LatchAgentServiceHost {
    /// Bundle identifier of the application allowed to connect.
    public static let clientIdentifier = "sh.latch.mac"

    /// The listener holds its delegate weakly; keep the host alive for the process lifetime.
    nonisolated(unsafe) private static var host: LatchAgentXPCHost?

    public static func main() -> Never {
        let host = LatchAgentXPCHost(codeSigningRequirement: "identifier \"\(clientIdentifier)\"")
        Self.host = host
        let listener = NSXPCListener.service()
        listener.delegate = host
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await host.start()
            semaphore.signal()
        }
        semaphore.wait()
        listener.resume()
        // NSXPCListener.service() never returns; dispatchMain keeps the process alive regardless.
        dispatchMain()
    }
}
