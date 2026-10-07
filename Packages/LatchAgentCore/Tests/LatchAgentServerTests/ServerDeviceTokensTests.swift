import Foundation
import LatchRemoteProtocol
import XCTest
@testable import LatchAgentServer
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class ServerDeviceTokensTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("latch-devices-\(UUID().uuidString)").path
        try ServerConfigDirectory.prepare(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func mode(_ path: String) -> mode_t {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return status.st_mode & 0o777
    }

    private func tokens(_ devices: ServerDeviceTokens) throws -> [String: LatchRemoteToken?] {
        Dictionary(uniqueKeysWithValues: try devices.read().map { ($0.name, try? $0.token.get()) })
    }

    func testNames() {
        for valid in ["phone", "Simon-iPhone_15.pro", "a", String(repeating: "x", count: 64)] {
            XCTAssertTrue(ServerDeviceTokens.isValidName(valid), valid)
        }
        for invalid in ["", ".hidden", "..", "a/b", "../x", "my phone", "née", "x\n", String(repeating: "x", count: 65)] {
            XCTAssertFalse(ServerDeviceTokens.isValidName(invalid), invalid)
        }
    }

    func testNoDirectoryIsNoDevices() throws {
        let devices = ServerDeviceTokens(configDirectory: root)
        XCTAssertEqual(try tokens(devices), [:])
        XCTAssertFalse(try devices.revoke("phone"))
        // Reading creates nothing.
        XCTAssertFalse(FileManager.default.fileExists(atPath: devices.directory))
    }

    func testEachDeviceGetsItsOwnTokenOnceInAPrivateDirectory() throws {
        let devices = ServerDeviceTokens(configDirectory: root)
        let server = try ServerTokenFile(directory: root).readOrCreate()
        let phone = try devices.readOrCreate("phone")
        let tablet = try devices.readOrCreate("tablet")
        XCTAssertEqual(try devices.readOrCreate("phone"), phone)
        XCTAssertNotEqual(phone, tablet)
        XCTAssertNotEqual(phone, server)

        XCTAssertEqual(mode(devices.directory), 0o700)
        XCTAssertEqual(mode(devices.directory + "/phone"), 0o600)
        XCTAssertEqual(try tokens(devices), ["phone": phone, "tablet": tablet])
        XCTAssertEqual(try devices.read().map(\.name), ["phone", "tablet"])
        // No temporary files are left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: devices.directory).sorted(), ["phone", "tablet"])

        XCTAssertThrowsError(try devices.readOrCreate("../server-token")) {
            XCTAssertEqual($0 as? ServerTokenError, .invalidDeviceName("../server-token"))
        }
    }

    func testConcurrentFirstPairingsOfOneDeviceAgree() async throws {
        let directory = root!
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<16 {
                group.addTask { try ServerDeviceTokens(configDirectory: directory).readOrCreate("phone").rawValue }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(tokens.count, 1)
    }

    func testRevokingDeletesOnlyThatDevicesToken() throws {
        let devices = ServerDeviceTokens(configDirectory: root)
        let phone = try devices.readOrCreate("phone")
        let tablet = try devices.readOrCreate("tablet")
        XCTAssertTrue(try devices.revoke("phone"))
        XCTAssertFalse(try devices.revoke("phone"))
        XCTAssertEqual(try tokens(devices), ["tablet": tablet])
        // Pairing it again gives it a new token.
        XCTAssertNotEqual(try devices.readOrCreate("phone"), phone)
    }

    func testEntriesThatAreNotDeviceNamesAreNotDevices() throws {
        let devices = ServerDeviceTokens(configDirectory: root)
        let phone = try devices.readOrCreate("phone")
        for stray in [".phone.123", "my phone", "phone~ "] {
            XCTAssertTrue(FileManager.default.createFile(atPath: devices.directory + "/" + stray, contents: Data((phone.rawValue + "\n").utf8)))
        }
        XCTAssertEqual(try devices.read().map(\.name), ["phone"])
    }

    func testAnUnusableDeviceIsRefusedAlone() throws {
        let devices = ServerDeviceTokens(configDirectory: root)
        try devices.readOrCreate("phone")
        let tablet = try devices.readOrCreate("tablet")
        XCTAssertEqual(chmod(devices.directory + "/phone", 0o640), 0)
        let read = try devices.read()
        XCTAssertEqual(read.map(\.name), ["phone", "tablet"])
        XCTAssertThrowsError(try read[0].token.get()) {
            XCTAssertEqual($0 as? ServerTokenError, .insecurePermissions(devices.directory + "/phone"))
        }
        XCTAssertEqual(try read[1].token.get(), tablet)

        // A device's remedy is revoking and pairing it again, not rotating the server token.
        let malformed = ServerTokenError.malformed(devices.directory + "/phone")
        XCTAssertTrue("\(malformed)".contains("latch-server devices --revoke phone"), "\(malformed)")
        XCTAssertTrue("\(ServerTokenError.malformed(root + "/server-token"))".contains("token --rotate"))
    }

    func testAnUnsafeDirectoryRefusesEveryDevice() throws {
        let devices = ServerDeviceTokens(configDirectory: root)
        try devices.readOrCreate("phone")
        XCTAssertEqual(chmod(devices.directory, 0o750), 0)
        XCTAssertThrowsError(try devices.read()) {
            XCTAssertEqual($0 as? ServerTokenError, .insecurePermissions(devices.directory))
        }
        XCTAssertThrowsError(try devices.revoke("phone"))
        XCTAssertEqual(chmod(devices.directory, 0o700), 0)

        let moved = root + "/elsewhere"
        XCTAssertEqual(rename(devices.directory, moved), 0)
        XCTAssertEqual(symlink(moved, devices.directory), 0)
        XCTAssertThrowsError(try devices.read()) {
            XCTAssertEqual($0 as? ServerTokenError, .symbolicLink(devices.directory))
        }
    }
}
