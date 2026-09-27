import Foundation
import LatchRemoteProtocol
import XCTest
@testable import LatchAgentServer

final class ServerListenPolicyTests: XCTestCase {
    private func parse(_ value: String) throws -> ServerSocketAddress {
        try ServerListenPolicy.parse(value)
    }

    private func decide(
        _ value: String,
        allowUnencrypted: Bool = false,
        interfaces: [ServerInterfaceAddress] = [],
        prefixes: [String] = ServerListenPolicy.defaultTunnelPrefixes
    ) throws -> ServerListenPolicy.Decision {
        ServerListenPolicy.evaluate(try parse(value), allowUnencryptedNetwork: allowUnencrypted, interfaces: interfaces, tunnelPrefixes: prefixes)
    }

    func testParsesNumericAddressesOnly() throws {
        XCTAssertEqual(try parse("127.0.0.1:7428"), ServerSocketAddress(bytes: [127, 0, 0, 1], port: 7428))
        XCTAssertEqual(try parse("localhost:0"), ServerSocketAddress(bytes: [127, 0, 0, 1], port: 0))
        XCTAssertEqual(try parse("[::1]:80"), ServerSocketAddress(bytes: [UInt8](repeating: 0, count: 15) + [1], port: 80))
        // IPv4-mapped IPv6 becomes IPv4.
        XCTAssertEqual(try parse("[::ffff:100.64.1.2]:1"), ServerSocketAddress(bytes: [100, 64, 1, 2], port: 1))
        XCTAssertEqual(try parse("[fd7a:115c:a1e0::5]:7428").bytes.count, 16)
        XCTAssertEqual(ServerListenPolicy.defaultListen, "127.0.0.1:7428")

        XCTAssertThrowsError(try parse("example.com:7428")) { XCTAssertEqual($0 as? ServerListenError, .hostName("example.com:7428")) }
        XCTAssertThrowsError(try parse("my-vps:7428")) { XCTAssertEqual($0 as? ServerListenError, .hostName("my-vps:7428")) }
        for invalid in ["127.0.0.1", "::1:80", "[::1]", "[::1]80", ":7428", "[127.0.0.1]:1", "010.0.0.1:1", "127.1:1", "[fe80::1%lo0]:1"] {
            XCTAssertThrowsError(try parse(invalid), invalid)
        }
        for badPort in ["127.0.0.1:", "127.0.0.1:65536", "127.0.0.1:-1", "127.0.0.1:0x10", "127.0.0.1:123456"] {
            XCTAssertThrowsError(try parse(badPort), badPort) { XCTAssertEqual($0 as? ServerListenError, .invalidPort(badPort)) }
        }
    }

    func testLoopbackIsAlwaysAllowed() throws {
        XCTAssertEqual(try decide("127.0.0.1:1"), .allowed)
        XCTAssertEqual(try decide("127.9.8.7:1"), .allowed)
        XCTAssertEqual(try decide("[::1]:1"), .allowed)
        XCTAssertEqual(try decide("[::ffff:127.0.0.1]:1"), .allowed)
    }

    func testTheUnspecifiedAddressNeedsTheFlagInEveryForm() throws {
        for value in ["0.0.0.0:7428", "[::]:7428", "[::ffff:0.0.0.0]:7428", "[0:0:0:0:0:0:0:0]:1"] {
            guard case .refused = try decide(value) else { return XCTFail("\(value) was not refused") }
            guard case .allowedUnencrypted = try decide(value, allowUnencrypted: true) else { return XCTFail("\(value) with the flag") }
        }
    }

    func testTailnetAddressesNeedATunnelInterfaceCarryingThem() throws {
        let tailscale = [ServerInterfaceAddress(name: "tailscale0", address: [100, 101, 102, 103])]
        let utun = [ServerInterfaceAddress(name: "utun3", address: [100, 101, 102, 103])]
        let ethernet = [ServerInterfaceAddress(name: "eth0", address: [100, 101, 102, 103])]

        XCTAssertEqual(try decide("100.101.102.103:7428", interfaces: tailscale, prefixes: ["tailscale"]), .allowed)
        XCTAssertEqual(try decide("100.101.102.103:7428", interfaces: utun, prefixes: ["utun"]), .allowed)
        #if os(macOS)
        XCTAssertEqual(try decide("100.101.102.103:7428", interfaces: utun), .allowed)
        #else
        XCTAssertEqual(try decide("100.101.102.103:7428", interfaces: tailscale), .allowed)
        #endif

        // The right range on the wrong interface, or not up yet: wait for it.
        guard case .tailnetNotUp = try decide("100.101.102.103:7428", interfaces: ethernet) else { return XCTFail("eth0") }
        guard case .tailnetNotUp = try decide("100.101.102.103:7428", interfaces: []) else { return XCTFail("no interface") }
        // Another address on the tunnel does not count.
        guard case .tailnetNotUp = try decide("100.101.102.104:7428", interfaces: tailscale, prefixes: ["tailscale"]) else {
            return XCTFail("another address")
        }
        guard case .allowedUnencrypted = try decide("100.101.102.103:7428", allowUnencrypted: true, interfaces: ethernet) else {
            return XCTFail("with the flag")
        }

        let v6 = [ServerInterfaceAddress(name: "tailscale0", address: try parse("[fd7a:115c:a1e0::5]:1").bytes)]
        XCTAssertEqual(try decide("[fd7a:115c:a1e0::5]:7428", interfaces: v6, prefixes: ["tailscale"]), .allowed)
    }

    func testOtherAddressesNeedTheFlag() throws {
        for value in ["192.168.1.10:7428", "203.0.113.5:7428", "[2001:db8::1]:7428", "100.128.0.1:1"] {
            guard case .refused = try decide(value) else { return XCTFail("\(value) was not refused") }
            guard case .allowedUnencrypted = try decide(value, allowUnencrypted: true) else { return XCTFail("\(value) with the flag") }
        }
    }

    func testSystemInterfacesIncludeLoopback() {
        XCTAssertTrue(ServerListenPolicy.systemInterfaces().contains { $0.address == [127, 0, 0, 1] })
    }

    func testBinderListensAndReportsTheChosenPort() throws {
        let log = ServerLog(sink: { _ in })
        let listeners = try XCTUnwrap(ServerListenBinder.bind(
            [ServerSocketAddress(bytes: [127, 0, 0, 1], port: 0), try parse("[::1]:0")],
            allowUnencryptedNetwork: false, log: log
        ))
        defer { listeners.forEach { ServerSocket.close($0.descriptor) } }
        XCTAssertEqual(listeners.count, 2)
        XCTAssertTrue(listeners.allSatisfy { $0.address.port != 0 })
        XCTAssertEqual(listeners[1].address.bytes.count, 16)

        // The same port again fails rather than waiting.
        XCTAssertNil(ServerListenBinder.bind([listeners[0].address], allowUnencryptedNetwork: false, log: log))
    }

    func testBinderWaitsForATailnetAddressThenGivesUp() {
        let lines = LogCollector()
        let start = ContinuousClock.now
        let result = ServerListenBinder.bind(
            [ServerSocketAddress(bytes: [100, 64, 0, 9], port: 0)],
            allowUnencryptedNetwork: false,
            log: ServerLog(sink: lines.sink),
            interfaces: { [] },
            retryInterval: .milliseconds(50),
            retryLimit: .milliseconds(300)
        )
        XCTAssertNil(result)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(300))
    }
}
