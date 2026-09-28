import Foundation
import LatchRemoteClient
import LatchRemoteProtocol
import LatchSessionKit

/// One connection that asks a server which runtimes it has, then closes: how the sessions
/// list finds agents another device started. Tests substitute a stub.
typealias RuntimeListing = @Sendable (LatchRemoteConnectionOptions) async throws -> [LatchRemoteRuntimeSummary]

enum RemoteRuntimeList {
    static let live: RuntimeListing = live(welcomed: { _, _ in })

    /// The listing, telling `welcomed` of each server's handshake on the way: it carries the
    /// server's home folder, which paths on it are shown against.
    static func live(welcomed: @escaping @Sendable (LatchRemoteConnectionOptions, LatchRemoteWelcome) async -> Void)
        -> RuntimeListing {
        { options in try await list(options, welcomed: welcomed) }
    }

    private static func list(_ options: LatchRemoteConnectionOptions,
                             welcomed: @Sendable (LatchRemoteConnectionOptions, LatchRemoteWelcome) async -> Void)
        async throws -> [LatchRemoteRuntimeSummary] {
        let connection = LatchRemoteConnection(options: options)
        defer { connection.close() }
        connection.start()
        await welcomed(options, try await connection.waitUntilReady())
        guard case let .runtimes(runtimes) = try await connection.request(.listRuntimes, timeout: .seconds(10)) else {
            throw LatchRemoteClientError.closed
        }
        return runtimes
    }
}

/// What the last listing of one server found.
struct ServerRuntimes: Equatable {
    var runtimes: [LatchRemoteRuntimeSummary] = []
    var isLoading = false
    /// Why the server could not be asked, in plain words.
    var failure: String?
    /// The server has answered a listing, so it was reachable then.
    var answered = false
}

/// The folder Latch keeps its files in: Application Support, readable after the first unlock
/// so a session can save while the phone is locked, and excluded from nothing else.
enum AppFiles {
    static var directory: URL {
        let directory = SessionStore.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Files made in the folder take its protection, including each save's replacement.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        return directory
    }
}
