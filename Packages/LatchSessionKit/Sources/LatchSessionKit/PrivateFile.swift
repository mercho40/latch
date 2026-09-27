import Foundation

/// A file in Latch's Application Support folder that only its owner may read. Reading refuses
/// symlinks and special files; writing stages a file that is 0600 from its first byte and
/// renames it over the old one, so a failure at any point leaves the previous file intact.
/// Both stores go through here, so neither can drift into a weaker way of writing.
public enum PrivateFile {
    public enum Failure: Error, Equatable { case unreadable, tooLarge, writeFailed }

    /// The file's bytes, or nil when there is no file yet.
    public static func read(_ name: String, in directory: URL, maximumSize: Int) throws(Failure) -> Data? {
        guard directory.isFileURL else { throw .unreadable }
        let file = directory.appendingPathComponent(name)
        // Refuse symlinks and special files; O_NONBLOCK avoids hanging on a FIFO.
        let descriptor = file.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw .unreadable
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .unreadable }
        guard info.st_size >= 0, info.st_size <= maximumSize else { throw .tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Read at most one byte beyond the limit if the file grows after fstat.
            let count = min(buffer.count, maximumSize - data.count + 1)
            let received = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
            if received < 0 {
                if errno == EINTR { continue }
                throw .unreadable
            }
            if received == 0 { break }
            guard received <= maximumSize - data.count else { throw .tooLarge }
            data.append(contentsOf: buffer.prefix(received))
        }
        return data
    }

    /// Replaces the file with `data`, creating the directory (0700) when needed.
    public static func write(_ data: Data, as name: String, in directory: URL) throws(Failure) {
        guard directory.isFileURL else { throw .writeFailed }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .writeFailed
        }
        let dirFD = directory.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dirFD >= 0 else { throw .writeFailed }
        defer { Darwin.close(dirFD) }
        guard fchmod(dirFD, 0o700) == 0 else { throw .writeFailed }

        // Exclusive creation keeps the staging file private from its first byte.
        // A same-directory rename is atomic; errors before rename leave the old file intact.
        let temporaryName = ".\((name as NSString).deletingPathExtension)-\(UUID().uuidString).tmp"
        let fd = openat(dirFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw .writeFailed }
        defer {
            Darwin.close(fd)
            unlinkat(dirFD, temporaryName, 0)
        }
        guard fchmod(fd, 0o600) == 0 else { throw .writeFailed }
        let written = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, fsync(fd) == 0 else { throw .writeFailed }
        guard renameat(dirFD, temporaryName, dirFD, name) == 0 else { throw .writeFailed }
    }
}
