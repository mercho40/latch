import CLatchZlib
import Foundation

/// What a hello offers and a welcome chooses for the bytes the server sends after the welcome.
public enum LatchRemoteCompression: String, Codable, Sendable {
    /// Raw DEFLATE (RFC 1951) as one stream for the connection's life, flushed after every
    /// write so the client can read all that was sent. Events are JSON whose keys and envelopes
    /// repeat from one to the next, which the shared window compresses many times over.
    case deflate
}

/// The server's half: compresses what it writes after the welcome. One per connection, used
/// by the one thread that writes.
public final class LatchRemoteDeflater {
    private var stream = z_stream()
    private let ready: Bool

    /// Level 3: most of what the default level saves on JSON, for much less work on a server
    /// with one core.
    public init(level: Int32 = 3) {
        ready = deflateInit2_(&stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                              Int32(MemoryLayout<z_stream>.size)) == Z_OK
    }

    deinit {
        if ready { deflateEnd(&stream) }
    }

    /// `data` compressed and flushed to a byte boundary, so it can be read in full on arrival;
    /// nil if zlib failed, after which the connection cannot go on.
    public func compress(_ data: Data) -> Data? {
        guard ready else { return nil }
        var output = Data()
        var input = data
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        let status: Int32 = input.withUnsafeMutableBytes { raw in
            stream.next_in = raw.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(raw.count)
            var result: Int32 = Z_OK
            repeat {
                result = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return deflate(&stream, Z_SYNC_FLUSH)
                }
                guard result == Z_OK || result == Z_BUF_ERROR else { break }
                output.append(buffer, count: chunk - Int(stream.avail_out))
            } while stream.avail_out == 0
            stream.next_in = nil
            return result
        }
        return status == Z_OK || status == Z_BUF_ERROR ? output : nil
    }
}

/// The client's half: decompresses what arrives after the welcome, as it arrives. One per
/// connection, used on the connection's queue.
public final class LatchRemoteInflater {
    public enum Failure: Error, Equatable {
        /// The bytes are not DEFLATE, or zlib could not start.
        case corrupt
        /// One read expanded past the limit: a frame larger than any the server sends, or bytes
        /// built to expand without end.
        case tooLarge
    }

    private var stream = z_stream()
    private let ready: Bool
    private let limit: Int

    /// `limit` bounds what one call may produce: a frame's maximum, and room for its neighbours.
    public init(limit: Int = LatchRemoteProtocol.maxFrameBytes * 4) {
        self.limit = limit
        ready = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    }

    deinit {
        if ready { inflateEnd(&stream) }
    }

    public func decompress(_ data: Data) throws(Failure) -> Data {
        guard ready else { throw .corrupt }
        var output = Data()
        var input = data
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var failure: Failure?
        input.withUnsafeMutableBytes { raw in
            stream.next_in = raw.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(raw.count)
            while stream.avail_in > 0 || stream.avail_out == 0 {
                let result: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_SYNC_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                output.append(buffer, count: produced)
                if output.count > limit { failure = .tooLarge; break }
                if result == Z_STREAM_END { failure = stream.avail_in > 0 ? .corrupt : nil; break }
                if result == Z_BUF_ERROR, produced == 0 { break }
                guard result == Z_OK || result == Z_BUF_ERROR else { failure = .corrupt; break }
            }
            stream.next_in = nil
        }
        if let failure { throw failure }
        return output
    }
}
