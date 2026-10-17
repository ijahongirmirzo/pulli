public import Foundation

/// How strongly a sync reached the disk.
public enum SyncLevel: String, Sendable, Codable {
    /// `F_FULLFSYNC`: flushed through the drive's cache. Survives power loss.
    case full
    /// `F_BARRIERFSYNC`: everything before it reaches the disk before anything after it.
    case barrier
    /// Plain `fsync`, used when the volume supports neither of the above (exFAT, SMB).
    case fsync
}

/// What a sync must guarantee.
public enum SyncRequest: Sendable {
    /// The data survives power loss once the call returns.
    case durable
    /// The data reaches the disk before any later write to the same volume. Enough when the
    /// journal lives on the same volume and is written afterwards (docs/DECISIONS.md, D-006).
    case ordered
}

/// Destination-side failures. All of them pause the transfer rather than fail files (brief:
/// "Destination disk full or removed: pause with a clear message, resume when fixed").
public enum DestinationError: Error, Sendable, Equatable, CustomStringConvertible {
    case noSpace
    case readOnly
    case permissionDenied(String)
    case volumeUnavailable(String)
    case alreadyExists(String)
    case io(code: Int32, context: String)

    public init(errno code: Int32, context: String) {
        switch code {
        case ENOSPC, EDQUOT: self = .noSpace
        case EROFS: self = .readOnly
        case EACCES, EPERM: self = .permissionDenied(context)
        case ENXIO, ENODEV, ENOENT, ENOTDIR, ESTALE: self = .volumeUnavailable(context)
        case EEXIST: self = .alreadyExists(context)
        default: self = .io(code: code, context: context)
        }
    }

    public var description: String {
        switch self {
        case .noSpace: "destination disk is full"
        case .readOnly: "destination is read-only"
        case .permissionDenied(let context): "permission denied: \(context)"
        case .volumeUnavailable(let context): "destination is unavailable: \(context)"
        case .alreadyExists(let context): "already exists: \(context)"
        case .io(let code, let context): "\(context): \(String(cString: strerror(code)))"
        }
    }
}

/// An open `.part` file. Abstracted so tests can simulate crashes and full disks.
public protocol PartFile: AnyObject {
    func size() throws(DestinationError) -> UInt64
    func write(_ data: Data, at offset: UInt64) throws(DestinationError)
    func read(at offset: UInt64, count: Int) throws(DestinationError) -> Data
    func truncate(to length: UInt64) throws(DestinationError)
    /// Makes every write so far durable (or ordered). Returns the level actually achieved.
    func sync(_ request: SyncRequest) throws(DestinationError) -> SyncLevel
    func setModificationDate(_ date: Date) throws(DestinationError)
    /// Marks the file as written by this job, so a crash between rename and journal update is
    /// recognised as our own finished file rather than a pre-existing duplicate.
    func setJobTag(_ tag: String) throws(DestinationError)
    func close()
}

/// File-system operations the transfer engine needs at the destination.
public protocol FileSink: Sendable {
    func openPart(at url: URL) throws(DestinationError) -> any PartFile
    /// Size and modification date of an existing regular file, or nil if there is none.
    func attributes(of url: URL) -> (size: UInt64, modified: Date)?
    /// The job tag written by `PartFile.setJobTag`, if any.
    func jobTag(of url: URL) -> String?
    /// Renames, failing with `.alreadyExists` rather than replacing an existing file.
    func renameExclusive(_ source: URL, to destination: URL) throws(DestinationError)
    /// Renames over an existing file atomically (the "overwrite" duplicate policy).
    func renameReplacing(_ source: URL, to destination: URL) throws(DestinationError)
    /// Makes completed renames in this folder durable (or ordered).
    func syncDirectory(_ url: URL, _ request: SyncRequest) throws(DestinationError)
    /// Creates missing folders along `url`, durably (each new folder synced into its parent).
    func createDirectory(_ url: URL) throws(DestinationError)
    func remove(_ url: URL)
    /// Free bytes on the volume holding `url`, or nil if it is not reachable (e.g. unplugged).
    func availableCapacity(at url: URL) -> UInt64?
    /// Identifies the volume holding `url` (for deciding if the journal shares it).
    func volumeID(of url: URL) -> UInt64?
}
