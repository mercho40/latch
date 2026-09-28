import Foundation
import LatchRemoteClient
import LatchSessionKit

/// What this device remembers about its servers beyond their profiles, in the app's defaults:
/// each server's home folder, as the last handshake reported it, so a path on it reads as
/// `~/latch` rather than `/home/simon/latch`; and where each removed server was, so adding it
/// back can offer to reconnect the sessions it left behind. Neither is secret, and both are
/// kept by address: the home belongs to the machine, whatever the profile is called.
@MainActor
final class ServerMemory {
    private let defaults: UserDefaults
    private static let homesKey = "ServerHomes"
    private static let removedKey = "RemovedServers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Home folders

    /// Keeps the home a handshake with the server at `address` reported.
    func recordHome(_ home: String, address: String) {
        let home = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/"), home.count > 1 else { return }
        var homes = self.homes
        guard homes[address] != home else { return }
        homes[address] = home
        defaults.set(homes, forKey: Self.homesKey)
    }

    /// Keeps the home a handshake made with `options` reported.
    func recordHome(_ home: String, options: LatchRemoteConnectionOptions) {
        let host = options.host
        recordHome(home, address: host.contains(":") ? "[\(host)]:\(options.port)" : "\(host):\(options.port)")
    }

    /// A server check that keeps the home each handshake reports, so every Test Connection,
    /// New Session and Servers check leaves it for the rest of the app.
    func recording(_ check: @escaping ServerCheck) -> ServerCheck {
        { [weak self] options in
            let info = try await check(options)
            await self?.recordHome(info.home, options: options)
            return info
        }
    }

    func home(for server: ServerProfile?) -> String? {
        server.flatMap { homes[$0.address] }
    }

    private var homes: [String: String] {
        defaults.dictionary(forKey: Self.homesKey) as? [String: String] ?? [:]
    }

    /// `path` with the server's home written as `~`: the home itself is `~`, and a folder in
    /// it `~/rest`. Anything else, and every path when the home is unknown, stays as it is.
    nonisolated static func displayPath(_ path: String, home: String?) -> String {
        guard var home, home.hasPrefix("/"), home.count > 1 else { return path }
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The reverse, for a folder typed as `~/rest`: the absolute path when the home is known.
    /// Unknown, the tilde stays, and the server resolves it when the agent launches.
    nonisolated static func expandedPath(_ path: String, home: String?) -> String {
        guard let home, home.hasPrefix("/"), path == "~" || path.hasPrefix("~/") else { return path }
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        return base + path.dropFirst()
    }

    func displayPath(_ path: String, on server: ServerProfile?) -> String {
        Self.displayPath(path, home: home(for: server))
    }

    // MARK: Removed servers

    /// Where a removed server was, and what it was called.
    struct RemovedServer: Codable, Equatable {
        var name: String
        var address: String
    }

    func recordRemoval(of server: ServerProfile) {
        var removed = removedServers
        removed[server.id.uuidString] = RemovedServer(name: server.name, address: server.address)
        save(removed)
    }

    func removedServer(id: UUID) -> RemovedServer? { removedServers[id.uuidString] }

    func forgetRemoval(of id: UUID) {
        var removed = removedServers
        guard removed.removeValue(forKey: id.uuidString) != nil else { return }
        save(removed)
    }

    private var removedServers: [String: RemovedServer] {
        guard let data = defaults.data(forKey: Self.removedKey) else { return [:] }
        return (try? JSONDecoder().decode([String: RemovedServer].self, from: data)) ?? [:]
    }

    private func save(_ removed: [String: RemovedServer]) {
        defaults.set(try? JSONEncoder().encode(removed), forKey: Self.removedKey)
    }
}
