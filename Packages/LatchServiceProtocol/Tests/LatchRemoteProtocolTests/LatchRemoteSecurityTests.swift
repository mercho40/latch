import Foundation
import LatchRemoteProtocol
import XCTest

final class LatchRemoteTokenTests: XCTestCase {
    func testGeneratedTokensParseAndDiffer() throws {
        let first = LatchRemoteToken.generate()
        let second = LatchRemoteToken.generate()
        XCTAssertTrue(first.rawValue.hasPrefix("latch_"))
        XCTAssertEqual(first.rawValue.utf8.count, 6 + 43)
        XCTAssertEqual(LatchRemoteToken(first.rawValue), first)
        XCTAssertNotEqual(first, second)
    }

    func testParsingIsStrict() {
        XCTAssertNotNil(LatchRemoteToken(Sample.token))
        let body = String(Sample.token.dropFirst(6))
        let rejected = [
            "",
            body,
            "Latch_" + body,
            "latch-" + body,
            Sample.token + "=",
            Sample.token + "A",
            String(Sample.token.dropLast()),
            " " + Sample.token,
            "latch_" + String(repeating: "A", count: 42) + "+",
            "latch_" + String(repeating: "A", count: 42) + "/",
            // 43 characters carry 258 bits; the last two must be zero.
            "latch_" + String(repeating: "A", count: 42) + "B",
        ]
        for token in rejected {
            XCTAssertNil(LatchRemoteToken(token), token)
        }
        XCTAssertNotNil(LatchRemoteToken("latch_" + String(repeating: "A", count: 42) + "E"))
        XCTAssertNotNil(LatchRemoteToken("latch_" + String(repeating: "_", count: 42) + "w"))
    }

    func testMatching() throws {
        let token = try XCTUnwrap(LatchRemoteToken(Sample.token))
        XCTAssertTrue(token.matches(Sample.token))
        XCTAssertFalse(token.matches(String(Sample.token.dropLast()) + "g"))
        XCTAssertFalse(token.matches(String(Sample.token.dropLast())))
        XCTAssertFalse(token.matches(""))
    }

    func testDescriptionIsRedacted() throws {
        let token = try XCTUnwrap(LatchRemoteToken(Sample.token))
        XCTAssertFalse(String(describing: token).contains("AAECAw"))
        XCTAssertFalse(String(reflecting: token).contains("AAECAw"))
        let pairing = try LatchRemotePairing(host: "vps", token: token)
        var dumped = ""
        dump(token, to: &dumped)
        dump(pairing, to: &dumped)
        XCTAssertFalse(dumped.contains("AAECAw"), dumped)
        XCTAssertFalse(String(describing: pairing).contains("AAECAw"))
        XCTAssertFalse(String(reflecting: pairing).contains("AAECAw"))
        XCTAssertTrue(Mirror(reflecting: token).children.isEmpty)
    }
}

final class LatchRemotePairingTests: XCTestCase {
    private var token: LatchRemoteToken { LatchRemoteToken(Sample.token)! }

    func testFormatsAndParses() throws {
        let cases: [(host: String, port: UInt16, string: String)] = [
            ("vps.tail1234.ts.net", 7428, "latch://vps.tail1234.ts.net:7428?token=\(Sample.token)"),
            ("100.101.102.103", 9000, "latch://100.101.102.103:9000?token=\(Sample.token)"),
            ("fd7a:115c:a1e0::1", 7428, "latch://[fd7a:115c:a1e0::1]:7428?token=\(Sample.token)"),
            ("::1", 1, "latch://[::1]:1?token=\(Sample.token)"),
            ("localhost", 65535, "latch://localhost:65535?token=\(Sample.token)"),
        ]
        for (host, port, string) in cases {
            let pairing = try LatchRemotePairing(host: host, port: port, token: token)
            XCTAssertEqual(pairing.string, string)
            XCTAssertEqual(try LatchRemotePairing(parsing: string), pairing)
        }
    }

    func testParsingIsForgivingAboutPastedDetails() throws {
        let expected = try LatchRemotePairing(host: "vps", token: token)
        for string in [
            "  latch://vps:7428?token=\(Sample.token)\n",
            "latch://vps?token=\(Sample.token)",
            "LATCH://vps:7428/?token=\(Sample.token)",
            "latch://vps:7428?name=home&token=\(Sample.token)",
        ] {
            XCTAssertEqual(try LatchRemotePairing(parsing: string), expected, string)
        }
        XCTAssertEqual(try LatchRemotePairing(parsing: "latch://[::1]?token=\(Sample.token)").port, 7428)
    }

    func testATLSProxyIsReachedOverAWebSocket() throws {
        let pairing = try LatchRemotePairing(host: "latch.example.com", transport: .webSocket, token: token)
        XCTAssertEqual(pairing.port, 443)
        XCTAssertEqual(pairing.string, "latch://latch.example.com:443?transport=wss&token=\(Sample.token)")
        XCTAssertEqual(try LatchRemotePairing(parsing: pairing.string), pairing)
        for string in [
            "latch://latch.example.com?transport=wss&token=\(Sample.token)",
            "latch://latch.example.com?token=\(Sample.token)&transport=WSS",
            "latch://latch.example.com:443/?name=x&transport=wss&token=\(Sample.token)",
        ] {
            XCTAssertEqual(try LatchRemotePairing(parsing: string), pairing, string)
        }
        let custom = try LatchRemotePairing(parsing: "latch://latch.example.com:8443?transport=wss&token=\(Sample.token)")
        XCTAssertEqual(custom.port, 8443)
        XCTAssertEqual(try LatchRemotePairing(parsing: "latch://vps?transport=tcp&token=\(Sample.token)").transport, .tcp)
        XCTAssertEqual(try LatchRemotePairing(host: "vps", token: token).transport, .tcp)
    }

    func testParsingRejects() {
        let cases: [(String, LatchRemotePairingError)] = [
            ("http://vps:7428?token=\(Sample.token)", .invalidScheme),
            ("vps:7428?token=\(Sample.token)", .invalidScheme),
            ("latch://vps:0?token=\(Sample.token)", .invalidPort),
            ("latch://vps:65536?token=\(Sample.token)", .invalidPort),
            ("latch://vps:07428x?token=\(Sample.token)", .invalidPort),
            ("latch://vps:?token=\(Sample.token)", .invalidPort),
            ("latch://vps:-1?token=\(Sample.token)", .invalidPort),
            ("latch://:7428?token=\(Sample.token)", .invalidHost),
            ("latch://::1:7428?token=\(Sample.token)", .invalidHost),
            ("latch://[vps]:7428?token=\(Sample.token)", .invalidHost),
            ("latch://[fe80::1%25en0]:7428?token=\(Sample.token)", .invalidHost),
            ("latch://[::1:7428?token=\(Sample.token)", .invalidHost),
            ("latch://[::1]7428?token=\(Sample.token)", .invalidHost),
            ("latch://user@vps:7428?token=\(Sample.token)", .invalidHost),
            ("latch://my_vps:7428?token=\(Sample.token)", .invalidHost),
            ("latch://vps..net:7428?token=\(Sample.token)", .invalidHost),
            ("latch://-vps:7428?token=\(Sample.token)", .invalidHost),
            ("latch://vps:7428", .missingToken),
            ("latch://vps:7428?other=1", .missingToken),
            ("latch://vps:7428?token=latch_short", .invalidToken),
            ("latch://vps:7428?token=\(Sample.token)&token=\(Sample.token)", .invalidToken),
            ("latch://vps:7428?transport=quic&token=\(Sample.token)", .unsupportedTransport),
            ("latch://vps:7428?transport=&token=\(Sample.token)", .unsupportedTransport),
            ("latch://vps:7428?transport=wss&transport=wss&token=\(Sample.token)", .unsupportedTransport),
        ]
        for (string, error) in cases {
            XCTAssertThrowsError(try LatchRemotePairing(parsing: string), string) {
                XCTAssertEqual($0 as? LatchRemotePairingError, error, string)
            }
        }
    }

    func testInitValidates() {
        XCTAssertThrowsError(try LatchRemotePairing(host: "vps", port: 0, token: token))
        XCTAssertThrowsError(try LatchRemotePairing(host: "", token: token))
        XCTAssertThrowsError(try LatchRemotePairing(host: "a b", token: token))
        XCTAssertThrowsError(try LatchRemotePairing(host: "::zz", token: token))
    }
}

final class LatchRemoteAddressPolicyTests: XCTestCase {
    private func classify(_ string: String) -> LatchRemoteAddressPolicy.Classification? {
        LatchRemoteAddressPolicy.classify(numericHost: string)
    }

    func testIPv4() {
        XCTAssertEqual(classify("127.0.0.1"), .loopback)
        XCTAssertEqual(classify("127.255.0.9"), .loopback)
        XCTAssertEqual(classify("0.0.0.0"), .unspecified)
        XCTAssertEqual(classify("100.63.255.255"), .other)
        XCTAssertEqual(classify("100.64.0.0"), .tailnet)
        XCTAssertEqual(classify("100.101.102.103"), .tailnet)
        XCTAssertEqual(classify("100.127.255.255"), .tailnet)
        XCTAssertEqual(classify("100.128.0.0"), .other)
        XCTAssertEqual(classify("192.168.1.10"), .other)
        XCTAssertEqual(classify("8.8.8.8"), .other)
    }

    func testIPv6() {
        XCTAssertEqual(classify("::1"), .loopback)
        XCTAssertEqual(classify("::"), .unspecified)
        XCTAssertEqual(classify("fd7a:115c:a1e0::1"), .tailnet)
        XCTAssertEqual(classify("fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff"), .tailnet)
        XCTAssertEqual(classify("fd7a:115c:a1e1::1"), .other)
        XCTAssertEqual(classify("fd7a:115c:a1df::1"), .other)
        XCTAssertEqual(classify("2001:db8::1"), .other)
        XCTAssertEqual(classify("::2"), .other)
    }

    func testIPv4MappedAddressesAreUnmapped() {
        XCTAssertEqual(classify("::ffff:127.0.0.1"), .loopback)
        XCTAssertEqual(classify("::ffff:0.0.0.0"), .unspecified)
        XCTAssertEqual(classify("::ffff:100.64.0.1"), .tailnet)
        XCTAssertEqual(classify("::ffff:100.128.0.0"), .other)
        XCTAssertEqual(LatchRemoteAddressPolicy.unmapped(LatchRemoteAddressPolicy.numericAddress("::ffff:1.2.3.4")!), [1, 2, 3, 4])
        // IPv4-compatible (deprecated) is not IPv4-mapped.
        XCTAssertEqual(classify("::127.0.0.1"), .other)
    }

    func testClassifiesRawBytes() {
        XCTAssertEqual(LatchRemoteAddressPolicy.classify([127, 0, 0, 1]), .loopback)
        XCTAssertEqual(LatchRemoteAddressPolicy.classify(Data([100, 64, 0, 1])), .tailnet)
        XCTAssertEqual(LatchRemoteAddressPolicy.classify([UInt8](repeating: 0, count: 16)), .unspecified)
        XCTAssertNil(LatchRemoteAddressPolicy.classify([127, 0, 0]))
        XCTAssertNil(LatchRemoteAddressPolicy.classify([UInt8]()))
    }

    func testNumericParsingNeverResolvesNames() {
        XCTAssertEqual(LatchRemoteAddressPolicy.numericAddress("10.0.0.1"), [10, 0, 0, 1])
        XCTAssertEqual(LatchRemoteAddressPolicy.numericAddress("::1")?.count, 16)
        for string in ["localhost", "example.com", "", " 127.0.0.1", "127.0.0.1 ", "[::1]", "fe80::1%en0", "127.1", "1.2.3.4.5", "256.0.0.1"] {
            XCTAssertNil(LatchRemoteAddressPolicy.numericAddress(string), string)
        }
        // Leading zeros read as octal elsewhere, so they are rejected on every platform.
        for string in ["010.0.0.1", "0127.0.0.1", "0100.64.0.1", "127.0.0.01", "::ffff:010.0.0.1", "::ffff:100.064.0.1"] {
            XCTAssertNil(LatchRemoteAddressPolicy.numericAddress(string), string)
        }
        XCTAssertEqual(LatchRemoteAddressPolicy.numericAddress("10.0.0.0"), [10, 0, 0, 0])
        XCTAssertEqual(LatchRemoteAddressPolicy.numericAddress("0000:0000::0001")?.last, 1)
        XCTAssertEqual(classify("::ffff:10.0.0.0"), .other)
    }
}
