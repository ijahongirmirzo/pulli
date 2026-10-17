public import Foundation
import Darwin

/// The real destination: POSIX calls with explicit durability.
public struct POSIXFileSink: FileSink {
    // Stored on unfinished files already on users' disks: keeps its original (Relay-era)
    // spelling so those files are still recognised and resumed.
    static let jobTagAttribute = "com.relay.job"

    public init() {}

    public func openPart(at url: URL) throws(DestinationError) -> any PartFile {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw DestinationError(errno: errno, context: "open \(url.path)") }
        return POSIXPartFile(fd: fd, path: url.path)
    }

    public func attributes(of url: URL) -> (size: UInt64, modified: Date)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return (UInt64(info.st_size), modified)
    }

    public func jobTag(of url: URL) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = getxattr(url.path, Self.jobTagAttribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    public func renameExclusive(_ source: URL, to destination: URL) throws(DestinationError) {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw DestinationError(errno: errno, context: "rename to \(destination.path)")
        }
    }

    public func renameReplacing(_ source: URL, to destination: URL) throws(DestinationError) {
        guard rename(source.path, destination.path) == 0 else {
            throw DestinationError(errno: errno, context: "replace \(destination.path)")
        }
    }

    public func syncDirectory(_ url: URL, _ request: SyncRequest) throws(DestinationError) {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw DestinationError(errno: errno, context: "open directory \(url.path)") }
        defer { Darwin.close(fd) }
        guard POSIXPartFile.sync(fd, request) != nil else {
            throw DestinationError(errno: errno, context: "sync directory \(url.path)")
        }
    }

    /// Durable `mkdir -p`: each folder it creates is made durable in its parent (otherwise a power
    /// loss could lose the folder, and every finished file in it, after the journal said "done").
    /// Fails with the real errno, so a removed volume reads as unavailable.
    public func createDirectory(_ url: URL) throws(DestinationError) {
        var path = ""
        for component in url.standardizedFileURL.pathComponents {
            let parent = path
            path = component == "/" ? "/" : (path as NSString).appendingPathComponent(component)
            if mkdir(path, 0o755) == 0 {
                try syncDirectory(URL(fileURLWithPath: parent), .durable)
            } else if errno != EEXIST {
                throw DestinationError(errno: errno, context: "create \(path)")
            }
        }
    }

    public func remove(_ url: URL) {
        unlink(url.path)
    }

    public func availableCapacity(at url: URL) -> UInt64? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return UInt64(info.f_bavail) * UInt64(info.f_bsize)
    }

    public func volumeID(of url: URL) -> UInt64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return UInt64(bitPattern: Int64(info.st_dev))
    }
}

final class POSIXPartFile: PartFile {
    private var fd: Int32
    private let path: String

    init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit { close() }

    func size() throws(DestinationError) -> UInt64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DestinationError(errno: errno, context: "stat \(path)") }
        return UInt64(info.st_size)
    }

    func write(_ data: Data, at offset: UInt64) throws(DestinationError) {
        var failure: DestinationError?
        data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = pwrite(fd, buffer.baseAddress! + written, buffer.count - written, off_t(offset) + off_t(written))
                if result < 0 {
                    if errno == EINTR { continue }
                    failure = DestinationError(errno: errno, context: "write \(path)")
                    return
                }
                written += result
            }
        }
        if let failure { throw failure }
    }

    func read(at offset: UInt64, count: Int) throws(DestinationError) -> Data {
        var data = Data(count: count)
        var failure: DestinationError?
        let total = data.withUnsafeMutableBytes { buffer -> Int in
            var done = 0
            while done < count {
                let result = pread(fd, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if result < 0 {
                    if errno == EINTR { continue }
                    failure = DestinationError(errno: errno, context: "read \(path)")
                    return done
                }
                if result == 0 { break }
                done += result
            }
            return done
        }
        if let failure { throw failure }
        data.count = total
        return data
    }

    func truncate(to length: UInt64) throws(DestinationError) {
        guard ftruncate(fd, off_t(length)) == 0 else { throw DestinationError(errno: errno, context: "truncate \(path)") }
    }

    func sync(_ request: SyncRequest) throws(DestinationError) -> SyncLevel {
        guard let level = Self.sync(fd, request) else { throw DestinationError(errno: errno, context: "sync \(path)") }
        return level
    }

    /// Strongest sync the volume supports for the request; nil (with errno set) on failure.
    /// Some file systems (exFAT, SMB) reject F_FULLFSYNC and F_BARRIERFSYNC; fsync is their best.
    static func sync(_ fd: Int32, _ request: SyncRequest) -> SyncLevel? {
        switch request {
        case .durable:
            if fcntl(fd, F_FULLFSYNC) == 0 { return .full }
        case .ordered:
            if fcntl(fd, F_BARRIERFSYNC) == 0 { return .barrier }
            if fcntl(fd, F_FULLFSYNC) == 0 { return .full }
        }
        return Darwin.fsync(fd) == 0 ? .fsync : nil
    }

    func setModificationDate(_ date: Date) throws(DestinationError) {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1e9)),
        ]
        guard futimens(fd, times) == 0 else { throw DestinationError(errno: errno, context: "set date on \(path)") }
    }

    func setJobTag(_ tag: String) throws(DestinationError) {
        let bytes = Array(tag.utf8)
        guard fsetxattr(fd, POSIXFileSink.jobTagAttribute, bytes, bytes.count, 0, 0) == 0 else {
            // Extended attributes are optional on some file systems (FAT, some SMB shares).
            if errno == ENOTSUP { return }
            throw DestinationError(errno: errno, context: "tag \(path)")
        }
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}
