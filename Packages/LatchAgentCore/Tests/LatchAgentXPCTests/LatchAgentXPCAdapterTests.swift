import Foundation
import LatchAgentCore
import LatchAgentXPC
import LatchServiceProtocol
import XCTest

final class LatchAgentXPCAdapterTests: XCTestCase {
    func testRequestReplyAcrossAnonymousConnection() async throws {
        let codec = LatchServiceCodec()
        let request = LatchAgentRequest(command: .listRuntimes)
        try await exchange(try codec.encode(request)) { data, error in
            XCTAssertNil(error)
            guard let data else { return XCTFail("Missing reply payload") }
            XCTAssertEqual(
                try? codec.decode(LatchAgentReply.self, from: data),
                LatchAgentReply(requestID: request.requestID, result: .success(.runtimeList([])))
            )
        }
    }

    func testUnsupportedVersionReturnsCorrelatedServiceFailure() async throws {
        let codec = LatchServiceCodec()
        let request = LatchAgentRequest(protocolVersion: 999, command: .listRuntimes)
        try await exchange(try codec.encode(request)) { data, error in
            XCTAssertNil(error)
            guard let data else { return XCTFail("Missing reply payload") }
            XCTAssertEqual(
                try? codec.decode(LatchAgentReply.self, from: data),
                LatchAgentReply(requestID: request.requestID, result: .failure(LatchAgentFailure(
                    code: .unsupportedProtocolVersion,
                    message: "Unsupported service protocol version."
                )))
            )
        }
    }

    func testCommandFailureUsesReplyRatherThanTransportError() async throws {
        let codec = LatchServiceCodec()
        let request = LatchAgentRequest(command: .stopRuntime(id: AgentRuntimeID("missing")))
        try await exchange(try codec.encode(request)) { data, error in
            XCTAssertNil(error)
            guard let data else { return XCTFail("Missing reply payload") }
            XCTAssertEqual(
                try? codec.decode(LatchAgentReply.self, from: data),
                LatchAgentReply(requestID: request.requestID, result: .failure(LatchAgentFailure(
                    code: .commandFailed,
                    message: "Runtime not found."
                )))
            )
        }
    }

    func testRejectsEmptyMalformedAndOversizedPayloads() async throws {
        for payload in [Data(), Data("not JSON".utf8), Data(repeating: 32, count: 257)] {
            try await exchange(payload, codec: LatchServiceCodec(maximumPayloadSize: 256)) { data, error in
                XCTAssertNil(data)
                XCTAssertEqual(error?.domain, LatchAgentXPCErrorCode.domain)
                XCTAssertEqual(error?.code, LatchAgentXPCErrorCode.invalidPayload.rawValue)
                XCTAssertEqual(error?.localizedDescription, "Invalid service request payload.")
            }
        }
    }

    func testReplyEncodingFailureUsesSanitizedTransportError() async throws {
        let request = LatchAgentRequest(command: .stopRuntime(id: AgentRuntimeID("missing")))
        let payload = try LatchServiceCodec().encode(request)
        let expectedReply = LatchAgentReply(requestID: request.requestID, result: .failure(
            LatchAgentFailure(code: .commandFailed, message: "Runtime not found.")
        ))
        XCTAssertGreaterThan(try LatchServiceCodec().encode(expectedReply).count, payload.count)
        try await exchange(payload, codec: LatchServiceCodec(maximumPayloadSize: payload.count)) { data, error in
            XCTAssertNil(data)
            XCTAssertEqual(error?.domain, LatchAgentXPCErrorCode.domain)
            XCTAssertEqual(error?.code, LatchAgentXPCErrorCode.replyEncodingFailed.rawValue)
            XCTAssertEqual(error?.localizedDescription, "Could not encode service reply.")
        }
    }

    private func exchange(
        _ payload: Data,
        codec: LatchServiceCodec = LatchServiceCodec(),
        check: @escaping @Sendable (Data?, NSError?) -> Void
    ) async throws {
        let service = LatchAgentService()
        let delegate = TestListenerDelegate(adapter: LatchAgentXPCAdapter(service: service, codec: codec))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = LatchAgentXPCAdapter.interface()
        connection.resume()
        defer {
            connection.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }

        let finished = expectation(description: "XPC request completed")
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC connection failed: \(error)")
            finished.fulfill()
        } as? LatchAgentXPCProtocol)
        proxy.sendRequest(payload) { data, error in
            check(data, error)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        await service.shutdown()
    }
}

/// Anonymous endpoint used only within this test process; not a production admission policy.
final class TestListenerDelegate: NSObject, NSXPCListenerDelegate {
    let adapter: LatchAgentXPCAdapter

    init(adapter: LatchAgentXPCAdapter) {
        self.adapter = adapter
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = LatchAgentXPCAdapter.interface()
        connection.exportedObject = adapter
        connection.resume()
        return true
    }
}
