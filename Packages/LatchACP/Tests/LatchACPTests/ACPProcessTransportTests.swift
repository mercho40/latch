import Foundation
import XCTest
@testable import LatchACP

final class ACPProcessTransportTests: XCTestCase {
    func testInheritsParentEnvironmentByDefault() async throws {
        let expectedPath = try XCTUnwrap(ProcessInfo.processInfo.environment["PATH"])
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf %s \"$PATH\""],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var incoming = transport.incoming.makeAsyncIterator()

        let received = await incoming.next()
        let path = try XCTUnwrap(received)
        XCTAssertEqual(String(decoding: path, as: UTF8.self), expectedPath)
        await transport.stop()
    }

    func testRoundTripsBytesThroughOwnedSubprocess() async throws {
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var incoming = transport.incoming.makeAsyncIterator()

        try await transport.send(Data("hello\n".utf8))
        let echoed = await incoming.next()
        XCTAssertEqual(echoed, Data("hello\n".utf8))

        await transport.stop()
        var termination = transport.termination.makeAsyncIterator()
        let status = await termination.next()
        XCTAssertNotNil(status)
    }
}
