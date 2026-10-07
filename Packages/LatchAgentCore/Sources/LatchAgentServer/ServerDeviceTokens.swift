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

/// What a device's token lets it do.
public enum DeviceAccess: Sendable, Equatable {
    /// Everything the server token does.
    case full
    /// List the server's agents and follow them, and nothing that changes them: no launch,
    /// prompt, answer, setting or stop.
    case watch

    /// Where its tokens are kept. Each access has a directory of its own, so a file in the
    /// wrong one never gives a device more than the directory says.
    public var directoryName: String {
        switch self {
        case .full: ServerDeviceTokens.directoryName
        case .watch: "watch-devices"
        }
    }

    /// Where one-time pairing codes for devices of this access wait to be used.
    public var pairingCodeDirectoryName: String {
        switch self {
        case .full: "pairing-codes"
        case .watch: "watch-pairing-codes"
        }
    }
}

/// Tokens of their own for single devices: `devices/NAME` in the config directory, or
/// `watch-devices/NAME` for one that only watches, each a token in the form of
/// `server-token` and under the same checks. A device presents its token in the hello as it
/// would the server's, so its pairing string and the apps are unchanged; revoking it deletes
/// the file, which closes that device's connections and no other's.
public final class ServerDeviceTokens: Sendable {
    public static let directoryName = "devices"

    public let directory: String
    public let access: DeviceAccess
    private let owner: uid_t
    /// One file per device, kept so each keeps its cache across checks.
    private let files = Mutex<[String: ServerTokenFile]>([:])

    public init(configDirectory: String, access: DeviceAccess = .full, owner: uid_t = geteuid()) {
        directory = (configDirectory as NSString).appendingPathComponent(access.directoryName)
        self.access = access
        self.owner = owner
    }

    /// The one-time pairing codes waiting for devices of `access`, one per device name, kept
    /// and checked as tokens are: `pairing-codes/NAME` or `watch-pairing-codes/NAME`.
    public static func pairingCodes(configDirectory: String, access: DeviceAccess = .full, owner: uid_t = geteuid()) -> ServerDeviceTokens {
        ServerDeviceTokens(directory: (configDirectory as NSString).appendingPathComponent(access.pairingCodeDirectoryName),
                           access: access, owner: owner)
    }

    private init(directory: String, access: DeviceAccess, owner: uid_t) {
        self.directory = directory
        self.access = access
        self.owner = owner
    }

    /// A new token for the device in place of any it had, as a code's exchange or a new
    /// pairing code needs; `token` to make it that one.
    @discardableResult
    public func replace(_ name: String, with token: LatchRemoteToken = .generate()) throws(ServerTokenError) -> LatchRemoteToken {
        guard Self.isValidName(name) else { throw .invalidDeviceName(name) }
        try ServerConfigDirectory.prepare(directory, owner: owner)
        return try ServerTokenFile(directory: directory, name: name, owner: owner).replace(with: token)
    }

    /// When the device's file was last written: for a pairing code, when it was made.
    public func written(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: (directory as NSString).appendingPathComponent(name)))?[.modificationDate] as? Date
    }

    /// 1 to 64 letters, digits, `.`, `_` and `-`, not starting with `.`: a file name with no
    /// path in it, and never one of the temporary files, which start with `.`.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), !name.hasPrefix(".") else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    /// Every device by name, sorted, with its token or why it is refused. A device whose file
    /// is unusable is refused alone; a directory that is unusable throws, which refuses them
    /// all. No directory is no devices. Entries that are not device names are not devices.
    public func read() throws(ServerTokenError) -> [(name: String, token: Result<LatchRemoteToken, ServerTokenError>)] {
        var status = stat()
        guard lstat(directory, &status) == 0 else {
            if errno == ENOENT { return [] }
            throw .system(directory, call: "lstat", code: errno)
        }
        try ServerConfigDirectory.check(directory, owner: owner)
        let names = try names()
        let current = files.withLock { files in
            files = files.filter { names.contains($0.key) }
            return names.map { name in
                if let file = files[name] { return file }
                let file = ServerTokenFile(directory: directory, name: name, owner: owner)
                files[name] = file
                return file
            }
        }
        return zip(names, current).map { name, file in
            do throws(ServerTokenError) {
                return (name, .success(try file.read()))
            } catch {
                return (name, .failure(error))
            }
        }
    }

    /// The device's token, created with the directory on first use. Two first runs for one
    /// device agree on one token, as for the server's.
    @discardableResult
    public func readOrCreate(_ name: String) throws(ServerTokenError) -> LatchRemoteToken {
        guard Self.isValidName(name) else { throw .invalidDeviceName(name) }
        try ServerConfigDirectory.prepare(directory, owner: owner)
        return try ServerTokenFile(directory: directory, name: name, owner: owner).readOrCreate()
    }

    /// Deletes the device's token; false when it had none. Running servers close the
    /// device's connections at their next check, or at once on SIGHUP.
    public func revoke(_ name: String) throws(ServerTokenError) -> Bool {
        guard Self.isValidName(name) else { throw .invalidDeviceName(name) }
        var status = stat()
        guard lstat(directory, &status) == 0 else {
            if errno == ENOENT { return false }
            throw .system(directory, call: "lstat", code: errno)
        }
        try ServerConfigDirectory.check(directory, owner: owner)
        let path = (directory as NSString).appendingPathComponent(name)
        guard unlink(path) == 0 else {
            if errno == ENOENT { return false }
            throw .system(path, call: "unlink", code: errno)
        }
        let descriptor = open(directory, O_RDONLY | O_CLOEXEC)
        if descriptor >= 0 {
            _ = fsync(descriptor)
            close(descriptor)
        }
        return true
    }

    /// Every device of either access, sorted by name.
    public static func readAll(configDirectory: String, owner: uid_t = geteuid())
        throws(ServerTokenError) -> [(name: String, access: DeviceAccess, token: Result<LatchRemoteToken, ServerTokenError>)] {
        var all: [(name: String, access: DeviceAccess, token: Result<LatchRemoteToken, ServerTokenError>)] = []
        for access in [DeviceAccess.full, .watch] {
            all += try ServerDeviceTokens(configDirectory: configDirectory, access: access, owner: owner).read()
                .map { ($0.name, access, $0.token) }
        }
        return all.sorted { $0.name < $1.name }
    }

    /// Revokes the device of that name, of whichever access, and any pairing code waiting for
    /// it; nil when there was neither.
    public static func revoke(_ name: String, configDirectory: String, owner: uid_t = geteuid()) throws(ServerTokenError) -> DeviceAccess? {
        var revoked: DeviceAccess?
        for access in [DeviceAccess.full, .watch] {
            if try pairingCodes(configDirectory: configDirectory, access: access, owner: owner).revoke(name) { revoked = access }
            if try ServerDeviceTokens(configDirectory: configDirectory, access: access, owner: owner).revoke(name) { revoked = access }
        }
        return revoked
    }

    /// A new one-time pairing code for the device, in place of any waiting for it with either
    /// access.
    public static func makePairingCode(_ name: String, access: DeviceAccess, configDirectory: String,
                                       owner: uid_t = geteuid()) throws(ServerTokenError) -> LatchRemoteToken {
        try ServerDeviceTokens(configDirectory: configDirectory, access: access, owner: owner).checkUnique(name)
        _ = try pairingCodes(configDirectory: configDirectory, access: access == .full ? .watch : .full, owner: owner).revoke(name)
        return try pairingCodes(configDirectory: configDirectory, access: access, owner: owner).replace(name)
    }

    /// The device's token, created on first use, unless the name is a device's of the other
    /// access: one device, one token.
    public func readOrCreateUnique(_ name: String) throws(ServerTokenError) -> LatchRemoteToken {
        try checkUnique(name)
        return try readOrCreate(name)
    }

    /// Throws when the name is a device's of the other access.
    public func checkUnique(_ name: String) throws(ServerTokenError) {
        let configDirectory = (directory as NSString).deletingLastPathComponent
        let other = ServerDeviceTokens(configDirectory: configDirectory, access: access == .full ? .watch : .full, owner: owner)
        if try other.read().contains(where: { $0.name == name }) { throw .deviceExists(name, access: other.access) }
    }

    private func names() throws(ServerTokenError) -> [String] {
        guard let stream = opendir(directory) else { throw .system(directory, call: "opendir", code: errno) }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            var entryName = entry.pointee.d_name
            let name = withUnsafeBytes(of: &entryName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if Self.isValidName(name) { names.append(name) }
        }
        return names.sorted()
    }
}
