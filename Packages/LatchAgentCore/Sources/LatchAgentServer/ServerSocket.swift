import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An IPv4 (4 bytes) or IPv6 (16 bytes) address in network byte order, and a port.
public struct ServerSocketAddress: Hashable, Sendable, CustomStringConvertible {
    public var bytes: [UInt8]
    public var port: UInt16

    public init(bytes: [UInt8], port: UInt16) {
        precondition(bytes.count == 4 || bytes.count == 16)
        self.bytes = bytes
        self.port = port
    }

    public var isIPv6: Bool { bytes.count == 16 }

    /// `127.0.0.1:7428` or `[::1]:7428`.
    public var description: String {
        isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The address alone: `127.0.0.1` or `::1`.
    public var host: String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isIPv6 ? AF_INET6 : AF_INET
        return bytes.withUnsafeBytes { raw in
            guard inet_ntop(family, raw.baseAddress, &text, socklen_t(text.count)) != nil else { return "?" }
            return String(nulTerminated: text)
        }
    }

    init?(_ storage: sockaddr_storage) {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            let address = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in.self) }
            var ip = address.sin_addr
            self.init(bytes: withUnsafeBytes(of: &ip) { Array($0) }, port: UInt16(bigEndian: address.sin_port))
        case AF_INET6:
            let address = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in6.self) }
            var ip = address.sin6_addr
            self.init(bytes: withUnsafeBytes(of: &ip) { Array($0) }, port: UInt16(bigEndian: address.sin6_port))
        default:
            return nil
        }
    }

    /// Calls `body` with this address as a `sockaddr`.
    func withSocketAddress<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        if isIPv6 {
            var address = sockaddr_in6()
            #if canImport(Darwin)
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}

public struct ServerSocketError: Error, Equatable, Sendable, CustomStringConvertible {
    public var call: String
    public var code: Int32

    init(_ call: String, code: Int32 = errno) {
        self.call = call
        self.code = code
    }

    public var description: String { "\(call): \(String(cString: strerror(code)))" }
}

/// The socket calls the server makes, each retrying `EINTR`. Every descriptor is close-on-exec,
/// and no write can raise SIGPIPE.
enum ServerSocket {
    #if canImport(Glibc)
    static let streamType = Int32(SOCK_STREAM.rawValue)
    /// For `socket` only: close-on-exec from the start on Linux, where agents may be spawned
    /// while a socket is being made.
    static let closeOnExecStreamType = Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue)
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #elseif canImport(Musl)
    static let streamType = SOCK_STREAM
    static let closeOnExecStreamType = SOCK_STREAM | SOCK_CLOEXEC
    static let sendFlags = MSG_NOSIGNAL
    #else
    static let streamType = SOCK_STREAM
    static let closeOnExecStreamType = SOCK_STREAM
    static let sendFlags: Int32 = 0
    #endif

    /// A listening socket bound to `address`; for port 0, `bound` has the port the kernel chose.
    static func listen(on address: ServerSocketAddress, backlog: Int32 = 64) throws(ServerSocketError) -> (descriptor: Int32, bound: ServerSocketAddress) {
        let descriptor = socket(address.isIPv6 ? AF_INET6 : AF_INET, closeOnExecStreamType, 0)
        guard descriptor >= 0 else { throw ServerSocketError("socket") }
        do throws(ServerSocketError) {
            setCloseOnExec(descriptor)
            try setOption(descriptor, SOL_SOCKET, SO_REUSEADDR, 1, "SO_REUSEADDR")
            if address.isIPv6 {
                try setOption(descriptor, Int32(IPPROTO_IPV6), IPV6_V6ONLY, 1, "IPV6_V6ONLY")
            }
            // Nonblocking so a connection reset between poll and accept cannot stall the loop.
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
                throw ServerSocketError("fcntl")
            }
            let bound = address.withSocketAddress { posixBind(descriptor, $0, $1) }
            guard bound == 0 else { throw ServerSocketError("bind \(address)") }
            guard posixListen(descriptor, backlog) == 0 else { throw ServerSocketError("listen \(address)") }
            guard let local = localAddress(descriptor) else { throw ServerSocketError("getsockname") }
            return (descriptor, local)
        } catch {
            _ = posixClose(descriptor)
            throw error
        }
    }

    /// Waits for a connection or for `stop` to become readable. Nil when stopping.
    static func accept(from listener: Int32, stop: Int32) -> (descriptor: Int32, peer: ServerSocketAddress?)? {
        while true {
            var descriptors = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stop, events: Int16(POLLIN), revents: 0),
            ]
            guard poll(&descriptors, nfds_t(descriptors.count), -1) >= 0 else {
                if errno == EINTR { continue }
                return nil
            }
            if descriptors[1].revents != 0 { return nil }
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let descriptor = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixAccept(listener, $0, &length) }
            }
            if descriptor >= 0 {
                configureAccepted(descriptor)
                return (descriptor, ServerSocketAddress(storage))
            }
            switch errno {
            case EINTR, EAGAIN, EWOULDBLOCK, ECONNABORTED, EPROTO:
                continue
            default:
                // Out of descriptors, most likely; back off rather than spin.
                usleep(100_000)
            }
        }
    }

    /// Close-on-exec and blocking (Linux does not inherit the listener's flags; Darwin does),
    /// no SIGPIPE on Darwin, and no Nagle delay for the small frames most writes are. Swift's
    /// Glibc module has no `accept4`, so on Linux an agent spawned in the moment between
    /// `accept` and this can inherit the socket; it runs as the same user, and `shutdown` ends
    /// the connection whoever still holds the descriptor.
    static func configureAccepted(_ descriptor: Int32) {
        setCloseOnExec(descriptor)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        #if canImport(Darwin)
        try? setOption(descriptor, SOL_SOCKET, SO_NOSIGPIPE, 1, "SO_NOSIGPIPE")
        #endif
        try? setOption(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, 1, "TCP_NODELAY")
    }

    static func setCloseOnExec(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
    }

    /// Writes all of `data`, across partial writes. False once the peer is gone.
    static func sendAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = send(descriptor, pointer, remaining, sendFlags)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    /// Bytes read, 0 at end of stream, or -1 with `errno` set; never `EINTR`.
    static func receive(_ descriptor: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        while true {
            let received = recv(descriptor, buffer, count, 0)
            if received < 0, errno == EINTR { continue }
            return received
        }
    }

    /// Makes a blocked receive fail with `EAGAIN` after `timeout`; nil waits forever.
    static func setReceiveTimeout(_ descriptor: Int32, _ timeout: Duration?) {
        var value = timeval()
        if let timeout {
            let (seconds, attoseconds) = timeout.components
            value.tv_sec = .init(seconds)
            value.tv_usec = .init(max(attoseconds / 1_000_000_000_000, seconds == 0 ? 1 : 0))
        }
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Wakes any thread blocked on the socket; the descriptor stays open until `close`.
    static func shutdownBoth(_ descriptor: Int32) {
        _ = posixShutdown(descriptor, Int32(SHUT_RDWR))
    }

    static func shutdownRead(_ descriptor: Int32) {
        _ = posixShutdown(descriptor, Int32(SHUT_RD))
    }

    static func shutdownWrite(_ descriptor: Int32) {
        _ = posixShutdown(descriptor, Int32(SHUT_WR))
    }

    static func close(_ descriptor: Int32) {
        _ = posixClose(descriptor)
    }

    static func localAddress(_ descriptor: Int32) -> ServerSocketAddress? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return result == 0 ? ServerSocketAddress(storage) : nil
    }

    /// A blocking socket connected to `address`, or an error once `timeout` has passed or the
    /// peer refused. For `latch-server doctor`, which checks that a server answers.
    static func connect(to address: ServerSocketAddress, timeout: Duration) throws(ServerSocketError) -> Int32 {
        let descriptor = socket(address.isIPv6 ? AF_INET6 : AF_INET, closeOnExecStreamType, 0)
        guard descriptor >= 0 else { throw ServerSocketError("socket") }
        do throws(ServerSocketError) {
            setCloseOnExec(descriptor)
            let flags = fcntl(descriptor, F_GETFL)
            guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ServerSocketError("fcntl") }
            if address.withSocketAddress({ posixConnect(descriptor, $0, $1) }) != 0 {
                guard errno == EINPROGRESS else { throw ServerSocketError("connect \(address)") }
                var entry = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let (seconds, attoseconds) = timeout.components
                let ready = poll(&entry, 1, Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000))
                guard ready > 0 else { throw ServerSocketError("connect \(address)", code: ready == 0 ? ETIMEDOUT : errno) }
                var failure: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else { throw ServerSocketError("getsockopt") }
                guard failure == 0 else { throw ServerSocketError("connect \(address)", code: failure) }
            }
            guard fcntl(descriptor, F_SETFL, flags) == 0 else { throw ServerSocketError("fcntl") }
            return descriptor
        } catch {
            _ = posixClose(descriptor)
            throw error
        }
    }

    /// A close-on-exec pipe.
    static func makePipe() -> (read: Int32, write: Int32)? {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return nil }
        setCloseOnExec(descriptors[0])
        setCloseOnExec(descriptors[1])
        return (descriptors[0], descriptors[1])
    }

    private static func setOption(_ descriptor: Int32, _ level: Int32, _ name: Int32, _ value: Int32, _ label: String) throws(ServerSocketError) {
        var value = value
        guard setsockopt(descriptor, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ServerSocketError("setsockopt \(label)")
        }
    }
}

extension String {
    /// The text before the first NUL of a C buffer.
    init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// `ServerSocket` has members named like the libc calls; these reach the libc ones.
private func posixBind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    bind(descriptor, address, length)
}

private func posixConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(descriptor, address, length)
}

private func posixListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
    listen(descriptor, backlog)
}

private func posixAccept(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
    accept(descriptor, address, length)
}

private func posixShutdown(_ descriptor: Int32, _ how: Int32) -> Int32 {
    shutdown(descriptor, how)
}

private func posixClose(_ descriptor: Int32) -> Int32 {
    close(descriptor)
}
