import Foundation
import LatchAgentCore
import LatchServiceProtocol
import XCTest
@testable import LatchAgentXPC

final class LatchAgentXPCEventHubTests: XCTestCase {
    func testBroadcastsOrderedEnvelopesToTwoClientsAndSurvivesDisconnect() async throws {
        let source = AsyncStream<LatchAgentEvent>.makeStream()
        let hub = LatchAgentXPCEventHub(events: source.stream)
        await hub.start()
        let first = TestEventReceiver()
        let second = TestEventReceiver()
        let a = await connect(hub: hub, receiver: first)
        let b = await connect(hub: hub, receiver: second)
        defer { a.close(); b.close(); source.continuation.finish() }

        let runtimeID = AgentRuntimeID("events")
        let events: [LatchAgentEvent] = [
            .standardError(runtimeID: runtimeID, data: Data("diagnostic".utf8)),
            .processTerminated(runtimeID: runtimeID, status: 7),
        ]
        for event in events { source.continuation.yield(event) }
        await eventually { first.envelopes.count == 2 && second.envelopes.count == 2 }
        let expected = events.enumerated().map {
            LatchAgentEventEnvelope(sequence: UInt64($0.offset + 1), event: $0.element)
        }
        XCTAssertEqual(first.envelopes, expected)
        XCTAssertEqual(second.envelopes, expected)

        a.connection.invalidate()
        await eventually { await hub.subscriberCount == 1 }
        source.continuation.yield(events[0])
        await eventually { second.envelopes.count == 3 }
        XCTAssertEqual(first.envelopes.count, 2)
        XCTAssertEqual(second.envelopes.last?.sequence, 3)

        b.connection.invalidate()
        await eventually { await hub.subscriberCount == 0 }
        let reconnected = TestEventReceiver()
        let c = await connect(hub: hub, receiver: reconnected)
        defer { c.close() }
        source.continuation.yield(events[1])
        await eventually { reconnected.envelopes.count == 1 }
        XCTAssertEqual(reconnected.envelopes, [LatchAgentEventEnvelope(sequence: 4, event: events[1])])
        await hub.shutdown()
        let count = await hub.subscriberCount
        XCTAssertEqual(count, 0)
    }

    func testDisconnectsSlowClientWithoutBlockingHealthyClient() async {
        let source = AsyncStream<LatchAgentEvent>.makeStream()
        let hub = LatchAgentXPCEventHub(events: source.stream, maximumPendingEvents: 2)
        await hub.start()
        let slow = TestEventReceiver(acknowledges: false)
        let healthy = TestEventReceiver()
        let a = await connect(hub: hub, receiver: slow)
        let b = await connect(hub: hub, receiver: healthy)
        defer { a.close(); b.close(); source.continuation.finish() }
        let event = LatchAgentEvent.processTerminated(runtimeID: AgentRuntimeID("events"), status: 7)

        for count in 1...3 {
            source.continuation.yield(event)
            await eventually { healthy.envelopes.count == count }
        }
        await eventually { await hub.subscriberCount == 1 }
        XCTAssertEqual(slow.envelopes.count, 1)
        XCTAssertEqual(healthy.envelopes.map(\.sequence), [1, 2, 3])
        await hub.shutdown()
    }

    func testOversizedEventInvalidatesConnectionInsteadOfSilentlyDropping() async {
        let source = AsyncStream<LatchAgentEvent>.makeStream()
        let hub = LatchAgentXPCEventHub(events: source.stream, codec: LatchServiceCodec(maximumPayloadSize: 32))
        await hub.start()
        let receiver = TestEventReceiver()
        let client = await connect(hub: hub, receiver: receiver)
        defer { client.close(); source.continuation.finish() }
        let invalidated = expectation(description: "Oversized event interrupts client")
        client.connection.interruptionHandler = { invalidated.fulfill() }
        source.continuation.yield(.standardError(runtimeID: AgentRuntimeID("events"), data: Data(repeating: 65, count: 100)))
        await fulfillment(of: [invalidated], timeout: 5)
        await eventually { await hub.subscriberCount == 0 }
        XCTAssertTrue(receiver.envelopes.isEmpty)
        await hub.shutdown()
    }

    func testSourceCompletionAbortsPendingDeliveryAndPreventsReattachment() async {
        let source = AsyncStream<LatchAgentEvent>.makeStream()
        let hub = LatchAgentXPCEventHub(events: source.stream)
        await hub.start()
        let receiver = TestEventReceiver(acknowledges: false)
        let client = await connect(hub: hub, receiver: receiver)
        defer { client.close(); source.continuation.finish() }
        let invalidated = expectation(description: "Finished source interrupts client")
        client.connection.interruptionHandler = { invalidated.fulfill() }
        let event = LatchAgentEvent.processTerminated(runtimeID: AgentRuntimeID("events"), status: 7)
        source.continuation.yield(event)
        source.continuation.yield(event)
        await eventually { receiver.envelopes.count == 1 }
        // The first event is unacknowledged; final teardown must not wait on this client.
        source.continuation.finish()
        await fulfillment(of: [invalidated], timeout: 5)
        XCTAssertEqual(receiver.envelopes.map(\.sequence), [1])
        let count = await hub.subscriberCount
        XCTAssertEqual(count, 0)
        do {
            try await hub.attach(NSXPCConnection(listenerEndpoint: client.listener.endpoint))
            XCTFail("Stopped hub accepted a connection")
        } catch {
            guard case LatchAgentXPCEventHubError.stopped = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func connect(hub: LatchAgentXPCEventHub, receiver: TestEventReceiver) async -> EventTestClient {
        let attached = expectation(description: "Event client attached")
        let ready = expectation(description: "Initial XPC request completed")
        let client = EventTestClient(
            hub: hub, receiver: receiver,
            didAttach: { attached.fulfill() }, didReply: { ready.fulfill() }
        )
        await fulfillment(of: [attached, ready], timeout: 5)
        return client
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async {
        let done = expectation(description: "Event state reached")
        let task = Task {
            while !Task.isCancelled {
                if await condition() { done.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await fulfillment(of: [done], timeout: 5)
        task.cancel()
    }
}

/// Lock protects callbacks received on XPC queues and assertions made by async tests.
final class TestEventReceiver: NSObject, LatchAgentXPCEventReceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [LatchAgentEventEnvelope] = []
    private let acknowledges: Bool
    private let onEvent: @Sendable (LatchAgentEventEnvelope) -> Void
    private var heldReplies: [@Sendable () -> Void] = []

    init(acknowledges: Bool = true, onEvent: @escaping @Sendable (LatchAgentEventEnvelope) -> Void = { _ in }) {
        self.acknowledges = acknowledges
        self.onEvent = onEvent
        super.init()
    }

    var envelopes: [LatchAgentEventEnvelope] { lock.withLock { received } }

    func receiveEvent(_ payload: Data, withReply reply: @escaping @Sendable () -> Void) {
        do {
            let envelope = try LatchServiceCodec().decode(LatchAgentEventEnvelope.self, from: payload)
            lock.withLock {
                received.append(envelope)
                if !acknowledges { heldReplies.append(reply) }
            }
            onEvent(envelope)
        } catch {
            XCTFail("Invalid XPC event: \(error)")
        }
        if acknowledges { reply() }
    }
}

private final class EventTestClient {
    let delegate: TestListenerDelegate
    let listener: NSXPCListener
    let connection: NSXPCConnection

    init(
        hub: LatchAgentXPCEventHub,
        receiver: TestEventReceiver,
        didAttach: @escaping @Sendable () -> Void,
        didReply: @escaping @Sendable () -> Void
    ) {
        delegate = TestListenerDelegate(
            adapter: LatchAgentXPCAdapter(service: LatchAgentService()),
            eventHub: hub,
            didAttach: didAttach
        )
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.exportedInterface = LatchAgentXPCEventHub.interface()
        connection.exportedObject = receiver
        connection.remoteObjectInterface = LatchAgentXPCAdapter.interface()
        connection.resume()
        // Force the lazy XPC connection to connect, even before any events exist.
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("Event test connection failed: \(error)")
        } as? LatchAgentXPCProtocol
        proxy?.sendRequest(try! LatchServiceCodec().encode(LatchAgentRequest(command: .listRuntimes))) { data, error in
            XCTAssertNotNil(data)
            XCTAssertNil(error)
            didReply()
        }
    }

    func close() {
        connection.invalidate()
        listener.invalidate()
    }
}
