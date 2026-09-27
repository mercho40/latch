import Foundation
import LatchAgentCore
import LatchServiceProtocol
import XCTest
@testable import LatchSessionKit

#if os(macOS)
/// This Mac's agent service in the test process, as the Mac app's SwiftPM preview hosts it.
final class InProcessAgentServiceClient: AgentServiceClient {
    private let service = LatchAgentService()
    var events: AsyncStream<LatchAgentEvent> { service.events }

    func execute(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        try await service.execute(command)
    }

    func close() {
        let service = service
        Task { await service.shutdown() }
    }

    var transportDescription: String { "in-process" }
}

extension SessionModel {
    /// A session on this Mac, with a service of its own in the test process.
    convenience init() {
        self.init(makeClient: { InProcessAgentServiceClient() })
    }
}
#endif

struct EventuallyTimeout: Error, CustomStringConvertible {
    let description: String
}

extension XCTestCase {
    /// Waits for a condition that may need the server to answer, such as a runtime's state.
    @MainActor func eventually(_ description: String, timeout: Duration = .seconds(15),
                    file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw EventuallyTimeout(description: "Timed out waiting for \(description)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
