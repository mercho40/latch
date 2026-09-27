#if canImport(Network)
import Foundation
@testable import LatchRemoteClient
import Network
import XCTest

final class LatchRemoteClientPolicyTests: XCTestCase {
    func testBackoffDoublesFromOneSecondToAThirtySecondCap() {
        let backoff = LatchRemoteBackoff()
        XCTAssertEqual((0..<8).map { backoff.delay(afterFailures: $0) }, [1, 2, 4, 8, 16, 30, 30, 30].map { .seconds($0) })
        XCTAssertEqual(backoff.delay(afterFailures: 10_000), .seconds(30))
        XCTAssertEqual(backoff.delay(afterFailures: -1), .seconds(1))
    }

    func testInjectedBackoffKeepsItsShape() {
        let backoff = LatchRemoteBackoff(initial: .milliseconds(50), maximum: .milliseconds(150))
        XCTAssertEqual((0..<4).map { backoff.delay(afterFailures: $0) }, [50, 100, 150, 150].map { .milliseconds($0) })
    }

    func testSequenceCursorAdmitsOnlyIncreasingSequencesAndAllowsGaps() {
        var cursor = LatchRemoteSequenceCursor()
        XCTAssertEqual([1, 2, 2, 1, 5, 4, 6].map { cursor.admit($0) }, [true, true, false, false, true, false, true])
        XCTAssertEqual(cursor.last, 6)

        var resumed = LatchRemoteSequenceCursor(after: 10)
        XCTAssertFalse(resumed.admit(10))
        XCTAssertTrue(resumed.admit(11))
    }

    func testDestinationAllowsLoopbackAndTailnetOnly() {
        func allowed(_ address: [UInt8]?, interface: String? = "utun4", unencrypted: Bool = false) -> Bool {
            LatchRemoteDestinationPolicy.mayAuthenticate(peerAddress: address, interfaceName: interface, allowUnencryptedNetwork: unencrypted)
        }
        XCTAssertTrue(allowed([127, 0, 0, 1]))
        XCTAssertTrue(allowed([127, 8, 9, 10]))
        XCTAssertTrue(allowed([UInt8](repeating: 0, count: 15) + [1]))
        XCTAssertTrue(allowed([100, 64, 0, 1]))
        XCTAssertTrue(allowed([100, 127, 255, 254]))
        XCTAssertTrue(allowed([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + [UInt8](repeating: 7, count: 10)))
        // IPv4-mapped IPv6 is judged as its IPv4 address.
        XCTAssertTrue(allowed([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1]))
        XCTAssertFalse(allowed([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 203, 0, 113, 7]))

        XCTAssertFalse(allowed([100, 128, 0, 1]))
        XCTAssertFalse(allowed([192, 168, 1, 10]))
        XCTAssertFalse(allowed([203, 0, 113, 7]))
        XCTAssertFalse(allowed([0, 0, 0, 0]))
        XCTAssertFalse(allowed([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE1] + [UInt8](repeating: 0, count: 10)))
        XCTAssertFalse(allowed(nil))
        XCTAssertFalse(allowed([1, 2, 3]))

        XCTAssertTrue(allowed([203, 0, 113, 7], unencrypted: true))
        XCTAssertTrue(allowed(nil, unencrypted: true))
    }

    func testATailnetAddressNeedsATunnelInterface() {
        func allowed(_ address: [UInt8], interface: String?) -> Bool {
            LatchRemoteDestinationPolicy.mayAuthenticate(peerAddress: address, interfaceName: interface, allowUnencryptedNetwork: false)
        }
        let tailnet: [UInt8] = [100, 101, 102, 103]
        let tailnet6: [UInt8] = [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + [UInt8](repeating: 7, count: 10)
        // With Tailscale down the route to a tailnet address is the default one.
        XCTAssertFalse(allowed(tailnet, interface: "en0"))
        XCTAssertFalse(allowed(tailnet6, interface: "en0"))
        XCTAssertFalse(allowed(tailnet, interface: "lo0"))
        XCTAssertFalse(allowed(tailnet, interface: nil))
        XCTAssertTrue(allowed(tailnet, interface: "utun3"))
        XCTAssertTrue(allowed(tailnet6, interface: "utun3"))
        // Loopback is judged by its address.
        XCTAssertTrue(allowed([127, 0, 0, 1], interface: nil))
        XCTAssertFalse(allowed([192, 168, 1, 10], interface: "utun3"))
    }

    func testDispatchIntervalsSaturateInsteadOfOverflowing() {
        XCTAssertEqual(Duration.milliseconds(1500).dispatchInterval, .nanoseconds(1_500_000_000))
        XCTAssertEqual(Duration.seconds(40_000_000_000 / 4).dispatchInterval, .seconds(3_000_000_000))
        XCTAssertEqual(Duration.seconds(Int64.max).dispatchInterval, .seconds(3_000_000_000))
        XCTAssertEqual(Duration.seconds(-5).dispatchInterval, .nanoseconds(0))
    }

    func testDestinationReadsOnlyNumericEndpoints() {
        XCTAssertEqual(LatchRemoteDestinationPolicy.address(of: .hostPort(host: "127.0.0.1", port: 7428)), [127, 0, 0, 1])
        XCTAssertEqual(LatchRemoteDestinationPolicy.address(of: .hostPort(host: "::1", port: 7428)), [UInt8](repeating: 0, count: 15) + [1])
        XCTAssertNil(LatchRemoteDestinationPolicy.address(of: .hostPort(host: "vps.example", port: 7428)))
        XCTAssertNil(LatchRemoteDestinationPolicy.address(of: nil))
        XCTAssertEqual(LatchRemoteDestinationPolicy.describe([203, 0, 113, 7]), "203.0.113.7")
        XCTAssertEqual(LatchRemoteDestinationPolicy.describe([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 203, 0, 113, 7]), "203.0.113.7")
    }

    func testPermanenceClassification() {
        let permanent: [LatchRemoteClientError] = [
            .destinationNotAllowed(address: "x"), .unauthorized(message: ""), .protocolMismatch(message: "", supported: nil),
            .runtimeNotFound(message: ""), .closed, .invalidEndpoint,
        ]
        let transient: [LatchRemoteClientError] = [
            .connectionFailed(""), .connectionLost, .handshakeTimedOut, .silence, .timedOut, .protocolViolation(""),
            .rejected(reason: .busy, message: ""), .notConnected,
        ]
        XCTAssertTrue(permanent.allSatisfy { $0.isPermanent && !$0.isLinkFailure })
        XCTAssertTrue(transient.allSatisfy { !$0.isPermanent && $0.isLinkFailure })
    }
}
#endif
