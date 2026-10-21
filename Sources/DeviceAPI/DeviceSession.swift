public import Foundation

/// An open connection to one phone. The seam between TransferCore and real or simulated devices:
/// MTPKit, MockDevice and (from Phase 3) the worker-process proxy implement it.
public protocol DeviceSession: AnyObject, Sendable {
    var info: DeviceInfo { get }
    var epoch: SessionEpoch { get }

    /// Current storages. Empty means the phone is locked or has not authorised the Mac yet.
    func storages() async throws(DeviceError) -> [StorageInfo]

    /// Lists one folder, in pages, without enumerating anything below it.
    /// Cancelling the consuming task stops the listing between pages.
    func list(_ folder: RemotePath, storage: StorageID) -> AsyncThrowingStream<[RemoteEntry], any Error>

    /// Finds an object by path. Returns nil if any component is missing.
    func stat(_ path: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry?

    /// Reads up to `maxLength` bytes at `offset`. Short reads are normal; advance by `data.count`.
    /// Returns empty data at or past the end of the object.
    func read(_ ref: ObjectRef, offset: UInt64, maxLength: Int) async throws(DeviceError) -> Data

    /// Streams a whole object from its first byte, for devices (or file sizes) where `read` by
    /// offset is not available (see `ReadStrategy`). Not resumable: an interruption means starting
    /// over. Stopping iteration cancels the transfer. Errors are `DeviceError`s.
    func readWhole(_ ref: ObjectRef) -> AsyncThrowingStream<Data, any Error>

    /// The small preview the phone keeps for an object (MTP GetThumb): a JPEG of a few kilobytes,
    /// far cheaper than reading the file. Nil when the phone has none (most non-images; videos on
    /// many phones).
    func thumbnail(_ ref: ObjectRef) async throws(DeviceError) -> Data?

    /// Deletes a file from the phone. Only "Free up space" calls this, and only for files whose
    /// copy on the Mac was just verified byte for byte.
    func delete(_ ref: ObjectRef) async throws(DeviceError)

    /// Creates a folder (or returns the existing one of that name) inside `parent`.
    func makeFolder(_ name: String, in parent: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry

    /// Sends a file from the Mac to the phone. MTP cannot append, so an interrupted upload starts
    /// again from the beginning. `progress` is told the bytes sent so far.
    func upload(_ file: URL, as name: String, into parent: RemotePath, storage: StorageID,
                progress: @escaping @Sendable (UInt64) -> Void) async throws(DeviceError) -> RemoteEntry

    /// Renames a file or folder in place (Finder, through the phone drive).
    func rename(_ ref: ObjectRef, to name: String) async throws(DeviceError)

    /// Notified when the device reports its contents changed (e.g. photos added).
    var onContentChanged: (@Sendable () -> Void)? { get set }

    /// Ends the session. After this, every call throws `.deviceGone`.
    func close() async
}

extension DeviceSession {
    public var onContentChanged: (@Sendable () -> Void)? {
        get { nil }
        set {}
    }
}
