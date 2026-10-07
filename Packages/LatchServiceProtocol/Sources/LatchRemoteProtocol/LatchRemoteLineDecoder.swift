import Foundation

public enum LatchRemoteFramingError: Error, Equatable, Sendable {
    case lineTooLong(maximumBytes: Int)
    case emptyLine
}

/// Splits a byte stream into newline-terminated frames. Unlike `ACPFrameDecoder` it never
/// skips past a bad line: an oversized or empty line is fatal for the connection, and the
/// decoder keeps throwing once it has.
public struct LatchRemoteLineDecoder: Sendable {
    /// The longest line accepted, excluding its newline. A server raises it after
    /// authentication; it applies to lines not yet returned.
    public var maximumLineBytes: Int {
        didSet { precondition(maximumLineBytes > 0) }
    }

    private var buffer: [UInt8] = []
    private var lineStart = 0
    /// Where the newline search resumes, so a long line arriving in pieces is scanned once.
    private var scanned = 0
    private var failure: LatchRemoteFramingError?

    public init(maximumLineBytes: Int) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
    }

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// The next complete line without its newline, or nil until more bytes arrive.
    public mutating func nextLine() throws -> Data? {
        if let failure { throw failure }

        guard let newline = buffer[scanned...].firstIndex(of: 0x0A) else {
            scanned = buffer.count
            if buffer.count - lineStart > maximumLineBytes {
                return try fail(.lineTooLong(maximumBytes: maximumLineBytes))
            }
            compact()
            return nil
        }

        let length = newline - lineStart
        if length > maximumLineBytes {
            return try fail(.lineTooLong(maximumBytes: maximumLineBytes))
        }
        if length == 0 {
            return try fail(.emptyLine)
        }
        let line = Data(buffer[lineStart..<newline])
        lineStart = newline + 1
        scanned = lineStart
        return line
    }

    /// The bytes after the last line returned, which leave the decoder: what follows a welcome
    /// that starts compression is not lines until it is decompressed.
    public mutating func takeRemainder() -> Data {
        let remainder = Data(buffer[lineStart...])
        buffer.removeAll()
        lineStart = 0
        scanned = 0
        return remainder
    }

    /// Appends `data` and returns every line it completes.
    public mutating func lines(appending data: Data) throws -> [Data] {
        append(data)
        var lines: [Data] = []
        while let line = try nextLine() {
            lines.append(line)
        }
        return lines
    }

    private mutating func compact() {
        guard lineStart > 0 else { return }
        buffer.removeFirst(lineStart)
        scanned -= lineStart
        lineStart = 0
    }

    private mutating func fail(_ error: LatchRemoteFramingError) throws -> Data? {
        failure = error
        buffer = []
        lineStart = 0
        scanned = 0
        throw error
    }
}
