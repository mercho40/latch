#if os(Linux)
import Foundation
import XCTest
@testable import LatchACP

final class LinuxChildProcessTests: XCTestCase {
    /// Swift concurrency threads block most signals; an agent must not inherit that.
    func testAgentSpawnedFromAnActorStartsWithNoBlockedOrIgnoredSignals() async throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let transport = try await Spawner().spawn(
            ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: ["/proc/self/status"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        let status = String(decoding: await collect(transport.incoming), as: UTF8.self)
        let fields = Dictionary(
            status.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Only the standard signals, 1 to 31. glibc keeps 32 and 33 for its own threads and
        // unblocks them in every process it starts; some kernels report them blocked in a child.
        let standardSignals: UInt64 = 0x7FFF_FFFF
        XCTAssertEqual(fields["SigBlk"].flatMap { UInt64($0, radix: 16) }.map { $0 & standardSignals }, 0)
        XCTAssertEqual(fields["SigIgn"].flatMap { UInt64($0, radix: 16) }.map { $0 & standardSignals }, 0)
        await transport.stop()
    }

    func testIdleAgentStopsOnTerminationWithoutForceKill() async throws {
        let transport = try await Spawner().spawn(
            ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        let started = ContinuousClock.now
        await transport.stop()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertFalse(transport.wasForceKilled)
        var termination = transport.termination.makeAsyncIterator()
        let status = await termination.next()
        XCTAssertEqual(status, SIGTERM)
    }

    func testBackgroundChildHoldingOutputDoesNotDelayExit() async throws {
        let script = #"""
        sleep 30 &
        echo $! >&2
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
        sleep 0.1
        exit 3
        """#
        let runtime = ACPAgentRuntime(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            clientInfo: ACPImplementation(name: "latch-tests", version: "0.1.0")
        )
        var events = runtime.events.makeAsyncIterator()
        var standardError = runtime.standardError.makeAsyncIterator()

        let started = ContinuousClock.now
        _ = try await runtime.start()
        let line = await standardError.next().map { String(decoding: $0, as: UTF8.self) }
        let child = try XCTUnwrap(line.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let event = await events.next()
        XCTAssertEqual(event, .processTerminated(status: 3))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))

        let deadline = ContinuousClock.now + .seconds(3)
        while !processIsGone(child), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(processIsGone(child), "The agent's background child outlived it")
    }

    /// An ignored SIGPIPE survives exec, and agents rely on it to end pipelines like this one.
    func testPipeSignalKeepsItsDefaultDispositionInTheAgent() async throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(yes; echo $? >&2) | head -n 1 > /dev/null"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        let output = String(decoding: await collect(transport.standardError), as: UTF8.self)
        XCTAssertEqual(output, "141\n")
        var termination = transport.termination.makeAsyncIterator()
        let status = await termination.next()
        XCTAssertEqual(status, 0)
    }

    func testAgentInheritsNoDescriptorButItsStandardStreams() async throws {
        var leaked: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&leaked), 0)
        defer { leaked.forEach { _ = close($0) } }
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/ls"),
                arguments: ["/proc/self/fd"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        let listing = String(decoding: await collect(transport.incoming), as: UTF8.self)
        let descriptors = Set(listing.split(separator: "\n").compactMap { Int32($0) })
        // 3 is the directory ls itself is reading.
        XCTAssertEqual(descriptors, [0, 1, 2, 3])
    }

    /// A child that leaves the agent's group escapes the exit cleanup and can hold its output open.
    func testOutputEndsSoonAfterExitWhileAnEscapedChildHoldsIt() async throws {
        let started = ContinuousClock.now
        let transport = try ACPProcessTransport(
            configuration: ACPProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "setsid -f sh -c 'echo $$; exec sleep 30'; exit 0"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        var termination = transport.termination.makeAsyncIterator()
        let status = await termination.next()
        XCTAssertEqual(status, 0)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))

        let output = String(decoding: await collect(transport.incoming), as: UTF8.self)
        _ = await collect(transport.standardError)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        let escaped = try XCTUnwrap(pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(processIsGone(escaped))
        kill(escaped, SIGKILL)
    }

    func testReportsMissingExecutableAndWorkingDirectory() {
        XCTAssertThrowsError(
            try ACPProcessTransport(
                configuration: ACPProcessConfiguration(
                    executableURL: URL(fileURLWithPath: "/nonexistent/agent"),
                    arguments: [],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp")
                )
            )
        ) { error in
            XCTAssertEqual(error as? ACPProcessTransportError, .executableNotFound("/nonexistent/agent"))
        }
        XCTAssertThrowsError(
            try ACPProcessTransport(
                configuration: ACPProcessConfiguration(
                    executableURL: URL(fileURLWithPath: "/bin/cat"),
                    arguments: [],
                    workingDirectoryURL: URL(fileURLWithPath: "/nonexistent")
                )
            )
        ) { error in
            XCTAssertEqual(error as? ACPProcessTransportError, .workingDirectoryNotFound("/nonexistent"))
        }
    }

    func testDoesNotBlameAnExecutableWhoseInterpreterIsMissing() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("latch-\(UUID().uuidString)")
        try Data("#!/nonexistent/interpreter\n".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertThrowsError(
            try ACPProcessTransport(
                configuration: ACPProcessConfiguration(
                    executableURL: script,
                    arguments: [],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp")
                )
            )
        ) { error in
            XCTAssertEqual(error as? ACPProcessTransportError, .spawnFailed(errno: ENOENT))
        }
    }

    private func collect(_ stream: AsyncStream<Data>) async -> Data {
        var data = Data()
        for await chunk in stream {
            data.append(chunk)
        }
        return data
    }
}

/// Spawns on a Swift concurrency thread, as the agent service does.
private actor Spawner {
    func spawn(_ configuration: ACPProcessConfiguration) throws -> ACPProcessTransport {
        try ACPProcessTransport(configuration: configuration)
    }
}
#endif
