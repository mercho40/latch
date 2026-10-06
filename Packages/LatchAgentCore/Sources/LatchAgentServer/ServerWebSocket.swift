import Foundation
import LatchRemoteProtocol

/// The WebSocket side of the server's port (RFC 6455), for clients that reach the server
/// through a TLS proxy such as a Cloudflare Tunnel: the proxy ends TLS and forwards the
/// upgrade to the server's loopback address. Joined, the payloads of a connection's data
/// frames carry the same newline-delimited stream as TCP; where a frame ends means nothing.
enum ServerWebSocket {
    /// The longest request head accepted, through its blank line; a proxy's headers fit
    /// many times over.
    static let maxRequestHeadBytes = 16 * 1024
    /// The most payload the server puts in one frame, so a proxy never holds much of one.
    static let maxPayloadPerFrame = 0xFFFF

    static let opcodeContinuation: UInt8 = 0x0
    static let opcodeText: UInt8 = 0x1
    static let opcodeBinary: UInt8 = 0x2
    static let opcodeClose: UInt8 = 0x8
    static let opcodePing: UInt8 = 0x9
    static let opcodePong: UInt8 = 0xA

    /// Whether a connection's first byte begins an HTTP request, whose method is upper-case
    /// letters, rather than a hello, which always begins with `{`. Only `GET` can open a
    /// WebSocket; any other method, such as a proxy's `HEAD` check, gets an HTTP answer too.
    static func beginsRequest(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    /// The length of the request head in `bytes`, through the blank line that ends it, or
    /// nil while it is incomplete. A head that ends anywhere ends at or after `start`, the
    /// length already searched, so a head arriving a byte at a time is scanned once.
    static func requestHeadLength(in bytes: [UInt8], from start: Int = 0) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in max(3, start)..<bytes.count where bytes[index] == 0x0A {
            if bytes[index - 1] == 0x0D, bytes[index - 2] == 0x0A, bytes[index - 3] == 0x0D { return index + 1 }
        }
        return nil
    }

    // MARK: The upgrade

    /// A request the server switches to WebSocket for.
    struct Upgrade: Equatable {
        /// `Sec-WebSocket-Accept` for the response.
        var accept: String
    }

    /// Why a request gets an HTTP error instead of a WebSocket.
    enum Refusal: Error, Equatable {
        /// Not a WebSocket upgrade at all, such as a browser or `curl` checking the tunnel.
        case notAnUpgrade
        case malformed(String)
        case unsupportedVersion
        /// Browsers send `Origin` with every WebSocket and Latch never does, so a web page
        /// cannot use a browser on this machine, or a tunnel, to reach the server.
        case fromAWebPage
        case headTooLarge

        var status: String {
            switch self {
            case .notAnUpgrade, .unsupportedVersion: "426 Upgrade Required"
            case .malformed: "400 Bad Request"
            case .fromAWebPage: "403 Forbidden"
            case .headTooLarge: "431 Request Header Fields Too Large"
            }
        }

        /// For the server log.
        var reason: String {
            switch self {
            case .notAnUpgrade: "sent an HTTP request that is not a WebSocket upgrade"
            case let .malformed(what): "sent a malformed WebSocket upgrade: \(what)"
            case .unsupportedVersion: "asked for a WebSocket version other than 13"
            case .fromAWebPage: "sent a WebSocket upgrade from a web page"
            case .headTooLarge: "sent an HTTP request head over \(ServerWebSocket.maxRequestHeadBytes) bytes"
            }
        }

        /// The whole response, after which the connection closes.
        var response: Data {
            var head = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n"
            if case .notAnUpgrade = self { head += "Upgrade: websocket\r\n" }
            if self == .notAnUpgrade || self == .unsupportedVersion { head += "Sec-WebSocket-Version: 13\r\n" }
            return Data((head + "\r\n").utf8)
        }
    }

    /// A request head, as `requestHeadLength` delimits it: its request line's parts, and
    /// its headers by lower-case name.
    struct Head {
        var requestLine: [Substring]
        var headers: [String: [String]] = [:]

        init(_ bytes: [UInt8]) throws(Refusal) {
            var lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
            while lines.last?.isEmpty == true { lines.removeLast() }
            guard let first = lines.first else { throw .malformed("no request line") }
            requestLine = first.split(separator: " ", omittingEmptySubsequences: false)
            guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw .malformed("not an HTTP/1.1 request line") }
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw .malformed("a header line without a colon") }
                let name = line[..<colon].lowercased()
                headers[name, default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }

        /// The comma-separated values of every header called `name`, in order.
        func tokens(_ name: String) -> [String] {
            (headers[name] ?? []).flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }

        /// The last address in `X-Forwarded-For`: the client as the nearest proxy saw it. Only
        /// a proxy on this machine is believed.
        var forwardedFor: [UInt8]? {
            tokens("x-forwarded-for").last.flatMap { entry in
                // An IPv6 entry may come bracketed; ports and zones are not addresses.
                var address = Substring(entry)
                if address.hasPrefix("["), address.hasSuffix("]") { address = address.dropFirst().dropLast() }
                return LatchRemoteAddressPolicy.numericAddress(String(address)).flatMap(LatchRemoteAddressPolicy.unmapped)
            }
        }
    }

    /// Checks a request head for a WebSocket upgrade.
    static func upgrade(fromHead head: Head) throws(Refusal) -> Upgrade {
        guard head.requestLine[0] == "GET", head.requestLine[2] == "HTTP/1.1" else { throw .notAnUpgrade }
        guard head.tokens("upgrade").contains("websocket"), head.tokens("connection").contains("upgrade") else { throw .notAnUpgrade }
        guard head.headers["origin"] == nil else { throw .fromAWebPage }
        guard head.headers["sec-websocket-version"] == ["13"] else { throw .unsupportedVersion }
        guard let keys = head.headers["sec-websocket-key"], keys.count == 1, let key = keys.first,
              Data(base64Encoded: key)?.count == 16 else { throw .malformed("no valid Sec-WebSocket-Key") }
        return Upgrade(accept: acceptValue(forKey: key))
    }

    static func upgrade(fromHead bytes: [UInt8]) throws(Refusal) -> Upgrade {
        try upgrade(fromHead: Head(bytes))
    }

    /// RFC 6455 §4.2.2: the key and a fixed GUID, hashed with SHA-1, in base64.
    static func acceptValue(forKey key: String) -> String {
        Data(SHA1.hash(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    static func switchingProtocols(_ upgrade: Upgrade) -> Data {
        Data((
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(upgrade.accept)\r\n\r\n"
        ).utf8)
    }

    // MARK: Frames

    /// Stream bytes as unmasked binary frames of at most `maxPayloadPerFrame` each.
    static func binaryFrames(_ payload: Data) -> Data {
        var frames = Data()
        frames.reserveCapacity(payload.count + (payload.count / maxPayloadPerFrame + 1) * 4)
        var start = payload.startIndex
        repeat {
            let end = payload.index(start, offsetBy: min(maxPayloadPerFrame, payload.endIndex - start))
            appendFrame(opcode: opcodeBinary, payload: payload[start..<end], to: &frames)
            start = end
        } while start < payload.endIndex
        return frames
    }

    /// A close frame with a status code: 1001 when the server is going away, 1008 when it
    /// refused the client.
    static func closeFrame(code: UInt16) -> Data {
        frame(opcode: opcodeClose, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    /// One unmasked frame with FIN set; a control frame's payload is at most 125 bytes.
    static func frame(opcode: UInt8, payload: Data = Data()) -> Data {
        var frame = Data()
        appendFrame(opcode: opcode, payload: payload, to: &frame)
        return frame
    }

    private static func appendFrame(opcode: UInt8, payload: Data, to frames: inout Data) {
        frames.append(0x80 | opcode)
        switch payload.count {
        case ..<126:
            frames.append(UInt8(payload.count))
        case ...0xFFFF:
            frames.append(126)
            frames.append(UInt8(payload.count >> 8))
            frames.append(UInt8(payload.count & 0xFF))
        default:
            frames.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frames.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        frames.append(payload)
    }

    enum FrameError: Error, Equatable, CustomStringConvertible {
        case unmasked
        case reservedBits
        case unknownOpcode(UInt8)
        case invalidControlFrame
        case invalidLength

        var description: String {
            switch self {
            case .unmasked: "an unmasked frame"
            case .reservedBits: "a frame with reserved bits set"
            case let .unknownOpcode(opcode): "a frame with opcode \(opcode)"
            case .invalidControlFrame: "a fragmented or oversized control frame"
            case .invalidLength: "a frame with an invalid length"
            }
        }
    }

    /// What a client's frames carry, in order.
    enum Received: Equatable {
        /// Stream bytes, from text, binary or continuation frames alike.
        case data(Data)
        case ping(Data)
        case close
    }

    /// Unmasks a client's frames as their bytes arrive, without holding a whole frame. The
    /// line decoder the data goes to bounds what a frame can make the server keep.
    struct FrameDecoder {
        private var header: [UInt8] = []
        private var opcode: UInt8 = 0
        private var mask: [UInt8] = []
        private var maskOffset = 0
        private var remaining: UInt64 = 0
        private var inFrame = false
        private var control: [UInt8] = []
        private var failure: FrameError?

        /// Every frame's contents that `bytes` completes or continues. Throws on the first
        /// frame that breaks RFC 6455, and from then on.
        mutating func decode(_ bytes: Data) throws(FrameError) -> [Received] {
            if let failure { throw failure }
            var received: [Received] = []
            var index = bytes.startIndex
            while index < bytes.endIndex || (inFrame && remaining == 0) {
                if !inFrame {
                    header.append(bytes[index])
                    index += 1
                    do {
                        try readHeader()
                    } catch {
                        failure = error
                        throw error
                    }
                    if !inFrame { continue }
                }
                let take = Int(min(remaining, UInt64(bytes.endIndex - index)))
                if take > 0 {
                    var payload = Data(bytes[index..<(index + take)])
                    payload.withUnsafeMutableBytes { raw in
                        for offset in raw.indices { raw[offset] ^= mask[(maskOffset + offset) & 3] }
                    }
                    maskOffset = (maskOffset + take) & 3
                    index += take
                    remaining -= UInt64(take)
                    if opcode >= ServerWebSocket.opcodeClose {
                        control.append(contentsOf: payload)
                    } else {
                        received.append(.data(payload))
                    }
                }
                if remaining == 0 {
                    switch opcode {
                    case ServerWebSocket.opcodePing: received.append(.ping(Data(control)))
                    case ServerWebSocket.opcodeClose: received.append(.close)
                    default: break
                    }
                    inFrame = false
                    control = []
                }
            }
            return received
        }

        /// Parses `header` once it is whole, starting the frame it describes.
        private mutating func readHeader() throws(FrameError) {
            guard header.count >= 2 else { return }
            let first = header[0]
            let second = header[1]
            guard first & 0x70 == 0 else { throw .reservedBits }
            guard second & 0x80 != 0 else { throw .unmasked }
            let opcode = first & 0x0F
            switch opcode {
            case ServerWebSocket.opcodeContinuation, ServerWebSocket.opcodeText, ServerWebSocket.opcodeBinary,
                 ServerWebSocket.opcodeClose, ServerWebSocket.opcodePing, ServerWebSocket.opcodePong:
                break
            default:
                throw .unknownOpcode(opcode)
            }
            let shortLength = second & 0x7F
            let lengthBytes = shortLength == 127 ? 8 : shortLength == 126 ? 2 : 0
            guard header.count == 2 + lengthBytes + 4 else { return }
            var length = UInt64(shortLength)
            if lengthBytes > 0 {
                length = header[2..<(2 + lengthBytes)].reduce(0) { $0 << 8 | UInt64($1) }
                // The shortest form is required, and the top bit of a 64-bit length is zero.
                guard lengthBytes == 2 ? length >= 126 : length > 0xFFFF && length >> 63 == 0 else { throw .invalidLength }
            }
            if opcode >= ServerWebSocket.opcodeClose {
                guard first & 0x80 != 0, length <= 125 else { throw .invalidControlFrame }
            }
            self.opcode = opcode
            mask = Array(header.suffix(4))
            maskOffset = 0
            remaining = length
            inFrame = true
            header = []
        }
    }
}

/// SHA-1, which the WebSocket handshake needs and nothing else here may use: it no longer
/// resists collisions.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = UInt64(message.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8((bits >> UInt64(shift)) & 0xFF)) }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                w[i] = padded[(chunk + i * 4)..<(chunk + i * 4 + 4)].reduce(0) { $0 << 8 | UInt32($1) }
            }
            for i in 16..<80 {
                w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var (a, b, c, d, e) = h
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotateLeft(b, 30), a, temp)
            }
            h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
        }
        var digest: [UInt8] = []
        for word in [h.0, h.1, h.2, h.3, h.4] {
            for shift: UInt32 in [24, 16, 8, 0] { digest.append(UInt8(truncatingIfNeeded: word >> shift)) }
        }
        return digest
    }

    private static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        value << count | value >> (32 - count)
    }
}
