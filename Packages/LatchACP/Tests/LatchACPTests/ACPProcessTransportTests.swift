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

    func testStopForceKillsProcessThatIgnoresTermination() async throws {
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo ready; sleep 30 & wait"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var incoming = transport.incoming.makeAsyncIterator()
        let ready = await incoming.next() // Trap installed before echo.
        XCTAssertEqual(ready, Data("ready\n".utf8))

        let started = ContinuousClock.now
        await transport.stop(gracePeriod: .milliseconds(300))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertTrue(transport.wasForceKilled)

        var termination = transport.termination.makeAsyncIterator()
        let status = await termination.next()
        XCTAssertEqual(status, SIGKILL)
    }

    func testStopDoesNotForceKillCooperativeProcess() async throws {
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        await transport.stop()
        XCTAssertFalse(transport.wasForceKilled)
        var termination = transport.termination.makeAsyncIterator()
        let status = await termination.next()
        XCTAssertNotNil(status)
    }
}
