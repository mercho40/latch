import Foundation
import LatchRemoteProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One connection to a latch-server on this machine, for the commands that ask it something:
/// `doctor` and `runtimes`. Blocking, one request at a time; events are skipped.
struct ServerLocalClient {
    enum Failure: Error, Equatable {
        case nothingListening
        case unreachable(String)
        case notLatch
        case rejected(LatchRemoteRejectReason)
        case closed
    }

    let welcome: LatchRemoteWelcome
    private let descriptor: Int32
    private var decoder = LatchRemoteLineDecoder(maximumLineBytes: 64 * 1024)

    /// Connects and says hello with `token`.
    init(connectingTo address: ServerSocketAddress, token: LatchRemoteToken, timeout: Duration = .seconds(5)) throws(Failure) {
        do {
            descriptor = try ServerSocket.connect(to: address, timeout: .seconds(3))
        } catch {
            throw error.code == ECONNREFUSED ? .nothingListening : .unreachable(String(cString: strerror(error.code)))
        }
        ServerSocket.setReceiveTimeout(descriptor, timeout)
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "Linux"
        #endif
        let hello = LatchRemoteClientFrame.hello(LatchRemoteHello(
            token: token.rawValue,
            client: LatchRemoteClientInfo(name: "latch-server", version: LatchServerVersion.current, platform: platform)
        ))
        var welcome: LatchRemoteWelcome?
        do throws(Failure) {
            guard let line = try? LatchRemoteCoding.encodeLine(hello), ServerSocket.sendAll(descriptor, line) else { throw .notLatch }
            switch try? LatchRemoteCoding.decode(LatchRemoteServerFrame.self, fromLine: Self.readLine(descriptor, &decoder)) {
            case let .welcome(received)?: welcome = received
            case let .rejected(rejected)?: throw .rejected(rejected.reason)
            default: throw .notLatch
            }
        } catch {
            ServerSocket.close(descriptor)
            throw error
        }
        self.welcome = welcome!
        decoder.maximumLineBytes = LatchRemoteProtocol.maxFrameBytes
    }

    /// Sends `command` and waits for its reply.
    mutating func request(_ command: LatchRemoteCommand) throws(Failure) -> LatchRemoteReplyResult {
        let id = UUID()
        guard let line = try? LatchRemoteCoding.encodeLine(LatchRemoteClientFrame.request(LatchRemoteRequest(id: id, command: command))),
              ServerSocket.sendAll(descriptor, line) else { throw .closed }
        while true {
            let line = try Self.readLine(descriptor, &decoder)
            if case let .reply(reply)? = try? LatchRemoteCoding.decode(LatchRemoteServerFrame.self, fromLine: line), reply.id == id {
                return reply.result
            }
        }
    }

    func close() {
        ServerSocket.close(descriptor)
    }

    private static func readLine(_ descriptor: Int32, _ decoder: inout LatchRemoteLineDecoder) throws(Failure) -> Data {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            do {
                if let line = try decoder.nextLine() { return line }
            } catch {
                throw .notLatch
            }
            let count = ServerSocket.receive(descriptor, into: buffer, count: 64 * 1024)
            guard count > 0 else { throw .closed }
            decoder.append(Data(bytes: buffer, count: count))
        }
    }
}
