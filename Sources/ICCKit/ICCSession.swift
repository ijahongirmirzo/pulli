public import DeviceAPI
public import Foundation
import Synchronization

/// What `ICCSession` needs from a camera: the flat catalogue and ranged reads. ImageCaptureCore
/// provides it on a real phone (`ImageCaptureCamera`); tests use a fake.
public protocol ICCCameraBackend: AnyObject, Sendable {
    /// Every file now, with IDs that stay the same for an item for the whole session.
    func catalogue() -> [ICCCatalogueEntry]
    /// Reads up to `length` bytes at `offset`. `completion` may run on any queue, or never.
    func read(_ id: Int, offset: UInt64, length: Int, completion: @escaping @Sendable (Data?, (any Error)?) -> Void)
    /// The phone's small JPEG preview, if it has one.
    func thumbnail(_ id: Int, completion: @escaping @Sendable (Data?, (any Error)?) -> Void)
    /// `removed`: the phone left, or the session ended unasked. `catalogueChanged`: items came or went.
    func setHandlers(removed: @escaping @Sendable () -> Void, catalogueChanged: @escaping @Sendable () -> Void)
    func close() async
}

/// A catalogue item as the backend reports it, before folder synthesis.
public struct ICCCatalogueEntry: Sendable, Hashable {
    public var id: Int
    public var components: [String]
    public var size: UInt64
    public var modified: Date?

    public init(id: Int, components: [String], size: UInt64, modified: Date?) {
        self.id = id
        self.components = components
        self.size = size
        self.modified = modified
    }
}

/// A `DeviceSession` over ImageCaptureCore: one storage, "Photos and videos", whose folders are
/// synthesised from Image Capture's flat catalogue. Read-only: Image Capture is not used to write
/// to the phone in this edition.
public final class ICCSession: DeviceSession, Sendable {
    /// The one storage. Distinct from MTP's storage IDs, so a batch started over libmtp is never
    /// taken for one over Image Capture (their paths need not match).
    public static let storageID: StorageID = 0x1CC0_0001
    public static let storageName = "Photos and videos"
    /// Larger requests are cut short (short reads are allowed); spike 1 read 16 MiB at a time.
    public static let maxReadLength = 16 << 20
    static let pageSize = 256

    public let info: DeviceInfo
    public let epoch: SessionEpoch
    private let backend: any ICCCameraBackend
    private let timeZone: TimeZone
    private let callTimeout: Duration

    private struct State {
        var index = ICCFolderIndex([])
        var stale = true
        var gone = false
        /// Calls waiting for Image Capture; failed at once when the phone leaves.
        var pending: [UUID: @Sendable (DeviceError) -> Void] = [:]
        /// Handles are per session and start at a session-specific base, so a handle from an
        /// earlier session never resolves to the same file.
        var handleByItem: [Int: UInt32] = [:]
        var handleByFolder: [RemotePath: UInt32] = [:]
        var itemByHandle: [UInt32: Int] = [:]
        var nextHandle: UInt32 = 0
    }

    private let state = Mutex(State())

    /// - Parameter callTimeout: how long a read may take before it counts as a stall (`.transient`).
    public init(backend: any ICCCameraBackend, info: DeviceInfo, epoch: SessionEpoch, timeZone: TimeZone = .current,
                callTimeout: Duration = .seconds(30)) {
        self.backend = backend
        self.info = info
        self.epoch = epoch
        self.timeZone = timeZone
        self.callTimeout = callTimeout
        state.withLock { $0.nextHandle = UInt32(truncatingIfNeeded: epoch.rawValue &* 100_003) | 1 }
        backend.setHandlers(removed: { [weak self] in self?.markGone() },
                            catalogueChanged: { [weak self] in self?.state.withLock { $0.stale = true } })
    }

    // MARK: DeviceSession

    /// Empty while the catalogue is empty (the phone is in "File transfer" mode, or has no media).
    public func storages() async throws(DeviceError) -> [StorageInfo] {
        let index = try currentIndex()
        guard !index.isEmpty else { return [] }
        return [StorageInfo(id: Self.storageID, description: Self.storageName, volumeIdentifier: nil, capacityBytes: nil, freeBytes: nil)]
    }

    public func list(_ folder: RemotePath, storage: StorageID) -> AsyncThrowingStream<[RemoteEntry], any Error> {
        AsyncThrowingStream { continuation in
            do throws(DeviceError) {
                guard storage == Self.storageID else { throw .notFound(folder) }
                let index = try currentIndex()
                guard index.node(at: folder) == .folder, let children = index.folders[folder] else { throw .notFound(folder) }
                let entries = children.map { entry(for: $0, in: folder, index: index) }
                for start in stride(from: 0, to: entries.count, by: Self.pageSize) {
                    continuation.yield(Array(entries[start..<min(start + Self.pageSize, entries.count)]))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func stat(_ path: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry? {
        let index = try currentIndex()
        guard storage == Self.storageID, !path.isRoot, let node = index.node(at: path) else { return nil }
        let itemID: Int? = if case .file(let id) = node { id } else { nil }
        return entry(for: ICCFolderIndex.Entry(name: path.name, itemID: itemID), in: path.parent, index: index)
    }

    public func read(_ ref: ObjectRef, offset: UInt64, maxLength: Int) async throws(DeviceError) -> Data {
        let item = try item(for: ref)
        guard offset < item.size else { return Data() }
        let length = Int(min(UInt64(min(maxLength, Self.maxReadLength)), item.size - offset))
        guard length > 0 else { return Data() }
        let data = try await call { [backend] done in backend.read(item.id, offset: offset, length: length, completion: done) }
        guard let data, !data.isEmpty else { throw .transient("the phone returned no data at offset \(offset)") }
        return data.count > length ? data.prefix(length) : data
    }

    /// By offset too: Image Capture reads any range, so there is no separate whole-file transfer.
    public func readWhole(_ ref: ObjectRef) -> AsyncThrowingStream<Data, any Error> {
        let position = Mutex<UInt64>(0)
        return AsyncThrowingStream { [self] () async throws -> Data? in
            let offset = position.withLock { $0 }
            let data = try await read(ref, offset: offset, maxLength: 4 << 20)
            if data.isEmpty { return nil }
            position.withLock { $0 += UInt64(data.count) }
            return data
        }
    }

    /// A missing preview is nil, not an error; only losing the phone throws.
    public func thumbnail(_ ref: ObjectRef) async throws(DeviceError) -> Data? {
        let item = try item(for: ref)
        do {
            let data = try await call { [backend] done in backend.thumbnail(item.id, completion: done) }
            return data?.isEmpty == false ? data : nil
        } catch .deviceGone {
            throw .deviceGone
        } catch {
            return nil
        }
    }

    public func delete(_ ref: ObjectRef) async throws(DeviceError) {
        throw .unsupported("deleting from the phone through Image Capture")
    }

    public func makeFolder(_ name: String, in parent: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry {
        throw .unsupported("creating folders on the phone through Image Capture")
    }

    public func upload(_ file: URL, as name: String, into parent: RemotePath, storage: StorageID,
                       progress: @escaping @Sendable (UInt64) -> Void) async throws(DeviceError) -> RemoteEntry {
        throw .unsupported("copying to the phone through Image Capture")
    }

    public func rename(_ ref: ObjectRef, to name: String) async throws(DeviceError) {
        throw .unsupported("renaming on the phone through Image Capture")
    }

    public func close() async {
        let first = state.withLock { state -> Bool in
            defer { state.gone = true }
            return !state.gone
        }
        failPending()
        if first { await backend.close() }
    }

    // MARK: Internals

    private func markGone() {
        state.withLock { $0.gone = true }
        failPending()
    }

    private func failPending() {
        let waiting = state.withLock { state -> [@Sendable (DeviceError) -> Void] in
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for fail in waiting { fail(.deviceGone) }
    }

    /// The folder index, rebuilt first if Image Capture reported changes.
    private func currentIndex() throws(DeviceError) -> ICCFolderIndex {
        let (gone, stale) = state.withLock { ($0.gone, $0.stale) }
        if gone { throw .deviceGone }
        if !stale { return state.withLock { $0.index } }
        let items = backend.catalogue().map {
            ICCCatalogueItem(id: $0.id, components: $0.components, size: $0.size,
                             modifiedWallClock: ICCCatalogueItem.wallClock($0.modified, timeZone: timeZone))
        }
        let index = ICCFolderIndex(items)
        return try state.withLock { state throws(DeviceError) -> ICCFolderIndex in
            if state.gone { throw .deviceGone }
            state.index = index
            state.stale = false
            return index
        }
    }

    private func entry(for child: ICCFolderIndex.Entry, in folder: RemotePath, index: ICCFolderIndex) -> RemoteEntry {
        let path = folder.appending(child.name)
        let handle = state.withLock { state -> UInt32 in
            if let id = child.itemID {
                if let handle = state.handleByItem[id] { return handle }
                let handle = state.nextHandle
                state.nextHandle &+= 1
                state.handleByItem[id] = handle
                state.itemByHandle[handle] = id
                return handle
            }
            if let handle = state.handleByFolder[path] { return handle }
            let handle = state.nextHandle
            state.nextHandle &+= 1
            state.handleByFolder[path] = handle
            return handle
        }
        let ref = ObjectRef(handle: handle, storage: Self.storageID, epoch: epoch)
        guard let id = child.itemID, let item = index.items[id] else {
            return RemoteEntry(name: child.name, isFolder: true, size: 0, modifiedWallClock: 0, ref: ref)
        }
        return RemoteEntry(name: child.name, isFolder: false, size: item.size, modifiedWallClock: item.modifiedWallClock, ref: ref)
    }

    private func item(for ref: ObjectRef) throws(DeviceError) -> ICCCatalogueItem {
        guard ref.epoch == epoch else { throw .staleHandle }
        let index = try currentIndex()
        guard let id = state.withLock({ $0.itemByHandle[ref.handle] }) else { throw .rejected("invalid object handle") }
        guard let item = index.items[id] else { throw .rejected("object no longer exists") }
        return item
    }

    /// Runs one Image Capture call, resolved exactly once by its completion, the timeout, or the
    /// phone leaving (Image Capture may never call back after a cable pull).
    /// Cancelling the task (a paused copy) resolves it at once as `.transient("cancelled")`.
    private func call(_ start: (@escaping @Sendable (Data?, (any Error)?) -> Void) -> Void) async throws(DeviceError) -> Data? {
        let id = UUID()
        let once = OnceResult<Data?>()
        let registered = state.withLock { state -> Bool in
            guard !state.gone else { return false }
            state.pending[id] = { error in once.resolve(.failure(error)) }
            return true
        }
        guard registered else { throw .deviceGone }
        defer { _ = state.withLock { $0.pending.removeValue(forKey: id) } }

        let timeout = callTimeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
            once.resolve(.failure(.transient("the phone did not answer within \(timeout.formatted(.units(allowed: [.seconds])))")))
        }
        start { [weak self] data, error in
            let removed = self?.state.withLock { $0.gone } ?? true
            if let error {
                once.resolve(.failure(ICCErrorMapping.deviceError(error, deviceRemoved: removed)))
            } else {
                once.resolve(.success(data))
            }
        }
        let result = await withTaskCancellationHandler {
            await once.value()
        } onCancel: {
            once.resolve(.failure(.transient("cancelled")))
        }
        return try result.get()
    }
}

/// A result set once by whichever of completion, timeout, removal or cancellation is first, and
/// awaited by the caller (it may be set before anyone waits).
private final class OnceResult<T: Sendable>: Sendable {
    private struct State {
        var result: Result<T, DeviceError>?
        var waiter: CheckedContinuation<Result<T, DeviceError>, Never>?
    }

    private let state = Mutex(State())

    func resolve(_ result: Result<T, DeviceError>) {
        let waiter = state.withLock { state -> CheckedContinuation<Result<T, DeviceError>, Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: result)
    }

    func value() async -> Result<T, DeviceError> {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Result<T, DeviceError>? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
