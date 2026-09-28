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

final class ServerTokenFileTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("latch-token-\(UUID().uuidString)").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func mode(_ path: String) -> mode_t {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return status.st_mode & 0o777
    }

    func testConfigDirectoryResolution() {
        XCTAssertEqual(ServerConfigDirectory.resolve(explicit: "/etc/x", environment: ["XDG_CONFIG_HOME": "/xdg"], homeDirectory: "/home/u"), "/etc/x")
        XCTAssertEqual(ServerConfigDirectory.resolve(explicit: nil, environment: ["XDG_CONFIG_HOME": "/xdg"], homeDirectory: "/home/u"), "/xdg/latch")
        XCTAssertEqual(ServerConfigDirectory.resolve(explicit: nil, environment: [:], homeDirectory: "/home/u"), "/home/u/.config/latch")
        // A relative XDG_CONFIG_HOME is invalid by the spec and ignored.
        XCTAssertEqual(ServerConfigDirectory.resolve(explicit: nil, environment: ["XDG_CONFIG_HOME": "rel"], homeDirectory: "/home/u"), "/home/u/.config/latch")
    }

    func testPrepareCreatesPrivateDirectoriesAndRefusesUnsafeOnes() throws {
        let directory = root + "/a/b/latch"
        try ServerConfigDirectory.prepare(directory)
        XCTAssertEqual(mode(directory), 0o700)
        XCTAssertEqual(mode(root + "/a"), 0o700)
        try ServerConfigDirectory.prepare(directory)

        XCTAssertEqual(chmod(directory, 0o750), 0)
        XCTAssertThrowsError(try ServerConfigDirectory.prepare(directory)) {
            XCTAssertEqual($0 as? ServerTokenError, .insecurePermissions(directory))
        }
        XCTAssertEqual(chmod(directory, 0o700), 0)

        XCTAssertThrowsError(try ServerConfigDirectory.prepare(directory, owner: geteuid() + 1)) {
            XCTAssertEqual($0 as? ServerTokenError, .wrongOwner(directory))
        }

        let link = root + "/link"
        XCTAssertEqual(symlink(directory, link), 0)
        XCTAssertThrowsError(try ServerConfigDirectory.prepare(link)) {
            XCTAssertEqual($0 as? ServerTokenError, .symbolicLink(link))
        }

        let file = root + "/file"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data()))
        XCTAssertThrowsError(try ServerConfigDirectory.prepare(file)) {
            XCTAssertEqual($0 as? ServerTokenError, .notADirectory(file))
        }
    }

    func testTheTokenIsCreatedOnceWithMode0600() throws {
        try ServerConfigDirectory.prepare(root)
        let file = ServerTokenFile(directory: root)
        XCTAssertThrowsError(try file.read()) { XCTAssertEqual($0 as? ServerTokenError, .missing(file.path)) }
        XCTAssertNil(file.current())

        let token = try file.readOrCreate()
        XCTAssertEqual(mode(file.path), 0o600)
        XCTAssertEqual(try file.readOrCreate(), token)
        XCTAssertEqual(file.current(), token)
        XCTAssertEqual(try String(contentsOfFile: file.path, encoding: .utf8), token.rawValue + "\n")
        // No temporary files are left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [ServerTokenFile.fileName])
    }

    func testConcurrentFirstRunsAgreeOnOneToken() async throws {
        try ServerConfigDirectory.prepare(root)
        let directory = root!
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<16 {
                group.addTask { try ServerTokenFile(directory: directory).readOrCreate().rawValue }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [ServerTokenFile.fileName])
    }

    func testRotationReplacesTheToken() throws {
        try ServerConfigDirectory.prepare(root)
        let file = ServerTokenFile(directory: root)
        let first = try file.readOrCreate()
        let second = try file.rotate()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(file.current(), second)
        XCTAssertEqual(mode(file.path), 0o600)
        // Another reader of the same file sees it too.
        XCTAssertEqual(ServerTokenFile(directory: root).current(), second)
    }

    func testUnsafeTokenFilesAreRefused() throws {
        try ServerConfigDirectory.prepare(root)
        let file = ServerTokenFile(directory: root)
        let token = try file.readOrCreate()

        XCTAssertEqual(chmod(file.path, 0o640), 0)
        XCTAssertThrowsError(try file.read()) { XCTAssertEqual($0 as? ServerTokenError, .insecurePermissions(file.path)) }
        // A token read earlier is not used as a fallback.
        XCTAssertNil(file.current())
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(file.current(), token)

        XCTAssertThrowsError(try ServerTokenFile(directory: root, owner: geteuid() + 1).read()) {
            XCTAssertEqual($0 as? ServerTokenError, .wrongOwner(file.path))
        }

        // A symbolic link is never followed, even to a valid token.
        let elsewhere = root + "/elsewhere"
        XCTAssertEqual(rename(file.path, elsewhere), 0)
        XCTAssertEqual(symlink(elsewhere, file.path), 0)
        XCTAssertThrowsError(try file.read()) { XCTAssertEqual($0 as? ServerTokenError, .symbolicLink(file.path)) }
        XCTAssertThrowsError(try file.readOrCreate()) { XCTAssertEqual($0 as? ServerTokenError, .symbolicLink(file.path)) }
        XCTAssertEqual(unlink(file.path), 0)

        XCTAssertEqual(mkdir(file.path, 0o700), 0)
        XCTAssertThrowsError(try file.read()) { XCTAssertEqual($0 as? ServerTokenError, .notARegularFile(file.path)) }
        XCTAssertEqual(rmdir(file.path), 0)

        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        _ = write(descriptor, "latch_short\n", 12)
        close(descriptor)
        XCTAssertThrowsError(try file.read()) { XCTAssertEqual($0 as? ServerTokenError, .malformed(file.path)) }
    }

    func testErrorsNeverCarryTheToken() throws {
        try ServerConfigDirectory.prepare(root)
        let file = ServerTokenFile(directory: root)
        let token = try file.readOrCreate()
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try file.read()) { error in
            XCTAssertFalse("\(error)".contains(token.rawValue))
        }
    }
}
