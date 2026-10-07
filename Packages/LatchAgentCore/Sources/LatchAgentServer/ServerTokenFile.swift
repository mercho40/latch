import Foundation
import LatchRemoteProtocol
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Why the config directory or the token file cannot be used. Never carries the token.
public enum ServerTokenError: Error, Equatable, Sendable, CustomStringConvertible {
    case missing(String)
    case notADirectory(String)
    case notARegularFile(String)
    case symbolicLink(String)
    case wrongOwner(String)
    case insecurePermissions(String)
    case malformed(String)
    case system(String, call: String, code: Int32)
    case invalidDeviceName(String)
    case deviceExists(String, access: DeviceAccess)

    public var description: String {
        switch self {
        case let .missing(path): "\(path) does not exist; " + Self.replacement(path, "run `latch-server token` to create it")
        case let .notADirectory(path): "\(path) is not a directory"
        case let .notARegularFile(path): "\(path) is not a regular file"
        case let .symbolicLink(path): "\(path) is a symbolic link; refusing to follow it"
        case let .wrongOwner(path): "\(path) is not owned by this user"
        case let .insecurePermissions(path): "\(path) is accessible to other users; run chmod go= on it"
        case let .malformed(path): "\(path) does not hold a Latch token; " + Self.replacement(path, "run `latch-server token --rotate`")
        case let .system(path, call, code): "\(path): \(call): \(String(cString: strerror(code)))"
        case let .invalidDeviceName(name): "\(name) is not a device name: use 1 to 64 letters, digits, '.', '_' and '-', not starting with '.'"
        case let .deviceExists(name, access):
            "device \(name) already has a token \(access == .watch ? "that only watches" : "with full access"); "
                + "revoke it first with `latch-server devices --revoke \(name)`"
        }
    }

    /// How to get a new token for the file at `path`: a device's is replaced by revoking it
    /// and pairing it again, the server's as `serverAdvice` says.
    private static func replacement(_ path: String, _ serverAdvice: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        guard [DeviceAccess.full, .watch].map(\.directoryName).contains((directory as NSString).lastPathComponent) else { return serverAdvice }
        let name = (path as NSString).lastPathComponent
        return "run `latch-server devices --revoke \(name)`, then pair the device again"
    }
}

/// The server's configuration directory (spec §4.5): a real directory owned by the server
/// user with no group or other permissions.
public enum ServerConfigDirectory {
    /// `--config-dir`, else `$XDG_CONFIG_HOME/latch`, else `~/.config/latch`.
    public static func resolve(explicit: String?, environment: [String: String], homeDirectory: String) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let base = environment["XDG_CONFIG_HOME"], base.hasPrefix("/") {
            return (base as NSString).appendingPathComponent("latch")
        }
        return ((homeDirectory as NSString).appendingPathComponent(".config") as NSString).appendingPathComponent("latch")
    }

    /// Creates the directory with mode 0700 if needed, then refuses it unless it is a real
    /// directory owned by `owner` with no group or other bits. Missing parents are created
    /// 0700 too; only the last component is checked.
    public static func prepare(_ path: String, owner: uid_t = geteuid()) throws(ServerTokenError) {
        try makeDirectory(path)
        try check(path, owner: owner)
    }

    /// Refuses the directory unless it is a real directory owned by `owner` with no group or
    /// other bits; creates nothing.
    public static func check(_ path: String, owner: uid_t = geteuid()) throws(ServerTokenError) {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { throw .missing(path) }
            throw .system(path, call: "lstat", code: errno)
        }
        if status.st_mode & S_IFMT == S_IFLNK { throw .symbolicLink(path) }
        guard status.st_mode & S_IFMT == S_IFDIR else { throw .notADirectory(path) }
        guard status.st_uid == owner else { throw .wrongOwner(path) }
        guard status.st_mode & 0o077 == 0 else { throw .insecurePermissions(path) }
    }

    private static func makeDirectory(_ path: String) throws(ServerTokenError) {
        if mkdir(path, 0o700) == 0 || errno == EEXIST { return }
        guard errno == ENOENT else { throw .system(path, call: "mkdir", code: errno) }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { throw .system(path, call: "mkdir", code: ENOENT) }
        try makeDirectory(parent)
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw .system(path, call: "mkdir", code: errno) }
    }
}

/// `server-token` in the config directory, or a device's token in `devices`
/// (`ServerDeviceTokens`). Every read opens the file afresh without following a symbolic link
/// and checks its owner and mode, so a missing or loosened file fails every hello that would
/// use it rather than falling back to a token read earlier. The contents are cached only
/// while the file's identity (inode, modification time, size) is unchanged.
public final class ServerTokenFile: Sendable {
    public static let fileName = "server-token"

    public let directory: String
    public let path: String
    private let name: String
    let owner: uid_t
    private let cache = Mutex<Cached?>(nil)

    private struct Cached {
        var identity: Identity
        var token: LatchRemoteToken
    }

    private struct Identity: Equatable {
        var device: UInt64
        var inode: UInt64
        var modified: Int64
        var modifiedNanoseconds: Int64
        var size: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            #if canImport(Darwin)
            modified = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            #else
            modified = Int64(status.st_mtim.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtim.tv_nsec)
            #endif
            size = Int64(status.st_size)
        }
    }

    /// `owner` is the user the file must belong to; tests pass another to see it refused.
    public init(directory: String, name: String = ServerTokenFile.fileName, owner: uid_t = geteuid()) {
        self.directory = directory
        self.name = name
        path = (directory as NSString).appendingPathComponent(name)
        self.owner = owner
    }

    /// The token as the file holds it now.
    public func read() throws(ServerTokenError) -> LatchRemoteToken {
        // Nonblocking so a FIFO put in its place cannot stall a hello; a regular file reads
        // the same either way.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw .missing(path)
            case ELOOP: throw .symbolicLink(path)
            default: throw .system(path, call: "open", code: errno)
            }
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw .system(path, call: "fstat", code: errno) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw .notARegularFile(path) }
        guard status.st_uid == owner else { throw .wrongOwner(path) }
        guard status.st_mode & 0o077 == 0 else { throw .insecurePermissions(path) }

        let identity = Identity(status)
        if let cached = cache.withLock({ $0 }), cached.identity == identity { return cached.token }
        guard status.st_size <= 256 else { throw .malformed(path) }
        var buffer = [UInt8](repeating: 0, count: 257)
        var length = 0
        while length < buffer.count {
            let count = buffer.withUnsafeMutableBytes { posixRead(descriptor, $0.baseAddress! + length, $0.count - length) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw .system(path, call: "read", code: errno) }
            if count == 0 { break }
            length += count
        }
        let text = String(decoding: buffer[..<length], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = LatchRemoteToken(text) else { throw .malformed(path) }
        cache.withLock { $0 = Cached(identity: identity, token: token) }
        return token
    }

    /// The token, or nil when the file is missing or unusable.
    public func current() -> LatchRemoteToken? {
        try? read()
    }

    /// Reads the token, creating the file first if there is none. Two first runs at once
    /// agree on one token: each writes its own temporary file and only one `link` succeeds.
    @discardableResult
    public func readOrCreate() throws(ServerTokenError) -> LatchRemoteToken {
        do {
            return try read()
        } catch .missing(_) {
            let temporary = try writeTemporary(LatchRemoteToken.generate())
            defer { unlink(temporary) }
            if link(temporary, path) != 0, errno != EEXIST {
                throw .system(path, call: "link", code: errno)
            }
            syncDirectory()
            return try read()
        }
    }

    /// Replaces the token. Running servers close connections that used the old one at their
    /// next check, or at once on SIGHUP.
    @discardableResult
    public func rotate() throws(ServerTokenError) -> LatchRemoteToken {
        let token = LatchRemoteToken.generate()
        let temporary = try writeTemporary(token)
        guard rename(temporary, path) == 0 else {
            let code = errno
            unlink(temporary)
            throw .system(path, call: "rename", code: code)
        }
        syncDirectory()
        return token
    }

    /// Writes the token to a new 0600 file beside the final one and returns its path. The mode
    /// is set by `open` itself, never by a later chmod, so there is no window where it is wider.
    private func writeTemporary(_ token: LatchRemoteToken) throws(ServerTokenError) -> String {
        let bytes = Array((token.rawValue + "\n").utf8)
        for _ in 0..<8 {
            let temporary = (directory as NSString).appendingPathComponent(".\(name).\(UInt64.random(in: .min ... .max))")
            let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw .system(temporary, call: "open", code: errno)
            }
            defer { close(descriptor) }
            var written = 0
            while written < bytes.count {
                let count = bytes.withUnsafeBytes { posixWrite(descriptor, $0.baseAddress! + written, $0.count - written) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    let code = errno
                    unlink(temporary)
                    throw .system(temporary, call: "write", code: code)
                }
                written += count
            }
            guard fsync(descriptor) == 0 else {
                let code = errno
                unlink(temporary)
                throw .system(temporary, call: "fsync", code: code)
            }
            return temporary
        }
        throw .system(directory, call: "open", code: EEXIST)
    }

    private func syncDirectory() {
        let descriptor = open(directory, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}

private func posixRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}

private func posixWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(descriptor, buffer, count)
}
