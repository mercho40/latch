import Foundation
import LatchRemoteProtocol
import LatchServiceProtocol
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One line per event, in order, on a queue of its own so no caller blocks on stderr (spec
/// §4.7). journald adds timestamps. Never pass it the token or a hello frame.
public final class ServerLog: Sendable {
    private let queue = DispatchQueue(label: "dev.latchapp.server.log")
    private let sink: @Sendable (String) -> Void

    /// `sink` receives each line without its newline; by default it goes to stderr.
    public init(sink: @escaping @Sendable (String) -> Void = ServerLog.writeToStandardError) {
        self.sink = sink
    }

    public func log(_ message: String) {
        let sink = sink
        queue.async { sink(message) }
    }

    /// Returns once every line logged so far has been written.
    public func flush() {
        queue.sync {}
    }

    public static let writeToStandardError: @Sendable (String) -> Void = { message in
        let bytes = Array((message + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress! + written, $0.count - written) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            written += count
        }
    }

    /// Escapes control, line-separator and bidirectional-override characters, and backslash,
    /// so a logged line cannot forge another line or reorder what a terminal shows.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x5C:
                result += "\\\\"
            case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200E, 0x200F, 0x2028...0x202E, 0x2066...0x2069:
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// At most `limit` events per `window`; reports how many it suppressed once it lets one through.
struct LogRateLimiter: Sendable {
    let limit: Int
    let window: Duration
    private var windowStart: ContinuousClock.Instant?
    private var count = 0
    private var suppressed = 0

    init(limit: Int, window: Duration) {
        self.limit = limit
        self.window = window
    }

    /// Nil when this event must be dropped; otherwise how many were dropped before it.
    mutating func admit(now: ContinuousClock.Instant) -> Int? {
        if let start = windowStart, start.duration(to: now) < window {
            guard count < limit else {
                suppressed += 1
                return nil
            }
        } else {
            windowStart = now
            count = 0
        }
        count += 1
        defer { suppressed = 0 }
        return suppressed
    }
}

/// Agent stderr for `--log-agent-stderr`: split into lines, escaped, cut to a length and
/// rate-limited per runtime, and prefixed with the runtime ID, which the hub has validated.
public final class AgentStandardErrorLog: Sendable {
    private let log: ServerLog
    private let maxLineLength: Int
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let limit: Int
    private let window: Duration
    private let runtimes = Mutex<[AgentRuntimeID: Runtime]>([:])

    private struct Runtime {
        var partial: [UInt8] = []
        /// A line that grew past the cap has been logged; skip to its end.
        var skippingToNewline = false
        var limiter: LogRateLimiter
    }

    public init(
        log: ServerLog,
        maxLineLength: Int = 1000,
        linesPerWindow: Int = 100,
        window: Duration = .seconds(10),
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.log = log
        self.maxLineLength = maxLineLength
        self.limit = linesPerWindow
        self.window = window
        self.clock = clock
    }

    public func receive(_ runtimeID: AgentRuntimeID, _ data: Data) {
        let now = clock()
        let prefix = LatchRemoteProtocol.isValidRuntimeID(runtimeID.rawValue) ? runtimeID.rawValue : "?"
        let lines: [String] = runtimes.withLock { runtimes in
            var runtime = runtimes[runtimeID] ?? Runtime(limiter: LogRateLimiter(limit: limit, window: window))
            var complete: [[UInt8]] = []
            for byte in data {
                if byte == 0x0A {
                    if !runtime.skippingToNewline { complete.append(runtime.partial) }
                    runtime.partial.removeAll(keepingCapacity: true)
                    runtime.skippingToNewline = false
                } else if !runtime.skippingToNewline {
                    runtime.partial.append(byte)
                    // Four bytes per character at most, so this holds a full-length line.
                    if runtime.partial.count > maxLineLength * 4 {
                        complete.append(runtime.partial)
                        runtime.partial.removeAll(keepingCapacity: true)
                        runtime.skippingToNewline = true
                    }
                }
            }
            var admitted: [String] = []
            for line in complete {
                guard let suppressed = runtime.limiter.admit(now: now) else { continue }
                if suppressed > 0 { admitted.append("agent \(prefix): (\(suppressed) lines of stderr not logged)") }
                admitted.append("agent \(prefix): " + format(line))
            }
            runtimes[runtimeID] = runtime
            return admitted
        }
        for line in lines { log.log(line) }
    }

    /// Drops what is buffered for a runtime that has ended.
    public func forget(_ runtimeID: AgentRuntimeID) {
        _ = runtimes.withLock { $0.removeValue(forKey: runtimeID) }
    }

    private func format(_ bytes: [UInt8]) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        if text.count > maxLineLength { text = String(text.prefix(maxLineLength)) + "…" }
        return ServerLog.escape(text)
    }
}
