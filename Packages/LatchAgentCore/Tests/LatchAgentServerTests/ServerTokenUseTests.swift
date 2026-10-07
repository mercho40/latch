import Foundation
import Synchronization
import XCTest
@testable import LatchAgentServer
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private final class Clock: Sendable {
    let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func advance(_ seconds: TimeInterval) {
        now.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

final class ServerTokenUseTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("latch-use-\(UUID().uuidString)").path
        try ServerConfigDirectory.prepare(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testUsesAreNotedAtMostOnceAMinuteFromOneAddress() throws {
        let clock = Clock()
        let use = ServerTokenUse(configDirectory: root, now: { clock.now.withLock { $0 } })
        let start = clock.now.withLock { $0 }
        use.note(device: "phone", from: "100.101.102.103")
        use.note(device: nil, from: "127.0.0.1")
        var record = try XCTUnwrap(ServerTokenUse.read(configDirectory: root))
        XCTAssertEqual(record.devices, ["phone": .init(at: start, from: "100.101.102.103")])
        XCTAssertEqual(record.server, .init(at: start, from: "127.0.0.1"))
        var status = stat()
        XCTAssertEqual(stat(use.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)

        // Again within the minute from the same address: nothing written.
        clock.advance(30)
        use.note(device: "phone", from: "100.101.102.103")
        XCTAssertEqual(ServerTokenUse.read(configDirectory: root)?.devices["phone"]?.at, start)
        // From another address, or after the minute: written.
        use.note(device: "phone", from: "100.64.0.9")
        record = try XCTUnwrap(ServerTokenUse.read(configDirectory: root))
        XCTAssertEqual(record.devices["phone"], .init(at: start.addingTimeInterval(30), from: "100.64.0.9"))
        clock.advance(61)
        use.note(device: "phone", from: "100.64.0.9")
        XCTAssertEqual(ServerTokenUse.read(configDirectory: root)?.devices["phone"]?.at, start.addingTimeInterval(91))
        // No temporary files are left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [ServerTokenUse.fileName])
    }

    func testRevokedDevicesAreForgottenAndUsesOutliveARestart() throws {
        let use = ServerTokenUse(configDirectory: root)
        use.note(device: "phone", from: "a")
        use.note(device: "tablet", from: "b")
        use.forget(allBut: ["tablet"])
        XCTAssertEqual(ServerTokenUse.read(configDirectory: root)?.devices.keys.sorted(), ["tablet"])
        let restarted = ServerTokenUse(configDirectory: root)
        restarted.note(device: nil, from: "c")
        XCTAssertEqual(ServerTokenUse.read(configDirectory: root)?.devices.keys.sorted(), ["tablet"])
        XCTAssertNotNil(ServerTokenUse.read(configDirectory: root)?.server)
    }

    func testAnUnreadableFileStartsAfresh() throws {
        try Data("not json".utf8).write(to: URL(fileURLWithPath: root + "/" + ServerTokenUse.fileName))
        XCTAssertNil(ServerTokenUse.read(configDirectory: root))
        ServerTokenUse(configDirectory: root).note(device: "phone", from: "a")
        XCTAssertEqual(ServerTokenUse.read(configDirectory: root)?.devices.keys.sorted(), ["phone"])
    }

    func testDescribingWhen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ServerTokenUse.describe(now.addingTimeInterval(-59), now: now), "just now")
        XCTAssertEqual(ServerTokenUse.describe(now.addingTimeInterval(5), now: now), "just now")
        XCTAssertEqual(ServerTokenUse.describe(now.addingTimeInterval(-60), now: now), "1 minute ago")
        XCTAssertEqual(ServerTokenUse.describe(now.addingTimeInterval(-7200), now: now), "2 hours ago")
        XCTAssertEqual(ServerTokenUse.describe(now.addingTimeInterval(-86_400 * 3), now: now), "3 days ago")
    }
}
