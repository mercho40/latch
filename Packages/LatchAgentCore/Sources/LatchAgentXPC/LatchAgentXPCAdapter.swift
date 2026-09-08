import Foundation
import LatchAgentCore
import LatchServiceProtocol

/// One bounded JSON request and either a JSON reply or a transport error.
/// Command failures remain inside the versioned reply, not the NSError channel.
@objc public protocol LatchAgentXPCProtocol {
    func sendRequest(_ payload: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
}

public enum LatchAgentXPCErrorCode: Int, Sendable {
    case invalidPayload = 1
    case replyEncodingFailed = 2

    public static let domain = "sh.latch.agent.xpc"
}

/// Export on a connection only after its peer has been authorized by the host.
/// This adapter does not open a listener, authenticate clients, or own service shutdown.
public final class LatchAgentXPCAdapter: NSObject, LatchAgentXPCProtocol, Sendable {
    private let service: LatchAgentService
    private let codec: LatchServiceCodec

    public init(service: LatchAgentService, codec: LatchServiceCodec = LatchServiceCodec()) {
        self.service = service
        self.codec = codec
        super.init()
    }

    public static func interface() -> NSXPCInterface {
        NSXPCInterface(with: LatchAgentXPCProtocol.self)
    }

    public func sendRequest(
        _ payload: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        let request: LatchAgentRequest
        do {
            request = try codec.decode(LatchAgentRequest.self, from: payload)
        } catch {
            reply(nil, NSError(
                domain: LatchAgentXPCErrorCode.domain,
                code: LatchAgentXPCErrorCode.invalidPayload.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Invalid service request payload."]
            ))
            return
        }

        // Do not serialize requests behind a running prompt: cancellation must reach the actor.
        Task {
            let response = await service.handle(request)
            do {
                reply(try codec.encode(response), nil)
            } catch {
                // Execution may already have completed. Clients must not blindly retry mutations.
                reply(nil, NSError(
                    domain: LatchAgentXPCErrorCode.domain,
                    code: LatchAgentXPCErrorCode.replyEncodingFailed.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Could not encode service reply."]
                ))
            }
        }
    }
}
