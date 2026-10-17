internal import CLibMTP
public import DeviceAPI
public import Foundation
import IOKit
import USBKit

/// An open MTP session with one phone, backed by libmtp.
///
/// Every libmtp call happens on `MTPActor`'s dedicated thread. Folder listings are paged
/// (`LIBMTP_Get_Children` then per-object metadata) so a 50,000-file DCIM folder streams into the
/// caller and can be cancelled between pages, instead of blocking in one libmtp call.
@MTPActor
public final class MTPSession: DeviceSession {
    public nonisolated let info: DeviceInfo
    public nonisolated let epoch: SessionEpoch

    /// Children per listed folder, so path lookups do not re-list. Valid for this session only.
    private var folderCache: [FolderKey: [ExactName: RemoteEntry]] = [:]
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private let registryID: UInt64

    private struct FolderKey: Hashable {
        var storage: StorageID
        var path: RemotePath
    }

    static let listPageSize = 256
    private static var nextEpoch: UInt64 = 1

    init(device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, usb: USBDeviceRecord) {
        self.device = device
        self.registryID = usb.registryID
        self.epoch = SessionEpoch(rawValue: Self.nextEpoch)
        Self.nextEpoch += 1

        let mtpSerial = Self.takeString(LIBMTP_Get_Serialnumber(device))
        let key: DeviceKey = if DeviceKey.isUsableSerial(usb.summary.usbSerial) {
            DeviceKey(kind: .usb, vendorID: usb.summary.vendorID, serial: usb.summary.usbSerial!)
        } else {
            DeviceKey(kind: .mtp, vendorID: usb.summary.vendorID, serial: mtpSerial ?? "unknown")
        }

        info = DeviceInfo(
            key: key,
            usb: usb.summary,
            manufacturer: Self.takeString(LIBMTP_Get_Manufacturername(device)),
            model: Self.takeString(LIBMTP_Get_Modelname(device)),
            friendlyName: Self.takeString(LIBMTP_Get_Friendlyname(device)),
            mtpSerial: mtpSerial,
            readStrategy: Self.readStrategy(of: device)
        )
        LIBMTP_Clear_Errorstack(device)
    }

    // MARK: DeviceSession

    public func storages() throws(DeviceError) -> [StorageInfo] {
        let device = try openDevice()
        if LIBMTP_Get_Storage(device, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED)) != 0 {
            // -1 with the device still attached means zero storages: locked or not yet authorised.
            let error = failure("list storages")
            if error == .deviceGone { throw error }
            return []
        }
        var result: [StorageInfo] = []
        var node = device.pointee.storage
        while let storage = node {
            result.append(StorageInfo(
                id: storage.pointee.id,
                description: Self.string(storage.pointee.StorageDescription) ?? "Storage",
                volumeIdentifier: Self.string(storage.pointee.VolumeIdentifier),
                capacityBytes: Self.known(storage.pointee.MaxCapacity),
                freeBytes: Self.known(storage.pointee.FreeSpaceInBytes)
            ))
            node = storage.pointee.next
        }
        return result
    }

    public nonisolated func list(_ folder: RemotePath, storage: StorageID) -> AsyncThrowingStream<[RemoteEntry], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MTPActor in
                do {
                    // Browsing always reads the phone afresh (new photos appear); lookups for
                    // transfers use the cache.
                    try await self.streamFolder(folder, storage: storage, fresh: true) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stat(_ path: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry? {
        guard !path.isRoot else { return nil }
        let children = try await children(of: path.parent, storage: storage)
        return children?[ExactName(path.name)]
    }

    public func read(_ ref: ObjectRef, offset: UInt64, maxLength: Int) throws(DeviceError) -> Data {
        guard ref.epoch == epoch else { throw .staleHandle }
        let device = try openDevice()
        if offset > UInt64(UInt32.max), info.readStrategy != .partial64 {
            throw .unsupported("offsets above 4 GiB need GetPartialObject64")
        }

        var buffer: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        let length = UInt32(clamping: maxLength)
        let status = LIBMTP_GetPartialObject(device, ref.handle, offset, length, &buffer, &size)
        guard status == 0 else {
            free(buffer)
            throw failure("read \(length) bytes at \(offset) of object \(ref.handle)")
        }
        guard let buffer, size > 0 else {
            free(buffer)
            return Data()
        }
        // Hand libmtp's malloc'd buffer to Data without copying; Data frees it.
        return Data(bytesNoCopy: buffer, count: Int(size), deallocator: .free)
    }

    public func thumbnail(_ ref: ObjectRef) throws(DeviceError) -> Data? {
        guard ref.epoch == epoch else { throw .staleHandle }
        let device = try openDevice()
        var buffer: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        // A failure here only means "no thumbnail" (the phone has none for this object); it is
        // not an error on the session. Drain libmtp's error stack so it does not leak into the
        // next real failure's message.
        guard LIBMTP_Get_Thumbnail(device, ref.handle, &buffer, &size) == 0, let buffer, size > 0 else {
            free(buffer)
            LIBMTP_Clear_Errorstack(device)
            return nil
        }
        return Data(bytesNoCopy: buffer, count: Int(size), deallocator: .free)
    }

    public func delete(_ ref: ObjectRef) throws(DeviceError) {
        guard ref.epoch == epoch else { throw .staleHandle }
        let device = try openDevice()
        guard LIBMTP_Delete_Object(device, ref.handle) == 0 else { throw failure("delete object \(ref.handle)") }
        // The object's folder is not known here; forget every listing rather than serve a stale one.
        folderCache.removeAll()
    }

    public func rename(_ ref: ObjectRef, to name: String) throws(DeviceError) {
        guard ref.epoch == epoch else { throw .staleHandle }
        let device = try openDevice()
        guard LIBMTP_Set_Object_String(device, ref.handle, LIBMTP_PROPERTY_ObjectFileName, name) == 0 else {
            throw failure("rename object \(ref.handle)")
        }
        folderCache.removeAll()
    }

    public func makeFolder(_ name: String, in parent: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry {
        if let existing = try await stat(parent.appending(name), storage: storage) {
            guard existing.isFolder else { throw .rejected("a file named \(name) is in the way") }
            return existing
        }
        let parentHandle: UInt32 = parent.isRoot ? 0 : try await folderHandle(parent, storage: storage)
        let device = try openDevice()
        // libmtp may rewrite the name it is given (invalid characters), so it gets its own copy.
        let buffer = strdup(name)
        defer { free(buffer) }
        let handle = LIBMTP_Create_Folder(device, buffer, parentHandle, storage)
        guard handle != 0 else { throw failure("create folder \(name)") }
        folderCache[FolderKey(storage: storage, path: parent)] = nil
        return RemoteEntry(name: name, isFolder: true, size: 0, modifiedWallClock: Int64(Date().timeIntervalSince1970),
                           ref: ObjectRef(handle: handle, storage: storage, epoch: epoch))
    }

    public func upload(_ file: URL, as name: String, into parent: RemotePath, storage: StorageID,
                       progress: @escaping @Sendable (UInt64) -> Void) async throws(DeviceError) -> RemoteEntry {
        let parentHandle: UInt32 = parent.isRoot ? 0 : try await folderHandle(parent, storage: storage)
        let device = try openDevice()
        let descriptor = Darwin.open(file.path, O_RDONLY)
        guard descriptor >= 0 else { throw .rejected("cannot read \(file.path)") }
        defer { Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw .rejected("cannot read \(file.path)") }
        guard let metadata = LIBMTP_new_file_t() else { throw .transient("out of memory") }
        defer { LIBMTP_destroy_file_t(metadata) }
        metadata.pointee.filename = strdup(name)
        metadata.pointee.filesize = UInt64(info.st_size)
        metadata.pointee.filetype = Self.fileType(forName: name)
        metadata.pointee.parent_id = parentHandle
        metadata.pointee.storage_id = storage
        let reporter = Unmanaged.passRetained(ProgressReporter(progress))
        defer { reporter.release() }
        let status = LIBMTP_Send_File_From_File_Descriptor(device, descriptor, metadata, { sent, _, context in
            if let context { Unmanaged<ProgressReporter>.fromOpaque(context).takeUnretainedValue().report(sent) }
            return 0
        }, reporter.toOpaque())
        guard status == 0 else { throw failure("send \(name)") }
        folderCache[FolderKey(storage: storage, path: parent)] = nil
        return RemoteEntry(name: name, isFolder: false, size: UInt64(info.st_size), modifiedWallClock: Int64(info.st_mtimespec.tv_sec),
                           ref: ObjectRef(handle: metadata.pointee.item_id, storage: storage, epoch: epoch))
    }

    /// The MTP object format for a file sent to the phone: Android files media by it, so photos
    /// and videos sent as "unknown" would not show in the gallery.
    static func fileType(forName name: String) -> LIBMTP_filetype_t {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": LIBMTP_FILETYPE_JPEG
        case "png": LIBMTP_FILETYPE_PNG
        case "gif": LIBMTP_FILETYPE_GIF
        case "mp4", "m4v": LIBMTP_FILETYPE_MP4
        case "mov": LIBMTP_FILETYPE_QT
        case "avi": LIBMTP_FILETYPE_AVI
        case "mpg", "mpeg": LIBMTP_FILETYPE_MPEG
        case "mp3": LIBMTP_FILETYPE_MP3
        case "wav": LIBMTP_FILETYPE_WAV
        case "aac", "m4a": LIBMTP_FILETYPE_AAC
        case "txt": LIBMTP_FILETYPE_TEXT
        default: LIBMTP_FILETYPE_UNKNOWN
        }
    }

    public nonisolated func readWhole(_ ref: ObjectRef) -> AsyncThrowingStream<Data, any Error> {
        let pipe = WholeObjectPipe()
        Task { @MTPActor in self.pumpWholeObject(ref, into: pipe) }
        return pipe.stream()
    }

    /// Runs `LIBMTP_Get_File_To_Handler` on the MTP thread, feeding the pipe from its callback.
    private func pumpWholeObject(_ ref: ObjectRef, into pipe: WholeObjectPipe) {
        guard ref.epoch == epoch else { return pipe.finish(throwing: DeviceError.staleHandle) }
        guard let device else { return pipe.finish(throwing: DeviceError.deviceGone) }
        let context = Unmanaged.passRetained(pipe)
        defer { context.release() }
        let status = LIBMTP_Get_File_To_Handler(device, ref.handle, wholeObjectPut, context.toOpaque(), nil, nil)
        if status == 0 {
            pipe.finish()
        } else if pipe.isCancelled {
            LIBMTP_Clear_Errorstack(device)
            pipe.finish(throwing: CancellationError())
        } else {
            pipe.finish(throwing: failure("read whole object \(ref.handle)"))
        }
    }

    public func close() {
        folderCache.removeAll()
        guard let device else { return }
        self.device = nil
        LIBMTP_Release_Device(device)
        SessionMarker.markClosed(info.usb.usbSerial)
    }

    /// Drops the session without talking to the phone. Used when the device is already gone, and
    /// by the worker process on stall recovery (D-001): releasing an Android device triggers a USB
    /// reset, which can wedge MTP until the cable is replugged.
    public func abandon() {
        folderCache.removeAll()
        device = nil
    }

    /// libmtp's own dump of DeviceInfo, supported operations and storages (to stdout).
    public func dumpDeviceInfo() {
        guard let device else { return }
        LIBMTP_Dump_Device_Info(device)
    }

    // MARK: Listing

    private func streamFolder(
        _ folder: RemotePath, storage: StorageID, fresh: Bool = false, yield: ([RemoteEntry]) -> Void
    ) async throws(DeviceError) {
        let key = FolderKey(storage: storage, path: folder)
        if !fresh, let cached = folderCache[key] {
            yield(cached.values.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) })
            return
        }
        let parent = try await folderHandle(folder, storage: storage)
        let device = try openDevice()

        var ids: UnsafeMutablePointer<UInt32>?
        let count = LIBMTP_Get_Children(device, storage, parent, &ids)
        defer { free(ids) }
        guard count >= 0 else { throw failure("list \(folder)") }

        var byName: [ExactName: RemoteEntry] = [:]
        byName.reserveCapacity(Int(count))
        var start = 0
        while start < Int(count) {
            if Task.isCancelled { return }
            let end = min(start + Self.listPageSize, Int(count))
            var page: [RemoteEntry] = []
            page.reserveCapacity(end - start)
            for index in start..<end {
                guard let file = LIBMTP_Get_Filemetadata(device, ids![index]) else { continue }
                defer { LIBMTP_destroy_file_t(file) }
                guard let entry = entry(from: file.pointee, storage: storage) else { continue }
                page.append(entry)
                byName[ExactName(entry.name)] = entry
            }
            LIBMTP_Clear_Errorstack(device)
            yield(page)
            start = end
            // Let other work (a transfer's next chunk, a cancellation) run between pages.
            await Task.yield()
        }
        folderCache[key] = byName
    }

    private func children(of folder: RemotePath, storage: StorageID) async throws(DeviceError) -> [ExactName: RemoteEntry]? {
        let key = FolderKey(storage: storage, path: folder)
        if let cached = folderCache[key] { return cached }
        do {
            try await streamFolder(folder, storage: storage) { _ in }
        } catch DeviceError.notFound {
            return nil
        }
        return folderCache[key]
    }

    private func folderHandle(_ folder: RemotePath, storage: StorageID) async throws(DeviceError) -> UInt32 {
        if folder.isRoot { return UInt32(LIBMTP_FILES_AND_FOLDERS_ROOT) }
        guard let parent = try await children(of: folder.parent, storage: storage),
              let entry = parent[ExactName(folder.name)], entry.isFolder else {
            throw .notFound(folder)
        }
        return entry.ref.handle
    }

    private func entry(from file: LIBMTP_file_t, storage: StorageID) -> RemoteEntry? {
        guard let name = Self.string(file.filename), !name.isEmpty else { return nil }
        return RemoteEntry(
            name: name,
            isFolder: file.filetype == LIBMTP_FILETYPE_FOLDER,
            size: file.filesize,
            modifiedWallClock: Int64(file.modificationdate),
            ref: ObjectRef(handle: file.item_id, storage: file.storage_id == 0 ? storage : file.storage_id, epoch: epoch)
        )
    }

    // MARK: Errors

    private func openDevice() throws(DeviceError) -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let device else { throw .deviceGone }
        return device
    }

    /// Classifies the failure of the last libmtp call.
    ///
    /// libmtp reports PTP-layer failures of partial reads only on stderr, not on its error stack,
    /// so the decisive signal is whether the device is still in the IOKit registry.
    private func failure(_ context: String) -> DeviceError {
        guard let device else { return .deviceGone }
        var messages: [String] = []
        var node = LIBMTP_Get_Errorstack(device)
        while let error = node {
            if let text = Self.string(error.pointee.error_text) { messages.append(text) }
            node = error.pointee.next
        }
        LIBMTP_Clear_Errorstack(device)

        if !isStillAttached() {
            abandon()
            // It comes back from a replug with a fresh MTP stack: nothing to recover.
            SessionMarker.markClosed(info.usb.usbSerial)
            return .deviceGone
        }
        let detail = ([context] + messages).joined(separator: ": ")
        if messages.contains(where: { $0.contains("could not find mtpfile") || $0.contains("Error 2009") }) {
            return .rejected("object no longer exists (\(detail))")
        }
        if messages.contains(where: { $0.contains("Error 200f") }) {
            return .rejected("access denied (\(detail))")
        }
        return .transient(detail)
    }

    private func isStillAttached() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    // MARK: Helpers

    private static func readStrategy(of device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> ReadStrategy {
        guard LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_GetPartialObject) != 0 else { return .whole }
        // libmtp exposes no direct check for GetPartialObject64 (0x95C1). Android's MTP server added
        // it together with SendPartialObject (0x95C2), which libmtp does expose; verified per device
        // with `pulli-cli info --dump` (docs/device-matrix.md).
        return LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_SendPartialObject) != 0 ? .partial64 : .partial32
    }

    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        return string(pointer)
    }

    private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func known(_ value: UInt64) -> UInt64? {
        value == UInt64.max ? nil : value
    }
}

/// libmtp's put callback for whole-object reads: hands each piece to the `WholeObjectPipe`
/// passed as `priv`, and cancels the transfer once the consumer has gone away.
private let wholeObjectPut: MTPDataPutFunc = { _, priv, length, data, consumed in
    consumed?.pointee = length
    guard let priv else { return UInt16(LIBMTP_HANDLER_RETURN_ERROR) }
    let pipe = Unmanaged<WholeObjectPipe>.fromOpaque(priv).takeUnretainedValue()
    if pipe.isCancelled { return UInt16(LIBMTP_HANDLER_RETURN_CANCEL) }
    if let data, length > 0 {
        pipe.append(UnsafeRawBufferPointer(start: data, count: Int(length)))
    }
    return UInt16(pipe.isCancelled ? LIBMTP_HANDLER_RETURN_CANCEL : LIBMTP_HANDLER_RETURN_OK)
}

/// Carries an upload's progress callback through libmtp's C callback.
private final class ProgressReporter: @unchecked Sendable {
    let report: @Sendable (UInt64) -> Void
    init(_ report: @escaping @Sendable (UInt64) -> Void) { self.report = report }
}
