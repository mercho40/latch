import Foundation
import LatchRemoteProtocol
import XCTest
@testable import LatchSessionKit

@MainActor
final class ServerProfileTests: XCTestCase {
    private func profile(_ name: String = "vps", customCommand: String = "") -> ServerProfile {
        ServerProfile(name: name, host: "vps.example.ts.net", port: 7428, token: LatchRemoteToken.generate(),
                      allowUnencryptedNetwork: true, customCommand: customCommand)
    }

    func testTheTokenIsInNoDescriptionOrDump() throws {
        let server = profile()
        let secret = server.token.rawValue
        var dumped = ""
        dump(server, to: &dumped)
        var dumpedList = ""
        dump([server], to: &dumpedList)
        for text in [String(describing: server), String(reflecting: server), "\(server)", dumped, dumpedList,
                     String(describing: Mirror(reflecting: server).children.map(\.value))] {
            XCTAssertFalse(text.contains(secret), "Token leaked into: \(text)")
            XCTAssertFalse(text.contains(String(secret.dropFirst(LatchRemoteToken.prefix.count))))
        }
        XCTAssertTrue(dumped.contains("vps.example.ts.net"), "The rest of the profile is still described")
    }

    /// A store that keeps tokens apart reads and writes the rest in the whole profile's form.
    func testTheStoredFormIsTheWholeFormWithoutItsToken() throws {
        let server = profile(customCommand: "agent --acp")
        let whole = try JSONEncoder().encode(server)
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: whole), server)

        let stored = try JSONDecoder().decode(ServerProfile.Stored.self, from: whole)
        XCTAssertEqual(stored, ServerProfile.Stored(server))
        let apart = try JSONEncoder().encode(stored)
        XCTAssertFalse(String(decoding: apart, as: UTF8.self).contains(server.token.rawValue))
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.Stored.self, from: apart).profile(token: server.token), server)
        XCTAssertThrowsError(try JSONDecoder().decode(ServerProfile.self, from: apart), "A whole profile needs its token")

        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"vps","host":"vps","port":7428}"#.utf8)
        let defaults = try JSONDecoder().decode(ServerProfile.Stored.self, from: old)
        XCTAssertFalse(defaults.allowUnencryptedNetwork)
        XCTAssertEqual(defaults.customCommand, "")
    }

    /// Through a TLS proxy the connection is always encrypted, and an older Latch that reads
    /// the profile as plain TCP must not find the token allowed onto an unencrypted network.
    func testOnlyTCPKeepsAnUnencryptedNetwork() throws {
        var server = ServerProfile(name: "dev", host: "latch.example.com", transport: .webSocket, token: .generate(),
                                   allowUnencryptedNetwork: true)
        XCTAssertFalse(server.allowUnencryptedNetwork)
        XCTAssertEqual(server.port, 443)
        server.allowUnencryptedNetwork = true
        XCTAssertFalse(server.allowUnencryptedNetwork)
        server.transport = .tcp
        server.allowUnencryptedNetwork = true
        XCTAssertTrue(server.allowUnencryptedNetwork)
        server.transport = .webSocket
        XCTAssertFalse(server.allowUnencryptedNetwork)
        let stored = String(decoding: try JSONEncoder().encode(server), as: UTF8.self)
        XCTAssertTrue(stored.contains(#""allowUnencryptedNetwork":false"#), stored)
        XCTAssertTrue(stored.contains(#""transport":"wss""#), stored)

        let newer = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"vps","host":"vps","port":7428,"transport":"quic"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.Stored.self, from: newer).transport, .tcp)
    }

    func testAStoreBroadcastsItsChanges() throws {
        let store = InMemoryServerStore()
        let changed = expectation(forNotification: .serverStoreDidChange, object: store)
        try store.save(profile())
        wait(for: [changed], timeout: 1)
    }
}
