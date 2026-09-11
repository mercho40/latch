import Foundation

public enum ACPJSONRPCID: Hashable, Sendable {
    case integer(Int64)
    case string(String)
}

extension ACPJSONRPCID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be an integer or string"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

public struct ACPJSONRPCErrorObject: Codable, Error, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: ACPJSONValue?

    public init(code: Int, message: String, data: ACPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct ACPJSONRPCNotification: Equatable, Sendable {
    public let method: String
    public let params: ACPJSONValue?

    /// Connection-local ingress order; zero denotes a manually constructed notification.
    public let sequence: UInt64

    public init(method: String, params: ACPJSONValue? = nil, sequence: UInt64 = 0) {
        self.method = method
        self.params = params
        self.sequence = sequence
    }
}

public struct ACPJSONRPCRequest: Equatable, Sendable {
    public let id: ACPJSONRPCID
    public let method: String
    public let params: ACPJSONValue?

    public init(id: ACPJSONRPCID, method: String, params: ACPJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum ACPJSONRPCConnectionError: Error, Equatable, Sendable {
    case alreadyRunning
    case closed
    case oversizedFrame
    case malformedJSON
    case invalidMessage(String)
}

/// A transport-neutral JSON-RPC 2.0 client for ACP's newline-delimited JSON stream.
///
/// The caller owns the byte transport. `incoming` may contain arbitrary fragments and
/// `send` receives one complete UTF-8 JSON frame including its trailing newline.
public final class ACPJSONRPCConnection: Sendable {
    public typealias SendBytes = @Sendable (Data) async throws -> Void
    public typealias RequestHandler = @Sendable (ACPJSONRPCRequest) async throws -> ACPJSONValue?

    public let notifications: AsyncStream<ACPJSONRPCNotification>

    private let incoming: AsyncStream<Data>
    private let sendBytes: SendBytes
    private let core: Core
    private let maximumFrameSize: Int

    public init(
        incoming: AsyncStream<Data>,
        maximumFrameSize: Int = ACPFrameDecoder.defaultMaximumFrameSize,
        send: @escaping SendBytes
    ) {
        precondition(maximumFrameSize > 0)
        let notificationPair = AsyncStream<ACPJSONRPCNotification>.makeStream()
        self.incoming = incoming
        self.maximumFrameSize = maximumFrameSize
        self.sendBytes = send
        self.notifications = notificationPair.stream
        self.core = Core(notificationContinuation: notificationPair.continuation)
    }

    /// Consumes incoming bytes until the stream closes or a protocol error occurs.
    /// Exactly one task must own this loop for the lifetime of a connection.
    /// Incoming request handlers run concurrently so human decisions do not block the stream.
    /// Duplicate active IDs or more than 32 outstanding handlers close the connection.
    /// Closing cancels handlers; handlers must cooperate with task cancellation.
    public func run() async throws {
        try await core.beginRunning()
        var decoder = ACPFrameDecoder(maximumFrameSize: maximumFrameSize)

        do {
            for await chunk in incoming {
                try Task.checkCancellation()
                for event in decoder.append(chunk) {
                    switch event {
                    case .oversizedFrame:
                        throw ACPJSONRPCConnectionError.oversizedFrame
                    case let .frame(data):
                        if let request = try await core.receive(data) {
                            try await core.startIncomingRequest(request) {
                                await self.handleIncomingRequest(request)
                            }
                        }
                    }
                }
            }

            await core.close(with: ACPJSONRPCConnectionError.closed)
        } catch {
            await core.close(with: error)
            throw error
        }
    }

    public func setRequestHandler(_ handler: RequestHandler?) async {
        await core.setRequestHandler(handler)
    }

    public func request<Result: Decodable & Sendable>(
        _ method: String,
        params: ACPJSONValue? = nil,
        as resultType: Result.Type = Result.self
    ) async throws -> Result {
        try await requestWithSequence(method, params: params, as: resultType).response
    }

    /// Returns the response and its connection-local ingress sequence, assigned before delivery.
    public func requestWithSequence<Result: Decodable & Sendable>(
        _ method: String,
        params: ACPJSONValue? = nil,
        as resultType: Result.Type = Result.self
    ) async throws -> (response: Result, sequence: UInt64) {
        let pending = try await core.makePendingRequest(method: method, params: params)

        do {
            try await sendBytes(try Self.encodeFrame(pending.message))
        } catch {
            await core.failRequest(id: pending.id, error: error)
            throw error
        }

        let value = try await withTaskCancellationHandler {
            var iterator = pending.responses.makeAsyncIterator()
            guard let response = try await iterator.next() else {
                throw ACPJSONRPCConnectionError.closed
            }
            return response
        } onCancel: {
            Task {
                await self.core.failRequest(
                    id: pending.id,
                    error: CancellationError()
                )
            }
        }

        return (try value.response.decode(resultType), value.sequence)
    }

    public func notify(_ method: String, params: ACPJSONValue? = nil) async throws {
        let message = Self.requestObject(id: nil, method: method, params: params)
        try await sendBytes(try Self.encodeFrame(message))
    }

    private func handleIncomingRequest(_ request: ACPJSONRPCRequest) async {
        let handler = await core.requestHandler()
        guard !Task.isCancelled else { return }
        let response: ACPJSONValue

        guard let handler else {
            response = Self.errorResponse(
                id: request.id,
                error: ACPJSONRPCErrorObject(code: -32601, message: "Method not found")
            )
            try? await sendBytes(Self.encodeFrame(response))
            return
        }

        do {
            let result = try await handler(request) ?? .null
            response = Self.resultResponse(id: request.id, result: result)
        } catch let error as ACPJSONRPCErrorObject {
            response = Self.errorResponse(id: request.id, error: error)
        } catch {
            response = Self.errorResponse(
                id: request.id,
                error: ACPJSONRPCErrorObject(code: -32603, message: "Internal error")
            )
        }

        guard !Task.isCancelled else { return }
        try? await sendBytes(Self.encodeFrame(response))
    }

    private static func encodeFrame(_ value: ACPJSONValue) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    private static func requestObject(
        id: ACPJSONRPCID?,
        method: String,
        params: ACPJSONValue?
    ) -> ACPJSONValue {
        var object: [String: ACPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let id {
            object["id"] = id.jsonValue
        }
        if let params {
            object["params"] = params
        }
        return .object(object)
    }

    private static func resultResponse(
        id: ACPJSONRPCID,
        result: ACPJSONValue
    ) -> ACPJSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "result": result,
        ])
    }

    private static func errorResponse(
        id: ACPJSONRPCID,
        error: ACPJSONRPCErrorObject
    ) -> ACPJSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "error": (try? ACPJSONValue.encode(error)) ?? .object([
                "code": .integer(Int64(error.code)),
                "message": .string(error.message),
            ]),
        ])
    }
}

private extension ACPJSONRPCID {
    var jsonValue: ACPJSONValue {
        switch self {
        case let .integer(value):
            return .integer(value)
        case let .string(value):
            return .string(value)
        }
    }

    init?(jsonValue: ACPJSONValue) {
        switch jsonValue {
        case let .integer(value):
            self = .integer(value)
        case let .string(value):
            self = .string(value)
        default:
            return nil
        }
    }
}

private extension ACPJSONRPCConnection {
    typealias SequencedResponse = (response: ACPJSONValue, sequence: UInt64)

    struct PendingRequest: Sendable {
        let id: ACPJSONRPCID
        let message: ACPJSONValue
        let responses: AsyncThrowingStream<SequencedResponse, Error>
    }

    actor Core {
        private enum State {
            case idle
            case running
            case closed
        }

        private var state = State.idle
        private var nextRequestID: Int64 = 1
        private var ingressSequence: UInt64 = 0
        private var pendingRequests: [
            ACPJSONRPCID: AsyncThrowingStream<SequencedResponse, Error>.Continuation
        ] = [:]
        private var handler: RequestHandler?
        private var incomingRequests: [ACPJSONRPCID: Task<Void, Never>] = [:]
        private let notificationContinuation: AsyncStream<ACPJSONRPCNotification>.Continuation

        init(notificationContinuation: AsyncStream<ACPJSONRPCNotification>.Continuation) {
            self.notificationContinuation = notificationContinuation
        }

        func beginRunning() throws {
            guard case .idle = state else {
                throw state == .running
                    ? ACPJSONRPCConnectionError.alreadyRunning
                    : ACPJSONRPCConnectionError.closed
            }
            state = .running
        }

        // A permission handler may wait for a human. Never block responses, notifications,
        // or EOF behind it. Bound outstanding tasks and cancel them when the stream closes.
        func startIncomingRequest(
            _ request: ACPJSONRPCRequest,
            operation: @escaping @Sendable () async -> Void
        ) throws {
            guard state != .closed else { throw ACPJSONRPCConnectionError.closed }
            guard incomingRequests[request.id] == nil else {
                throw ACPJSONRPCConnectionError.invalidMessage("Duplicate in-flight request id")
            }
            guard incomingRequests.count < 32 else {
                throw ACPJSONRPCConnectionError.invalidMessage("Too many in-flight requests")
            }
            incomingRequests[request.id] = Task {
                await operation()
                incomingRequests.removeValue(forKey: request.id)
            }
        }

        func setRequestHandler(_ handler: RequestHandler?) {
            self.handler = handler
        }

        func requestHandler() -> RequestHandler? {
            handler
        }

        func makePendingRequest(
            method: String,
            params: ACPJSONValue?
        ) throws -> PendingRequest {
            guard state != .closed else {
                throw ACPJSONRPCConnectionError.closed
            }

            let id = ACPJSONRPCID.integer(nextRequestID)
            nextRequestID += 1
            let pair = AsyncThrowingStream<SequencedResponse, Error>.makeStream()
            pendingRequests[id] = pair.continuation

            return PendingRequest(
                id: id,
                message: ACPJSONRPCConnection.requestObject(
                    id: id,
                    method: method,
                    params: params
                ),
                responses: pair.stream
            )
        }

        func failRequest(id: ACPJSONRPCID, error: any Error) {
            guard let continuation = pendingRequests.removeValue(forKey: id) else {
                return
            }
            continuation.finish(throwing: error)
        }

        func receive(_ data: Data) throws -> ACPJSONRPCRequest? {
            // One counter for every frame, before any response/notification is delivered.
            ingressSequence += 1
            let value: ACPJSONValue
            do {
                value = try JSONDecoder().decode(ACPJSONValue.self, from: data)
            } catch {
                throw ACPJSONRPCConnectionError.malformedJSON
            }

            guard case let .object(object) = value else {
                throw ACPJSONRPCConnectionError.invalidMessage("Root must be an object")
            }
            guard object["jsonrpc"] == .string("2.0") else {
                throw ACPJSONRPCConnectionError.invalidMessage("Missing JSON-RPC 2.0 marker")
            }

            if case let .string(method)? = object["method"] {
                if let idValue = object["id"], let id = ACPJSONRPCID(jsonValue: idValue) {
                    return ACPJSONRPCRequest(id: id, method: method, params: object["params"])
                }

                notificationContinuation.yield(
                    ACPJSONRPCNotification(method: method, params: object["params"], sequence: ingressSequence)
                )
                return nil
            }

            guard let idValue = object["id"], let id = ACPJSONRPCID(jsonValue: idValue) else {
                throw ACPJSONRPCConnectionError.invalidMessage("Response is missing an id")
            }
            guard let continuation = pendingRequests.removeValue(forKey: id) else {
                return nil
            }

            if let errorValue = object["error"] {
                let error: ACPJSONRPCErrorObject
                do {
                    error = try errorValue.decode(ACPJSONRPCErrorObject.self)
                } catch {
                    continuation.finish(
                        throwing: ACPJSONRPCConnectionError.invalidMessage(
                            "Response contains an invalid error object"
                        )
                    )
                    return nil
                }
                continuation.finish(throwing: error)
                return nil
            }

            guard let result = object["result"] else {
                continuation.finish(
                    throwing: ACPJSONRPCConnectionError.invalidMessage(
                        "Response contains neither result nor error"
                    )
                )
                return nil
            }

            continuation.yield((response: result, sequence: ingressSequence))
            continuation.finish()
            return nil
        }

        func close(with error: any Error) {
            guard state != .closed else {
                return
            }
            state = .closed
            for task in incomingRequests.values { task.cancel() }
            incomingRequests.removeAll()
            for continuation in pendingRequests.values {
                continuation.finish(throwing: error)
            }
            pendingRequests.removeAll()
            notificationContinuation.finish()
        }
    }
}
