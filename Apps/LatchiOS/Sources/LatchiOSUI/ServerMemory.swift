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
        recordHome(home, address: Self.address(options))
    }

    private static func address(_ options: LatchRemoteConnectionOptions) -> String {
        ServerProfile.address(host: options.host, port: options.port, transport: options.transport)
    }

    /// A server check that keeps the home each handshake with a server in `servers` reports,
    /// so every New Session and Servers check, and Test Connection on a saved server, leaves it
    /// for the rest of the app. A server only being tried, as from a pairing link, leaves
    /// nothing behind: once added, its first listing records its home.
    func recording(_ check: @escaping ServerCheck, savedIn servers: any ServerStore) -> ServerCheck {
        let saved = SavedServers(servers)
        return { [weak self] options in
            let info = try await check(options)
            await self?.recordHome(info.home, options: options, ifSavedIn: saved)
            return info
        }
    }

    private func recordHome(_ home: String, options: LatchRemoteConnectionOptions, ifSavedIn saved: SavedServers) {
        let address = Self.address(options)
        guard saved.store.servers.contains(where: { $0.address == address }) else { return }
        recordHome(home, address: address)
    }

    /// The saved servers, held where a check, which must be `Sendable`, can reach them.
    @MainActor private final class SavedServers {
        let store: any ServerStore
        init(_ store: any ServerStore) { self.store = store }
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
    /// Unknown, the tilde stays for the server to resolve when the agent launches; it takes
    /// only `~/…`, so the home itself goes as `~/`.
    nonisolated static func expandedPath(_ path: String, home: String?) -> String {
        guard let home, home.hasPrefix("/") else { return path == "~" ? "~/" : path }
        guard path == "~" || path.hasPrefix("~/") else { return path }
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
