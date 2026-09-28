import Foundation
import LatchRemoteProtocol
import XCTest
@testable import LatchMacUI
@testable import LatchSessionKit

@MainActor
final class ServerStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ServerStoreTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.appendingPathComponent("Latch")
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func profile(_ name: String = "vps", customCommand: String = "") -> ServerProfile {
        ServerProfile(name: name, host: "vps.example.ts.net", port: 7428, token: LatchRemoteToken.generate(),
                      allowUnencryptedNetwork: true, customCommand: customCommand)
    }

    func testTheFileIsPrivateFromCreationAndStaysPrivateAfterAnUpdate() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent(FileServerStore.fileName)
        // A permissive umask must not widen the file: its mode is set when it is created.
        let previous = umask(0)
        defer { umask(previous) }
        let store = FileServerStore(directory: directory)
        var server = profile()
        try store.save(server)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(directory), 0o700)

        server.customCommand = "my-agent --acp"
        try store.save(server)
        XCTAssertEqual(try permissions(file), 0o600)
        try store.save(profile("second"))
        XCTAssertEqual(try permissions(file), 0o600)
        // No staging file is left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [FileServerStore.fileName])
    }

    func testProfilesRoundTripThroughTheFile() throws {
        let directory = try temporaryDirectory()
        let store = FileServerStore(directory: directory)
        let first = profile("first", customCommand: "agent 'quoted arg'")
        let second = ServerProfile(name: "local", host: "::1", port: 9000, token: LatchRemoteToken.generate())
        try store.save(first)
        try store.save(second)

        let reopened = FileServerStore(directory: directory)
        XCTAssertEqual(reopened.servers, [first, second])
        XCTAssertNil(reopened.problem)
        XCTAssertEqual(reopened.servers[1].address, "[::1]:9000")

        try reopened.remove(id: first.id)
        XCTAssertEqual(FileServerStore(directory: directory).servers, [second])
    }

    func testAMissingFileIsEmptyAndCreatesNothing() throws {
        let directory = try temporaryDirectory()
        XCTAssertEqual(FileServerStore(directory: directory).servers, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAnUnreadableFileIsReportedAndNeverOverwritten() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(FileServerStore.fileName)
        let secret = LatchRemoteToken.generate().rawValue
        let corrupt = Data(#"{"version":1,"servers":[{"token":"\#(secret)""#.utf8)
        try corrupt.write(to: file)

        let store = FileServerStore(directory: directory)
        XCTAssertEqual(store.servers, [])
        let problem = try XCTUnwrap(store.problem)
        XCTAssertFalse(problem.contains(secret))
        XCTAssertThrowsError(try store.save(profile())) { XCTAssertEqual($0 as? ServerStoreError, .saveBlocked) }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testAFileThatBecomesReadableIsReadAgainWithoutARelaunch() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(FileServerStore.fileName)
        try Data("not json".utf8).write(to: file)
        let store = FileServerStore(directory: directory)
        XCTAssertEqual(store.servers, [])
        XCTAssertTrue(try XCTUnwrap(store.problem).contains(FileServerStore.fileName), "The problem names the file")

        // Fixed by hand, as a user moving it aside and restoring a good copy would.
        let kept = profile()
        let elsewhere = try temporaryDirectory()
        try FileServerStore(directory: elsewhere).save(kept)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: elsewhere.appendingPathComponent(FileServerStore.fileName), to: file)

        let added = profile()
        try store.save(added)
        XCTAssertNil(store.problem)
        XCTAssertEqual(store.servers.map(\.id), [kept.id, added.id], "The file's servers are kept, not replaced")
    }
}
