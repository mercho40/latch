import Darwin
import Foundation
import LatchAgentCore
import LatchAgentXPC
import LatchServiceProtocol

/// Test-only extension. Never expose this shutdown method from a production host.
@objc protocol ProcessProbeProtocol: LatchAgentXPCProtocol {
    func shutdown()
}

private let serviceName = "sh.latch.process-probe.service"

@main
struct LatchXPCProcessProbe {
    static func main() {
        // Bound both fixture processes, including failures before a reply or interruption.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fail("Timed out waiting for cross-process XPC probe")
        }
        if Bundle.main.bundleIdentifier == serviceName {
            let delegate = ProbeListener()
            let listener = NSXPCListener.service()
            listener.delegate = delegate
            withExtendedLifetime(delegate) {
                listener.resume()
                dispatchMain()
            }
        } else {
            Task {
                do {
                    try await runClient()
                    exit(EXIT_SUCCESS)
                } catch {
                    fail("\(error)")
                }
            }
            dispatchMain()
        }
    }

    @MainActor private static func runClient() async throws {
        let receiver = ProbeReceiver()
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ProcessProbeProtocol.self)
        connection.exportedInterface = LatchAgentXPCEventHub.interface()
        connection.exportedObject = receiver
        let closed = AsyncStream<Void>.makeStream()
        connection.interruptionHandler = { closed.continuation.yield(()); closed.continuation.finish() }
        connection.invalidationHandler = { closed.continuation.yield(()); closed.continuation.finish() }
        connection.resume()
        defer { connection.invalidate() }
        let client = ProbeClient(connection: connection)
        let empty = try await client.request(.listRuntimes)
        try require(empty == .runtimeList([]), "Initial registry was not empty")
        let servicePID = connection.processIdentifier
        try require(servicePID > 0 && servicePID != getpid(), "Service did not run in a separate process")
        print("PROCESS: client PID=\(getpid()) service PID=\(servicePID)")

        let id = AgentRuntimeID("cross-process")
        let start = try await client.request(.startRuntime(id: id, profile: ACPCommandProfile(
            executablePath: "/bin/sh", arguments: ["-c", mockAgent], workingDirectoryPath: "/tmp"
        )))
        guard case let .runtimeStarted(startedID, initialization) = start else {
            throw ProbeError.failed("Missing runtime-started response")
        }
        try require(startedID == id && initialization.protocolVersion == 1, "Invalid initialization")
        let session = try await client.request(.newSession(runtimeID: id, cwd: "/tmp"))
        guard case let .sessionCreated(sessionID, result) = session else {
            throw ProbeError.failed("Missing session-created response")
        }
        try require(sessionID == id && result.sessionId == "session-1", "Invalid session")

        let prompt = Task { try await client.request(.prompt(runtimeID: id, text: "Keep working")) }
        var events = receiver.events.makeAsyncIterator()
        guard let event = await events.next(),
              event.protocolVersion == LatchServiceProtocolVersion.current,
              event.sequence == 1,
              case let .sessionUpdate(eventID, notification) = event.event,
              eventID == id,
              case let .messageChunk(chunk) = notification.event,
              chunk.text == "working" else {
            throw ProbeError.failed("Missing sequenced progress over XPC")
        }
        print("PROCESS: received progress over XPC: working (sequence=1)")
        let ready = try await client.request(.listRuntimes)
        try require(ready == .runtimeList([AgentRuntimeSnapshot(id: id, state: .ready)]), "Listing blocked or changed during prompt")
        let cancellation = try await client.request(.cancelPrompt(runtimeID: id))
        try require(cancellation == .promptCancellationRequested(runtimeID: id), "Missing cancellation acknowledgement")
        guard case let .promptCompleted(promptID, response) = try await prompt.value else {
            throw ProbeError.failed("Missing prompt completion")
        }
        try require(promptID == id && response.stopReason == "cancelled", "Prompt was not cancelled")
        let stop = try await client.request(.stopRuntime(id: id))
        try require(stop == .runtimeStopped(runtimeID: id), "Missing runtime stop")
        let final = try await client.request(.listRuntimes)
        try require(final == .runtimeList([]), "Runtime was not removed")
        print("PROCESS: cancellation completed; runtime stopped; registry empty")

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in fail("\(error)") }) as? ProcessProbeProtocol else {
            throw ProbeError.failed("Missing shutdown proxy")
        }
        proxy.shutdown()
        var interruptions = closed.stream.makeAsyncIterator()
        _ = await interruptions.next()
        print("PROCESS: service connection closed after fixture shutdown; PASS")
    }

    private static let mockAgent = #"""
    while IFS= read -r line; do
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
          ;;
        *\"method\":\"session*new\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
          ;;
        *\"method\":\"session*prompt\"*)
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"working"}}}}'
          ;;
        *\"method\":\"session*cancel\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}'
          ;;
      esac
    done
    """#
}

private final class ProbeListener: NSObject, NSXPCListenerDelegate {
    private let service = LatchAgentService()
    private let hub: LatchAgentXPCEventHub
    private let exported: ProbeService

    override init() {
        hub = LatchAgentXPCEventHub(events: service.events)
        exported = ProbeService(service: service, hub: hub)
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Fixture-only admission. Bundled service is not an installed production endpoint.
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: ProcessProbeProtocol.self)
        connection.exportedObject = exported
        // Objective-C does not express ownership transfer; no access follows this handoff.
        nonisolated(unsafe) let transferred = connection
        Task { [hub] in
            await hub.start()
            do { try await hub.attach(transferred) }
            catch { fail("Service attachment failed: \(error)") }
        }
        return true
    }
}

private final class ProbeService: NSObject, ProcessProbeProtocol, Sendable {
    private let service: LatchAgentService
    private let hub: LatchAgentXPCEventHub
    private let adapter: LatchAgentXPCAdapter

    init(service: LatchAgentService, hub: LatchAgentXPCEventHub) {
        self.service = service
        self.hub = hub
        adapter = LatchAgentXPCAdapter(service: service)
        super.init()
    }

    func sendRequest(_ payload: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        adapter.sendRequest(payload, withReply: reply)
    }

    func shutdown() {
        Task {
            await service.shutdown()
            await hub.shutdown()
            exit(EXIT_SUCCESS)
        }
    }
}

@MainActor private final class ProbeClient {
    private let connection: NSXPCConnection
    init(connection: NSXPCConnection) { self.connection = connection }

    func request(_ command: LatchAgentCommand) async throws -> LatchAgentResponse {
        let request = LatchAgentRequest(command: command)
        let codec = LatchServiceCodec()
        let data = try codec.encode(request)
        let reply: LatchAgentReply = try await withCheckedThrowingContinuation { continuation in
            let completion = ProbeCompletion(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                completion.finish(.failure(error))
            }) as? ProcessProbeProtocol else {
                completion.finish(.failure(ProbeError.failed("Missing request proxy")))
                return
            }
            proxy.sendRequest(data) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw ProbeError.failed("Empty reply") }
                    completion.finish(.success(try codec.decode(LatchAgentReply.self, from: data)))
                } catch { completion.finish(.failure(error)) }
            }
        }
        try require(reply.requestID == request.requestID && reply.protocolVersion == request.protocolVersion, "Mismatched reply envelope")
        switch reply.result {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }
}

private final class ProbeReceiver: NSObject, LatchAgentXPCEventReceiver, Sendable {
    let events: AsyncStream<LatchAgentEventEnvelope>
    private let continuation: AsyncStream<LatchAgentEventEnvelope>.Continuation
    override init() {
        (events, continuation) = AsyncStream<LatchAgentEventEnvelope>.makeStream()
        super.init()
    }
    func receiveEvent(_ payload: Data, withReply reply: @escaping @Sendable () -> Void) {
        do { continuation.yield(try LatchServiceCodec().decode(LatchAgentEventEnvelope.self, from: payload)) }
        catch { fail("Invalid event: \(error)") }
        reply()
    }
}

/// Lock guards the one-shot continuation across reply/error callback queues.
private final class ProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LatchAgentReply, any Error>?
    init(_ continuation: CheckedContinuation<LatchAgentReply, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<LatchAgentReply, any Error>) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        pending?.resume(with: result)
    }
}

private enum ProbeError: Error { case failed(String) }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError.failed(message) }
}
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("LatchXPCProcessProbe: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}
