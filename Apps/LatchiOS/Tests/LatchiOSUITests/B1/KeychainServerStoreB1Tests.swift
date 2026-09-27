import LatchRemoteProtocol
import LatchSessionKit
import Security
import XCTest
@testable import LatchiOSUI

@MainActor
final class KeychainServerStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try B1.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testProfilesRoundTripWithTheirTokensKeptApart() throws {
        let vault = InMemoryTokenVault()
        let store = KeychainServerStore(directory: directory, vault: vault)
        XCTAssertEqual(store.servers, [])
        XCTAssertNil(store.problem)
        var vps = B1.server("vps", command: "agent acp")
        vps.allowUnencryptedNetwork = true
        let mini = B1.server("mini", port: 9000)
        try store.save(vps)
        try store.save(mini)

        let reopened = KeychainServerStore(directory: directory, vault: vault)
        XCTAssertEqual(reopened.servers, [vps, mini])
        let file = directory.appendingPathComponent(KeychainServerStore.fileName)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(vps.token.rawValue), "The token lives in the Keychain, never in the file")
        XCTAssertTrue(text.contains("agent acp"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testSavingReplacesByIDAndRemovingForgetsTheToken() throws {
        let vault = InMemoryTokenVault()
        let store = KeychainServerStore(directory: directory, vault: vault)
        var vps = B1.server("vps")
        try store.save(vps)
        vps.name = "Renamed"
        vps.token = .generate()
        try store.save(vps)
        XCTAssertEqual(store.servers, [vps])
        XCTAssertEqual(try vault.token(for: vps.id), vps.token)

        try store.remove(id: vps.id)
        XCTAssertEqual(store.servers, [])
        XCTAssertNil(try vault.token(for: vps.id))
        XCTAssertEqual(KeychainServerStore(directory: directory, vault: vault).servers, [])
    }

    func testChangesAreBroadcast() throws {
        let store = KeychainServerStore(directory: directory, vault: InMemoryTokenVault())
        let saved = expectation(forNotification: .serverStoreDidChange, object: store)
        try store.save(B1.server("vps"))
        wait(for: [saved], timeout: 1)
    }

    /// A backup restored onto another device brings the file but not the tokens: the servers
    /// are named, skipped, and kept for their tokens to be entered again under the same ID.
    func testAProfileWithoutItsTokenIsReportedAndKept() throws {
        let vault = InMemoryTokenVault()
        let store = KeychainServerStore(directory: directory, vault: vault)
        let vps = B1.server("vps")
        let mini = B1.server("mini")
        try store.save(vps)
        try store.save(mini)
        vault.removeToken(for: vps.id)

        let restored = KeychainServerStore(directory: directory, vault: vault)
        XCTAssertEqual(restored.servers, [mini])
        XCTAssertEqual(restored.missingTokens.map(\.id), [vps.id])
        XCTAssertEqual(restored.problem,
                       "The token for “vps” is not on this device. Edit the server and enter its token again.")
        XCTAssertNil(restored.fileProblem, "The file was read; it can still be changed")

        // Another server's change keeps the one without a token in the file.
        try restored.save(B1.server("third"))
        XCTAssertEqual(KeychainServerStore(directory: directory, vault: vault).missingTokens.map(\.id), [vps.id])

        // Entering the token again under the same ID brings it back.
        var again = vps
        again.token = .generate()
        try restored.save(again)
        XCTAssertTrue(restored.missingTokens.isEmpty)
        XCTAssertNil(restored.problem)
        XCTAssertEqual(KeychainServerStore(directory: directory, vault: vault).server(id: vps.id)?.token, again.token)
    }

    func testAnUnreadableFileIsNeverOverwritten() throws {
        let file = directory.appendingPathComponent(KeychainServerStore.fileName)
        try Data("{ not json".utf8).write(to: file)
        let store = KeychainServerStore(directory: directory, vault: InMemoryTokenVault())
        XCTAssertEqual(store.fileProblem, "Saved servers could not be read.")
        XCTAssertEqual(store.problem, store.fileProblem)
        XCTAssertThrowsError(try store.save(B1.server("vps"))) { XCTAssertEqual($0 as? ServerStoreError, .saveBlocked) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ not json")

        // Moved aside, the next reload starts a new list.
        try FileManager.default.removeItem(at: file)
        store.reload()
        XCTAssertNil(store.problem)
        XCTAssertNoThrow(try store.save(B1.server("vps")))
    }

    /// The real Keychain. Without an app host, as when these tests run from the package, the
    /// Simulator refuses every Keychain call for want of an entitlement; the test says so.
    func testTheKeychainVaultStoresOneGenericPasswordPerServer() throws {
        let vault = KeychainTokenVault(service: "dev.latchapp.ios.server.tests")
        let id = UUID()
        let token = LatchRemoteToken.generate()
        do {
            try vault.setToken(token, for: id)
        } catch {
            guard error.status != errSecMissingEntitlement else {
                throw XCTSkip("The Keychain needs an app host in the Simulator")
            }
            throw error
        }
        defer { vault.removeToken(for: id) }
        XCTAssertEqual(try vault.token(for: id), token)
        let replacement = LatchRemoteToken.generate()
        try vault.setToken(replacement, for: id)
        XCTAssertEqual(try vault.token(for: id), replacement)

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: vault.service, kSecAttrAccount as String: id.uuidString,
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        vault.removeToken(for: id)
        XCTAssertNil(try vault.token(for: id))
    }

    /// An unsigned Simulator build cannot use the Keychain, so its tokens go in a private file.
    func testUnsignedSimulatorBuildsKeepTokensInAPrivateFile() throws {
        let vault = TokenFileVault(directory: directory)
        let store = KeychainServerStore(directory: directory, vault: vault)
        let vps = B1.server("vps")
        try store.save(vps)
        XCTAssertEqual(KeychainServerStore(directory: directory, vault: TokenFileVault(directory: directory)).servers, [vps])
        let file = directory.appendingPathComponent(TokenFileVault.fileName)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent(KeychainServerStore.fileName), encoding: .utf8)
            .contains(vps.token.rawValue))
        try store.remove(id: vps.id)
        XCTAssertNil(try vault.token(for: vps.id))

        // The app picks the file only where the Keychain refuses for want of an entitlement.
        var probe: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: KeychainTokenVault.service,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        let unsigned = SecItemCopyMatching(query as CFDictionary, &probe) == errSecMissingEntitlement
        let chosen = DeviceTokenVault.make(directory: directory)
        XCTAssertEqual(chosen is TokenFileVault, unsigned)
        XCTAssertEqual(chosen is KeychainTokenVault, !unsigned)
    }
}
