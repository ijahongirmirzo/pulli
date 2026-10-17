public import DeviceAPI
public import Foundation
import Synchronization

/// A simulated Android phone: fake storages and files of any size, and fault injection.
///
/// Like a real phone, it hands out different object handles in every session, and a session dies
/// for good when the device is unplugged. Reconnecting means calling `connect()` again.
public final class MockDevice: Sendable {
    public struct File: Sendable, Hashable {
        public var size: UInt64
        public var modifiedWallClock: Int64
        /// Seed for `MockContent`; changing it changes the bytes without changing size or date.
        public var seed: UInt64
    }

    /// Where a fault can be injected.
    public enum FaultPoint: Sendable, Hashable {
        case read(path: RemotePath, offset: UInt64, length: Int)
        case list(RemotePath)
        case stat(RemotePath)
        case open
    }

    public enum Fault: Sendable, Hashable {
        /// Cable pulled: this call fails and the device disappears until `plug()`.
        case disconnect
        /// The call fails with a retryable error; the session stays usable.
        case transient
        /// The read returns only this many bytes.
        case shortRead(Int)
        /// The object is gone or inaccessible: fails for good.
        case rejected
    }

    public typealias FaultInjector = @Sendable (FaultPoint) -> Fault?

    struct Folder {
        var files: [ExactName: (name: String, file: File)] = [:]
        var folders: [ExactName: String] = [:]
    }

    struct State {
        var storages: [StorageInfo]
        /// Folder index per storage, so lookups in 50,000-file folders stay O(1).
        var folders: [StorageID: [RemotePath: Folder]] = [:]
        var pluggedIn = true
        var locked = false
        var mode: Mode = .fileTransfer
        var epoch: UInt64 = 0
        var faultInjector: FaultInjector?
        var readCalls = 0
        var bytesServed: UInt64 = 0
    }

    public enum Mode: Sendable {
        case fileTransfer
        case chargingOnly
    }

    let state: Mutex<State>
    public let usb: USBDeviceSummary
    public let key: DeviceKey
    public let readStrategy: ReadStrategy

    public init(
        serial: String = "MOCK0001",
        model: String = "Mock Phone",
        storages: [StorageInfo] = [StorageInfo(id: 0x0001_0001, description: "Internal shared storage", volumeIdentifier: nil, capacityBytes: 256 << 30, freeBytes: 128 << 30)],
        readStrategy: ReadStrategy = .partial64,
        linkSpeedBitsPerSecond: UInt64 = 5_000_000_000,
        throughHub: Bool = false
    ) {
        usb = USBDeviceSummary(vendorID: 0x18d1, productID: 0x4ee1, vendorName: "Mock", productName: model,
                               usbSerial: serial, locationID: 0x0100_0000, address: 1, linkSpeedBitsPerSecond: linkSpeedBitsPerSecond,
                               throughHub: throughHub)
        key = DeviceKey(kind: .usb, vendorID: 0x18d1, serial: serial)
        self.readStrategy = readStrategy
        state = Mutex(State(storages: storages))
    }

    public var defaultStorage: StorageID {
        state.withLock { $0.storages[0].id }
    }

    // MARK: Scenario control

    public func addFile(_ path: RemotePath, size: UInt64, modifiedWallClock: Int64 = 1_760_000_000, seed: UInt64? = nil, storage: StorageID? = nil) {
        state.withLock { state in
            let storage = storage ?? state.storages[0].id
            let file = File(size: size, modifiedWallClock: modifiedWallClock, seed: seed ?? Self.stableSeed(path.description))
            var index = state.folders[storage] ?? [.root: Folder()]
            var parent = RemotePath.root
            for component in path.components.dropLast() {
                index[parent, default: Folder()].folders[ExactName(component)] = component
                parent = parent.appending(component)
                if index[parent] == nil { index[parent] = Folder() }
            }
            index[parent, default: Folder()].files[ExactName(path.name)] = (path.name, file)
            state.folders[storage] = index
        }
    }

    public func removeFile(_ path: RemotePath, storage: StorageID? = nil) {
        state.withLock { state in
            let storage = storage ?? state.storages[0].id
            state.folders[storage]?[path.parent]?.files[ExactName(path.name)] = nil
        }
    }

    public func file(_ path: RemotePath, storage: StorageID? = nil) -> File? {
        state.withLock { state in state.folders[storage ?? state.storages[0].id]?[path.parent]?.files[ExactName(path.name)]?.file }
    }

    /// Every file on the storage, for test assertions.
    public func allFiles(storage: StorageID? = nil) -> [RemotePath: File] {
        state.withLock { state in
            var result: [RemotePath: File] = [:]
            for (folder, contents) in state.folders[storage ?? state.storages[0].id] ?? [:] {
                for (_, entry) in contents.files { result[folder.appending(entry.name)] = entry.file }
            }
            return result
        }
    }

    /// Replaces a file on the "phone", as if the user edited or re-recorded it.
    public func modifyFile(_ path: RemotePath, storage: StorageID? = nil, _ change: (inout File) -> Void) {
        state.withLock { state in
            let storage = storage ?? state.storages[0].id
            guard var file = state.folders[storage]?[path.parent]?.files[ExactName(path.name)]?.file else { return }
            change(&file)
            state.folders[storage]?[path.parent]?.files[ExactName(path.name)] = (path.name, file)
        }
    }

    public func unplug() { state.withLock { $0.pluggedIn = false } }
    public func plug() { state.withLock { $0.pluggedIn = true } }
    public var isPluggedIn: Bool { state.withLock { $0.pluggedIn } }
    public var mode: Mode { state.withLock { $0.mode } }
    public func setLocked(_ locked: Bool) { state.withLock { $0.locked = locked } }
    public func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }

    public func setFaultInjector(_ injector: FaultInjector?) {
        state.withLock { $0.faultInjector = injector }
    }

    public var readCalls: Int { state.withLock { $0.readCalls } }
    public var bytesServed: UInt64 { state.withLock { $0.bytesServed } }

    /// Opens a new session; any previous session stops working.
    public func connect() throws(DeviceError) -> MockSession {
        let (epoch, fault) = try state.withLock { state throws(DeviceError) -> (UInt64, Fault?) in
            guard state.pluggedIn else { throw .deviceGone }
            guard state.mode == .fileTransfer else { throw .noMTPInterface }
            let fault = state.faultInjector?(.open)
            if fault == nil { state.epoch += 1 }
            return (state.epoch, fault)
        }
        switch fault {
        case .disconnect?:
            unplug()
            throw .deviceGone
        case .transient?, .shortRead?, .rejected?:
            throw .transient("injected open failure")
        case nil:
            break
        }
        let info = DeviceInfo(key: key, usb: usb, manufacturer: "Mock", model: usb.productName, friendlyName: nil,
                              mtpSerial: "MTP-" + key.serial, readStrategy: readStrategy)
        return MockSession(device: self, info: info, epoch: SessionEpoch(rawValue: epoch))
    }

    /// Byte-exact expected content of a file, for test assertions.
    public func expectedContent(_ path: RemotePath, storage: StorageID? = nil) -> Data? {
        guard let file = file(path, storage: storage) else { return nil }
        return MockContent.bytes(seed: file.seed, offset: 0, count: Int(file.size))
    }

    /// FNV-1a: stable across processes, unlike `hashValue`, so scenarios are reproducible.
    static func stableSeed(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }
}

/// Opens sessions to one or more mock phones by key, like MTPKit does for real ones.
public struct MockConnector: DeviceConnector {
    public let devices: [MockDevice]

    public init(_ devices: MockDevice...) {
        self.devices = devices
    }

    public init(devices: [MockDevice]) {
        self.devices = devices
    }

    public func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        guard let device = devices.first(where: { $0.key == key }) else { throw .deviceGone }
        return try device.connect()
    }
}

/// A session with a `MockDevice`.
public final class MockSession: DeviceSession {
    public let info: DeviceInfo
    public let epoch: SessionEpoch
    private let device: MockDevice
    /// Handles are assigned per session, starting at a session-specific base, so a handle from an
    /// earlier session never resolves to the same file (brief: failure cause 4).
    private let handles = Mutex<(byPath: [RemotePath: UInt32], byHandle: [UInt32: RemotePath], next: UInt32)>(([:], [:], 0))

    static let pageSize = 256

    init(device: MockDevice, info: DeviceInfo, epoch: SessionEpoch) {
        self.device = device
        self.info = info
        self.epoch = epoch
        handles.withLock { $0.next = UInt32(truncatingIfNeeded: epoch.rawValue &* 100_003) }
    }

    public func storages() throws(DeviceError) -> [StorageInfo] {
        try device.state.withLock { state throws(DeviceError) in
            try check(state)
            return state.locked ? [] : state.storages
        }
    }

    public func list(_ folder: RemotePath, storage: StorageID) -> AsyncThrowingStream<[RemoteEntry], any Error> {
        AsyncThrowingStream { continuation in
            do {
                try fault(.list(folder))
                let entries = try children(of: folder, storage: storage)
                for start in stride(from: 0, to: entries.count, by: Self.pageSize) {
                    continuation.yield(Array(entries[start..<min(start + Self.pageSize, entries.count)]))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func stat(_ path: RemotePath, storage: StorageID) throws(DeviceError) -> RemoteEntry? {
        try fault(.stat(path))
        guard !path.isRoot else { return nil }
        let found = try device.state.withLock { state throws(DeviceError) -> (MockDevice.File?, Bool) in
            try check(state)
            if state.locked { throw .noStorage }
            let parent = state.folders[storage]?[path.parent]
            return (parent?.files[ExactName(path.name)]?.file, parent?.folders[ExactName(path.name)] != nil)
        }
        if let file = found.0 {
            return RemoteEntry(name: path.name, isFolder: false, size: file.size, modifiedWallClock: file.modifiedWallClock,
                               ref: ref(for: path, storage: storage))
        }
        if found.1 {
            return RemoteEntry(name: path.name, isFolder: true, size: 0, modifiedWallClock: 0, ref: ref(for: path, storage: storage))
        }
        return nil
    }

    public func read(_ ref: ObjectRef, offset: UInt64, maxLength: Int) throws(DeviceError) -> Data {
        guard ref.epoch == epoch else { throw .staleHandle }
        guard let path = handles.withLock({ $0.byHandle[ref.handle] }) else { throw .rejected("invalid object handle") }
        let file = try device.state.withLock { state throws(DeviceError) -> MockDevice.File in
            try check(state)
            state.readCalls += 1
            guard let file = state.folders[ref.storage]?[path.parent]?.files[ExactName(path.name)]?.file else {
                throw .rejected("object no longer exists")
            }
            return file
        }
        if info.readStrategy == .whole {
            throw .unsupported("device cannot read by offset")
        }
        if offset > UInt64(UInt32.max), info.readStrategy != .partial64 {
            throw .unsupported("offsets above 4 GiB need GetPartialObject64")
        }
        guard offset < file.size else { return Data() }
        var length = Int(min(UInt64(maxLength), file.size - offset))
        if case .shortRead(let count)? = try fault(.read(path: path, offset: offset, length: length)) {
            length = max(0, min(length, count))
        }
        device.state.withLock { $0.bytesServed += UInt64(length) }
        return MockContent.bytes(seed: file.seed, offset: offset, count: length)
    }

    public func delete(_ ref: ObjectRef) throws(DeviceError) {
        guard ref.epoch == epoch else { throw .staleHandle }
        guard let path = handles.withLock({ $0.byHandle[ref.handle] }) else { throw .rejected("invalid object handle") }
        try device.state.withLock { state throws(DeviceError) in
            try check(state)
            guard state.folders[ref.storage]?[path.parent]?.files.removeValue(forKey: ExactName(path.name)) != nil else {
                throw .rejected("object no longer exists")
            }
        }
    }

    public func rename(_ ref: ObjectRef, to name: String) throws(DeviceError) {
        guard ref.epoch == epoch else { throw .staleHandle }
        guard let path = handles.withLock({ $0.byHandle[ref.handle] }) else { throw .rejected("invalid object handle") }
        try device.state.withLock { state throws(DeviceError) in
            try check(state)
            if let file = state.folders[ref.storage]?[path.parent]?.files.removeValue(forKey: ExactName(path.name)) {
                state.folders[ref.storage]?[path.parent]?.files[ExactName(name)] = (name, file.file)
            } else if state.folders[ref.storage]?[path.parent]?.folders.removeValue(forKey: ExactName(path.name)) != nil {
                state.folders[ref.storage]?[path.parent]?.folders[ExactName(name)] = name
                // Move the folder's index entries under the new name.
                let old = path.description, new = path.parent.appending(name).description
                var index = state.folders[ref.storage] ?? [:]
                for key in index.keys where key.description == old || key.description.hasPrefix(old + "/") {
                    let moved = RemotePath(new + key.description.dropFirst(old.count))
                    index[moved] = index.removeValue(forKey: key)
                }
                state.folders[ref.storage] = index
            } else {
                throw .rejected("object no longer exists")
            }
        }
        handles.withLock { handles in
            handles.byHandle[ref.handle] = path.parent.appending(name)
            handles.byPath[path] = nil
            handles.byPath[path.parent.appending(name)] = ref.handle
        }
    }

    public func makeFolder(_ name: String, in parent: RemotePath, storage: StorageID) throws(DeviceError) -> RemoteEntry {
        let path = parent.appending(name)
        try device.state.withLock { state throws(DeviceError) in
            try check(state)
            guard state.folders[storage]?[parent] != nil else { throw .notFound(parent) }
            state.folders[storage]?[parent]?.folders[ExactName(name)] = name
            if state.folders[storage]?[path] == nil { state.folders[storage]?[path] = MockDevice.Folder() }
        }
        return RemoteEntry(name: name, isFolder: true, size: 0, modifiedWallClock: 0, ref: ref(for: path, storage: storage))
    }

    /// Stores the file's size and date (the simulated phone's contents stay synthetic).
    public func upload(_ file: URL, as name: String, into parent: RemotePath, storage: StorageID,
                       progress: @escaping @Sendable (UInt64) -> Void) throws(DeviceError) -> RemoteEntry {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { throw .rejected("cannot read \(file.path)") }
        let modified = Int64((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let path = parent.appending(name)
        try device.state.withLock { state throws(DeviceError) in
            try check(state)
            guard state.folders[storage]?[parent] != nil else { throw .notFound(parent) }
            state.folders[storage]?[parent]?.files[ExactName(name)] = (name, MockDevice.File(size: size, modifiedWallClock: modified, seed: MockDevice.stableSeed(path.description)))
        }
        progress(size)
        return RemoteEntry(name: name, isFolder: false, size: size, modifiedWallClock: modified, ref: ref(for: path, storage: storage))
    }

    /// A generated preview for photos and videos (a soft gradient picked from the file's seed),
    /// like the JPEG thumbnail a phone keeps. Nil for other files.
    public func thumbnail(_ ref: ObjectRef) throws(DeviceError) -> Data? {
        guard ref.epoch == epoch else { throw .staleHandle }
        guard let path = handles.withLock({ $0.byHandle[ref.handle] }) else { throw .rejected("invalid object handle") }
        let file = try device.state.withLock { state throws(DeviceError) -> MockDevice.File? in
            try check(state)
            return state.folders[ref.storage]?[path.parent]?.files[ExactName(path.name)]?.file
        }
        guard let file else { return nil }
        let kind = (path.name as NSString).pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "heic", "mp4", "mov"].contains(kind) else { return nil }
        return MockThumbnail.jpeg(seed: file.seed, video: kind == "mp4" || kind == "mov")
    }

    public func readWhole(_ ref: ObjectRef) -> AsyncThrowingStream<Data, any Error> {
        let position = Mutex<UInt64>(0)
        return AsyncThrowingStream { [self] () async throws -> Data? in
            guard ref.epoch == epoch else { throw DeviceError.staleHandle }
            guard let path = handles.withLock({ $0.byHandle[ref.handle] }) else { throw DeviceError.rejected("invalid object handle") }
            let file = try device.state.withLock { state throws(DeviceError) -> MockDevice.File in
                try check(state)
                state.readCalls += 1
                guard let file = state.folders[ref.storage]?[path.parent]?.files[ExactName(path.name)]?.file else {
                    throw .rejected("object no longer exists")
                }
                return file
            }
            let offset = position.withLock { $0 }
            guard offset < file.size else { return nil }
            let length = Int(min(UInt64(Self.wholeChunk), file.size - offset))
            // Whole-object transfers cannot be shortened; only disconnects and errors apply.
            if case .shortRead? = try fault(.read(path: path, offset: offset, length: length)) {}
            device.state.withLock { $0.bytesServed += UInt64(length) }
            position.withLock { $0 += UInt64(length) }
            return MockContent.bytes(seed: file.seed, offset: offset, count: length)
        }
    }

    static let wholeChunk = 1 << 20

    public func close() {}

    // MARK: Internals

    private func check(_ state: MockDevice.State) throws(DeviceError) {
        guard state.pluggedIn, state.epoch == epoch.rawValue else { throw .deviceGone }
    }

    /// Applies the fault injector at `point`. Returns non-fatal faults for the caller to apply.
    @discardableResult
    private func fault(_ point: MockDevice.FaultPoint) throws(DeviceError) -> MockDevice.Fault? {
        let injected = try device.state.withLock { state throws(DeviceError) -> MockDevice.Fault? in
            try check(state)
            return state.faultInjector?(point)
        }
        switch injected {
        case .disconnect?:
            device.unplug()
            throw .deviceGone
        case .transient?:
            throw .transient("injected transient fault")
        case .rejected?:
            throw .rejected("injected: access denied")
        case .shortRead?, nil:
            return injected
        }
    }

    private func children(of folder: RemotePath, storage: StorageID) throws(DeviceError) -> [RemoteEntry] {
        let contents = try device.state.withLock { state throws(DeviceError) -> MockDevice.Folder? in
            try check(state)
            if state.locked { throw .noStorage }
            return state.folders[storage]?[folder]
        }
        guard let contents else {
            if folder.isRoot { return [] }
            throw .notFound(folder)
        }
        var entries: [RemoteEntry] = []
        entries.reserveCapacity(contents.files.count + contents.folders.count)
        for name in contents.folders.values {
            entries.append(RemoteEntry(name: name, isFolder: true, size: 0, modifiedWallClock: 0, ref: ref(for: folder.appending(name), storage: storage)))
        }
        for (name, file) in contents.files.values {
            entries.append(RemoteEntry(name: name, isFolder: false, size: file.size, modifiedWallClock: file.modifiedWallClock,
                                       ref: ref(for: folder.appending(name), storage: storage)))
        }
        return entries.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    private func ref(for path: RemotePath, storage: StorageID) -> ObjectRef {
        let handle = handles.withLock { table -> UInt32 in
            if let existing = table.byPath[path] { return existing }
            table.next &+= 1
            table.byPath[path] = table.next
            table.byHandle[table.next] = path
            return table.next
        }
        return ObjectRef(handle: handle, storage: storage, epoch: epoch)
    }
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Small JPEGs standing in for a phone's thumbnails: a two-colour gradient with a "sun", so a
/// simulated camera roll looks like photos.
enum MockThumbnail {
    static func jpeg(seed: UInt64, video: Bool) -> Data? {
        let width = 160, height = 120
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        func channel(_ shift: UInt64) -> CGFloat { CGFloat((seed >> shift) & 0xFF) / 255 }
        let top = CGColor(red: 0.3 + 0.6 * channel(0), green: 0.3 + 0.6 * channel(8), blue: 0.5 + 0.5 * channel(16), alpha: 1)
        let bottom = CGColor(red: 0.1 + 0.4 * channel(24), green: 0.2 + 0.5 * channel(32), blue: 0.2 + 0.4 * channel(40), alpha: 1)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.8, alpha: 0.85))
        let sun = CGFloat(18 + Int((seed >> 48) & 0x0F))
        context.fillEllipse(in: CGRect(x: CGFloat(20 + Int((seed >> 52) & 0x3F)), y: CGFloat(height) - 50, width: sun, height: sun))
        context.setFillColor(CGColor(red: 0.05, green: 0.15, blue: 0.1, alpha: 0.55))
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: 0, y: 40))
        context.addLine(to: CGPoint(x: 60, y: 70))
        context.addLine(to: CGPoint(x: 110, y: 35))
        context.addLine(to: CGPoint(x: 160, y: 55))
        context.addLine(to: CGPoint(x: 160, y: 0))
        context.fillPath()
        if video {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
            context.move(to: CGPoint(x: 70, y: 45))
            context.addLine(to: CGPoint(x: 70, y: 75))
            context.addLine(to: CGPoint(x: 96, y: 60))
            context.fillPath()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
