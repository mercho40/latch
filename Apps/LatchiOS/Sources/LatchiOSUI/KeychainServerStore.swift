import Foundation
import LatchRemoteProtocol
import LatchSessionKit
import Security

/// A server store as the Servers list needs it: which saved servers lack their token, and
/// whether the file could be read at all, apart from each other.
@MainActor
protocol PhoneServerStore: ServerStore {
    /// Profiles saved without a token this device can read; not in `servers`.
    var missingTokens: [ServerProfile.Stored] { get }
    /// The file could not be read, so nothing may be saved over it.
    var fileProblem: String? { get }
}

extension InMemoryServerStore: PhoneServerStore {
    var missingTokens: [ServerProfile.Stored] { [] }
    var fileProblem: String? { nil }
}

/// Where each server's token is kept, by server ID. The app uses the Keychain; tests that
/// run without an app host, where the Keychain refuses every call, use `InMemoryTokenVault`.
@MainActor
protocol TokenVault: AnyObject {
    /// The token, or nil when there is none, or none Latch can read.
    func token(for id: UUID) throws(TokenVaultFailure) -> LatchRemoteToken?
    func setToken(_ token: LatchRemoteToken, for id: UUID) throws(TokenVaultFailure)
    func removeToken(for id: UUID)
}

struct TokenVaultFailure: Error, Equatable {
    let status: OSStatus
}

/// One generic password per server: service `dev.latchapp.ios.server`, account the server's
/// ID. Readable after the first unlock, so a session can reconnect while the phone is locked,
/// and never restored to another device from a backup.
@MainActor
final class KeychainTokenVault: TokenVault {
    static let service = "dev.latchapp.ios.server"
    let service: String

    init(service: String = KeychainTokenVault.service) { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    func token(for id: UUID) throws(TokenVaultFailure) -> LatchRemoteToken? {
        var search = query(id)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenVaultFailure(status: status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return LatchRemoteToken(text)
    }

    func setToken(_ token: LatchRemoteToken, for id: UUID) throws(TokenVaultFailure) {
        let data = Data(token.rawValue.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(id).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TokenVaultFailure(status: status) }
    }

    func removeToken(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

@MainActor
final class InMemoryTokenVault: TokenVault {
    var tokens: [UUID: LatchRemoteToken] = [:]

    func token(for id: UUID) throws(TokenVaultFailure) -> LatchRemoteToken? { tokens[id] }
    func setToken(_ token: LatchRemoteToken, for id: UUID) throws(TokenVaultFailure) { tokens[id] = token }
    func removeToken(for id: UUID) { tokens[id] = nil }
}

/// The vault the app uses: the Keychain, except in a Simulator build made without signing
/// (`CODE_SIGNING_ALLOWED=NO`, as the scripts build), which has no Keychain access group, so
/// every call fails with `errSecMissingEntitlement`. There tokens go in a 0600 file instead,
/// so servers can be added in the Simulator. A device build is always signed and always uses
/// the Keychain.
@MainActor
enum DeviceTokenVault {
    static func make(directory: URL) -> any TokenVault {
        let keychain = KeychainTokenVault()
        #if targetEnvironment(simulator)
        var probe: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychain.service,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        if SecItemCopyMatching(query as CFDictionary, &probe) == errSecMissingEntitlement {
            return TokenFileVault(directory: directory)
        }
        #endif
        return keychain
    }
}

/// Tokens by server ID in `tokens.json`, 0600, for an unsigned Simulator build only.
@MainActor
final class TokenFileVault: TokenVault {
    static let fileName = "tokens.json"
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    private func read() throws(TokenVaultFailure) -> [String: String] {
        do {
            guard let data = try PrivateFile.read(Self.fileName, in: directory, maximumSize: 1024 * 1024) else { return [:] }
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw TokenVaultFailure(status: errSecDecode)
        }
    }

    private func write(_ tokens: [String: String]) throws(TokenVaultFailure) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try PrivateFile.write(try encoder.encode(tokens), as: Self.fileName, in: directory)
        } catch {
            throw TokenVaultFailure(status: errSecIO)
        }
    }

    func token(for id: UUID) throws(TokenVaultFailure) -> LatchRemoteToken? {
        try read()[id.uuidString].flatMap { LatchRemoteToken($0) }
    }

    func setToken(_ token: LatchRemoteToken, for id: UUID) throws(TokenVaultFailure) {
        var tokens = try read()
        tokens[id.uuidString] = token.rawValue
        try write(tokens)
    }

    func removeToken(for id: UUID) {
        guard var tokens = try? read(), tokens[id.uuidString] != nil else { return }
        tokens[id.uuidString] = nil
        try? write(tokens)
    }
}

/// Servers on iOS: each profile without its token in `servers.json` in Application Support,
/// 0600 like the saved sessions, and each token in the Keychain. The app has a stable signing
/// identity here, so unlike on the Mac the Keychain never asks for a token again.
///
/// A profile whose token is gone, as after restoring a backup onto another device, is kept in
/// the file and left out of `servers`; `missingTokens` lists it so the Servers list can offer
/// to enter its token again under the same ID, which reconnects the sessions on it.
@MainActor
final class KeychainServerStore: PhoneServerStore {
    static let fileName = "servers.json"
    static let maximumFileSize = 1024 * 1024

    private struct Library: Codable {
        var version = 1
        var servers: [ServerProfile.Stored]
    }

    private(set) var servers: [ServerProfile] = []
    /// Profiles in the file whose token could not be read.
    private(set) var missingTokens: [ServerProfile.Stored] = []
    /// The file itself could not be read. While set, nothing is written over it.
    private(set) var fileProblem: String?
    private let directory: URL
    private let vault: any TokenVault

    init(directory: URL, vault: any TokenVault) {
        self.directory = directory
        self.vault = vault
        load()
    }

    var problem: String? {
        if let fileProblem { return fileProblem }
        guard !missingTokens.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: missingTokens.map { "“\($0.name)”" })
        return missingTokens.count == 1
            ? "The token for \(names) is not on this device. Edit the server and enter its token again."
            : "The tokens for \(names) are not on this device. Edit each server and enter its token again."
    }

    func save(_ profile: ServerProfile) throws {
        guard fileProblem == nil else { throw ServerStoreError.saveBlocked }
        let previous = try? vault.token(for: profile.id)
        do { try vault.setToken(profile.token, for: profile.id) } catch { throw ServerStoreError.writeFailed }
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        let missing = missingTokens.filter { $0.id != profile.id }
        do {
            try write(updated, missing: missing)
        } catch {
            // The file still names the old token's server, or none; the Keychain goes back to match.
            if let previous { try? vault.setToken(previous, for: profile.id) } else { vault.removeToken(for: profile.id) }
            throw error
        }
        broadcast()
    }

    func remove(id: UUID) throws {
        guard fileProblem == nil else { throw ServerStoreError.saveBlocked }
        try write(servers.filter { $0.id != id }, missing: missingTokens.filter { $0.id != id })
        // After the file: a failed write leaves the server whole rather than without its token.
        vault.removeToken(for: id)
        broadcast()
    }

    /// Reads the file and the Keychain again, as when the Servers list opens: the Keychain is
    /// unavailable before the first unlock, and a file moved aside needs no relaunch.
    func reload() {
        let before = (servers, missingTokens, fileProblem)
        load()
        if before.0 != servers || before.1 != missingTokens || before.2 != fileProblem { broadcast() }
    }

    private func load() {
        let library: Library
        do {
            guard let data = try PrivateFile.read(Self.fileName, in: directory, maximumSize: Self.maximumFileSize) else {
                servers = []
                missingTokens = []
                fileProblem = nil
                return
            }
            library = try JSONDecoder().decode(Library.self, from: data)
            guard library.version == 1 else { throw ServerStoreError.unreadable }
        } catch {
            // Never repeat decoder diagnostics: they can quote the file.
            servers = []
            missingTokens = []
            fileProblem = "Saved servers could not be read."
            return
        }
        fileProblem = nil
        var found: [ServerProfile] = []
        var missing: [ServerProfile.Stored] = []
        for stored in library.servers {
            if let token = try? vault.token(for: stored.id) { found.append(stored.profile(token: token)) }
            else { missing.append(stored) }
        }
        servers = found
        missingTokens = missing
    }

    private func write(_ servers: [ServerProfile], missing: [ServerProfile.Stored]) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            data = try encoder.encode(Library(servers: servers.map(ServerProfile.Stored.init) + missing))
        } catch {
            throw ServerStoreError.writeFailed
        }
        do {
            try PrivateFile.write(data, as: Self.fileName, in: directory)
        } catch {
            throw ServerStoreError.writeFailed
        }
        self.servers = servers
        missingTokens = missing
    }
}
