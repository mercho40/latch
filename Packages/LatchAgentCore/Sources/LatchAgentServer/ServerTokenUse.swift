import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// When and from where the server token and each device's last authenticated: `token-use` in
/// the config directory, for `latch-server devices` to show before a token is revoked or
/// rotated. latch-server is its only writer. It notes a use as a connection authenticates, at
/// most once per `minimumInterval` for one token from one address, and forgets devices whose
/// token is gone. Nothing in it is secret.
public final class ServerTokenUse: Sendable {
    public static let fileName = "token-use"

    public struct Use: Codable, Equatable, Sendable {
        public var at: Date
        /// The client's address: a proxy's client when a proxy on the server named it.
        public var from: String
    }

    public struct Record: Codable, Equatable, Sendable {
        public var server: Use?
        public var devices: [String: Use] = [:]
    }

    public let directory: String
    public let path: String
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let state: Mutex<Record>

    public init(configDirectory: String, minimumInterval: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init) {
        directory = configDirectory
        path = (configDirectory as NSString).appendingPathComponent(Self.fileName)
        self.minimumInterval = minimumInterval
        self.now = now
        state = Mutex(Self.read(path: path) ?? Record())
    }

    /// The uses the file holds, or nil when there is none or it cannot be read.
    public static func read(configDirectory: String) -> Record? {
        read(path: (configDirectory as NSString).appendingPathComponent(fileName))
    }

    private static func read(path: String) -> Record? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    /// Notes that `device`'s token, or the server's for nil, authenticated a connection from
    /// `address`, writing the file unless the same use was noted within the interval.
    func note(device: String?, from address: String) {
        let at = now()
        let record: Record? = state.withLock { record in
            let previous = device.map { record.devices[$0] } ?? record.server
            if let previous, previous.from == address, at.timeIntervalSince(previous.at) < minimumInterval { return nil }
            let use = Use(at: at, from: address)
            if let device { record.devices[device] = use } else { record.server = use }
            return record
        }
        if let record { write(record) }
    }

    /// Forgets the devices not in `devices`, those whose token was revoked.
    func forget(allBut devices: Set<String>) {
        let record: Record? = state.withLock { record in
            let kept = record.devices.filter { devices.contains($0.key) }
            guard kept.count != record.devices.count else { return nil }
            record.devices = kept
            return record
        }
        if let record { write(record) }
    }

    /// Replaces the file through a new 0600 file, so a reader never sees half of one. A
    /// failure only loses the note.
    private func write(_ record: Record) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        let temporary = (directory as NSString).appendingPathComponent(".\(Self.fileName).\(UInt64.random(in: .min ... .max))")
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        let written = data.withUnsafeBytes { posixWrite(descriptor, $0.baseAddress!, $0.count) }
        close(descriptor)
        guard written == data.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            return
        }
    }

    /// "just now", "5 minutes ago", "3 hours ago", "2 days ago".
    public static func describe(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        func ago(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return ago(seconds / 60, "minute")
        case ..<86_400: return ago(seconds / 3600, "hour")
        default: return ago(seconds / 86_400, "day")
        }
    }
}

private func posixWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(descriptor, buffer, count)
}
