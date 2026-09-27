#if canImport(Network)
import LatchRemoteProtocol

/// One connection and handshake, then a clean close: Settings' "Test Connection", and the
/// server's home directory for a new remote session's path.
public enum LatchRemoteServerCheck {
    /// The welcome's server description, or the `LatchRemoteClientError` that prevented it.
    public static func run(_ options: LatchRemoteConnectionOptions) async throws -> LatchRemoteServerInfo {
        let connection = LatchRemoteConnection(options: options)
        defer { connection.close() }
        connection.start()
        return try await connection.waitUntilReady().server
    }
}
#endif
