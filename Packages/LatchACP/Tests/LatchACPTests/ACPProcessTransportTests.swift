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
                arguments: ["-c", "trap '' TERM; sleep 30 & echo $!; wait"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var incoming = transport.incoming.makeAsyncIterator()
        let line = await incoming.next().map { String(decoding: $0, as: UTF8.self) } // Trap installed before echo.
        let child = try XCTUnwrap(line.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })

        let started = ContinuousClock.now
        await transport.stop(gracePeriod: .milliseconds(300))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertTrue(transport.wasForceKilled)

        var termination = transport.termination.makeAsyncIterator()
        let status = await termination.next()
        XCTAssertEqual(status, SIGKILL)
        try await waitUntilGone(child, within: .seconds(2))
    }

    func testStopSignalsTheAgentsWholeProcessGroup() async throws {
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 60 & echo $!; wait"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var incoming = transport.incoming.makeAsyncIterator()
        let line = await incoming.next().map { String(decoding: $0, as: UTF8.self) }
        let child = try XCTUnwrap(line.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })

        await transport.stop()
        XCTAssertFalse(transport.wasForceKilled)
        try await waitUntilGone(child, within: .seconds(2))
    }

    func testStopKillsAToolChildThatIgnoresTerminationAfterTheAgentExits() async throws {
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", #"sh -c 'trap "" TERM; echo $$; exec sleep 60' & wait"#],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var incoming = transport.incoming.makeAsyncIterator()
        let line = await incoming.next().map { String(decoding: $0, as: UTF8.self) }
        let child = try XCTUnwrap(line.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })

        let started = ContinuousClock.now
        await transport.stop(gracePeriod: .milliseconds(300))
        XCTAssertFalse(transport.wasForceKilled)
        // Sooner than the SIGKILL Linux sends the group a second after the agent exits.
        try await waitUntilGone(child, within: started + .milliseconds(800) - ContinuousClock.now)
    }

    /// The caller waits for the agent, not for the tool children it leaves: those are killed
    /// at the deadline all the same.
    func testStopReturnsOnceTheAgentExitsAndKillsItsToolChildAtTheDeadline() async throws {
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", #"sh -c 'trap "" TERM; echo $$; exec sleep 60' & wait"#],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var incoming = transport.incoming.makeAsyncIterator()
        let line = await incoming.next().map { String(decoding: $0, as: UTF8.self) }
        let child = try XCTUnwrap(line.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })

        let started = ContinuousClock.now
        await transport.stop(gracePeriod: .seconds(3))
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(1500), "Waited for the tool child")
        XCTAssertFalse(transport.wasForceKilled)
        try await waitUntilGone(child, within: started + .seconds(4) - ContinuousClock.now)
    }

    func testWriteToAnAgentThatClosedStandardInputThrows() async throws {
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 0<&-; echo ready; exec sleep 60"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var incoming = transport.incoming.makeAsyncIterator()
        let ready = await incoming.next()
        XCTAssertEqual(ready, Data("ready\n".utf8))

        do {
            try await transport.send(Data("hello\n".utf8))
            XCTFail("Expected the write to fail")
        } catch let error as ACPJSONRPCConnectionError {
            XCTAssertEqual(error, .closed)
        }
        await transport.stop(gracePeriod: .seconds(1))
    }

    func testStopEndsAWriteTheAgentNeverReads() async throws {
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        let write = Task { try await transport.send(Data(count: 1 << 20)) }
        try await Task.sleep(for: .milliseconds(100))
        await transport.stop()
        do {
            try await write.value
            XCTFail("Expected the write to fail")
        } catch let error as ACPJSONRPCConnectionError {
            XCTAssertEqual(error, .closed)
        }
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

func waitUntilGone(_ pid: pid_t, within limit: Duration, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + limit
    while !processIsGone(pid), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(processIsGone(pid), "The agent's tool child outlived it", file: file, line: line)
}

/// An orphan the container's init has not reaped yet counts as gone.
func processIsGone(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 else { return true }
    #if os(Linux)
    let stat = (try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)) ?? ""
    return stat.split(separator: ")").last?.trimmingCharacters(in: .whitespaces).hasPrefix("Z") ?? true
    #else
    return false
    #endif
}
