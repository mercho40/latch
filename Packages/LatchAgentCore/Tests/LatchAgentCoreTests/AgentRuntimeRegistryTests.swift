import Foundation
import LatchACP
import XCTest
@testable import LatchAgentCore

final class AgentRuntimeRegistryTests: XCTestCase {
    func testStartsListsAndStopsMultipleRuntimes() async throws {
        let registry = AgentRuntimeRegistry()
        let firstID = AgentRuntimeID("first")
        let secondID = AgentRuntimeID("second")

        _ = try await registry.start(
            id: secondID,
            configuration: mockConfiguration(),
            clientInfo: clientInfo
        )
        _ = try await registry.start(
            id: firstID,
            configuration: mockConfiguration(),
            clientInfo: clientInfo
        )

        let first = try await registry.runtime(for: firstID)
        let second = try await registry.runtime(for: secondID)
        let runtimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(runtimeIDs, [firstID, secondID])
        let firstState = await first.state()
        let secondState = await second.state()
        XCTAssertEqual(firstState, .ready)
        XCTAssertEqual(secondState, .ready)

        try await registry.stop(id: firstID)
        let remainingRuntimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(remainingRuntimeIDs, [secondID])
        let stoppedFirstState = await first.state()
        XCTAssertEqual(stoppedFirstState, .stopped)

        await registry.stopAll()
        let emptyRuntimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(emptyRuntimeIDs, [])
        let stoppedSecondState = await second.state()
        XCTAssertEqual(stoppedSecondState, .stopped)
    }

    func testRejectsDuplicateRuntimeID() async throws {
        let registry = AgentRuntimeRegistry()
        let id = AgentRuntimeID("duplicate")
        _ = try await registry.start(
            id: id,
            configuration: mockConfiguration(),
            clientInfo: clientInfo
        )

        do {
            _ = try await registry.start(
                id: id,
                configuration: mockConfiguration(),
                clientInfo: clientInfo
            )
            XCTFail("Expected duplicate runtime ID to be rejected")
        } catch let error as AgentRuntimeRegistryError {
            XCTAssertEqual(error, .duplicateRuntime(id))
        }

        await registry.stopAll()
    }

    func testFailedStartReleasesReservedID() async throws {
        let registry = AgentRuntimeRegistry()
        let id = AgentRuntimeID("retry")
        let invalidConfiguration = ACPProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/path/that/does/not/exist"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        do {
            _ = try await registry.start(
                id: id,
                configuration: invalidConfiguration,
                clientInfo: clientInfo
            )
            XCTFail("Expected process launch to fail")
        } catch {
            // The process error is platform-specific; only registry recovery matters here.
        }

        let initialRuntimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(initialRuntimeIDs, [])
        _ = try await registry.start(
            id: id,
            configuration: mockConfiguration(),
            clientInfo: clientInfo
        )
        let recoveredRuntimeIDs = await registry.runtimeIDs()
        XCTAssertEqual(recoveredRuntimeIDs, [id])
        await registry.stopAll()
    }

    private var clientInfo: ACPImplementation {
        ACPImplementation(name: "latch-agent-core-tests", version: "0.1.0")
    }

    private func mockConfiguration() -> ACPProcessConfiguration {
        let script = #"""
        while IFS= read -r line; do
          case "$line" in
            *\"method\":\"initialize\"*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
              ;;
          esac
        done
        """#
        return ACPProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
    }
}
