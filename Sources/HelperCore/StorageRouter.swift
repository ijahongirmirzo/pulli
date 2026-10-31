public import DeviceAPI
import Foundation
public import PulliProtocol

/// Routes WebDAV drive paths to the phone's storages.
/// With a single storage, paths map directly to that storage root.
/// With several storages, the drive root lists one folder per storage,
/// and paths below route to the corresponding storage.
public struct StorageRouter: Sendable, Equatable {
    public struct Storage: Sendable, Equatable, Identifiable {
        public let id: StorageID
        public let folderName: String
        public var capacityBytes: UInt64?
        public var freeBytes: UInt64?

        public init(id: StorageID, folderName: String, capacityBytes: UInt64? = nil, freeBytes: UInt64? = nil) {
            self.id = id
            self.folderName = folderName
            self.capacityBytes = capacityBytes
            self.freeBytes = freeBytes
        }
    }

    public enum ResolvedPath: Sendable, Equatable {
        /// Drive root. In single-storage mode, storageID is present. In multi-storage mode, storageID is nil (virtual root).
        case root(storageID: StorageID?)
        /// Storage top folder in multi-storage mode (e.g. "/Internal storage" or "/SD card").
        case storageRoot(storage: Storage)
        /// An item inside a storage: target storage ID, remote path within that storage, and the storage folder name.
        case item(storageID: StorageID, remotePath: String, storageFolderName: String?)
        /// Path is not found in the virtual hierarchy.
        case notFound
    }

    public let isMultiStorage: Bool
    public private(set) var storages: [Storage]
    public let defaultStorageID: StorageID

    public init(storages: [StorageSnapshot]) {
        if storages.count > 1 {
            self.isMultiStorage = true
            let names = StorageDisplayName.uniqueFolderNames(for: storages, name: \.name)
            self.storages = zip(storages, names).map { snap, name in
                Storage(id: snap.id, folderName: name, capacityBytes: snap.capacityBytes, freeBytes: snap.freeBytes)
            }
            self.defaultStorageID = storages.first?.id ?? 0
        } else {
            self.isMultiStorage = false
            let single = storages.first
            let name = single.map { StorageDisplayName.name(for: $0.name, isFirst: true) } ?? "Internal storage"
            self.storages = single.map { [Storage(id: $0.id, folderName: name, capacityBytes: $0.capacityBytes, freeBytes: $0.freeBytes)] } ?? []
            self.defaultStorageID = single?.id ?? 0
        }
    }

    public init(storageInfos: [StorageInfo]) {
        if storageInfos.count > 1 {
            self.isMultiStorage = true
            let names = StorageDisplayName.uniqueFolderNames(for: storageInfos, name: \.description)
            self.storages = zip(storageInfos, names).map { info, name in
                Storage(id: info.id, folderName: name, capacityBytes: info.capacityBytes, freeBytes: info.freeBytes)
            }
            self.defaultStorageID = storageInfos.first?.id ?? 0
        } else {
            self.isMultiStorage = false
            let single = storageInfos.first
            let name = single.map { StorageDisplayName.name(for: $0.description, isFirst: true) } ?? "Internal storage"
            self.storages = single.map { [Storage(id: $0.id, folderName: name, capacityBytes: $0.capacityBytes, freeBytes: $0.freeBytes)] } ?? []
            self.defaultStorageID = single?.id ?? 0
        }
    }

    public init(singleStorageID: StorageID) {
        self.isMultiStorage = false
        self.storages = [Storage(id: singleStorageID, folderName: "Internal storage")]
        self.defaultStorageID = singleStorageID
    }

    public mutating func updateSpaces(_ infos: [StorageInfo]) {
        for info in infos {
            if let idx = storages.firstIndex(where: { $0.id == info.id }) {
                storages[idx].capacityBytes = info.capacityBytes
                storages[idx].freeBytes = info.freeBytes
            }
        }
    }

    public func resolve(_ rawPath: String) -> ResolvedPath {
        let path = normalize(rawPath)
        if !isMultiStorage {
            if path == "/" {
                return .root(storageID: defaultStorageID)
            }
            return .item(storageID: defaultStorageID, remotePath: path, storageFolderName: nil)
        }

        if path == "/" {
            return .root(storageID: nil)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = components.first, let storage = storages.first(where: { $0.folderName == first }) else {
            return .notFound
        }

        if components.count == 1 {
            return .storageRoot(storage: storage)
        }

        let remote = "/" + components.dropFirst().joined(separator: "/")
        return .item(storageID: storage.id, remotePath: remote, storageFolderName: storage.folderName)
    }

    public func drivePath(storageID: StorageID, remotePath: String) -> String {
        let norm = normalize(remotePath)
        if !isMultiStorage {
            return norm
        }
        guard let storage = storages.first(where: { $0.id == storageID }) else {
            return norm
        }
        if norm == "/" {
            return "/" + storage.folderName
        }
        return "/" + storage.folderName + norm
    }

    public func storage(for folderName: String) -> Storage? {
        storages.first(where: { $0.folderName == folderName })
    }

    private func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if !p.hasPrefix("/") { p = "/" + p }
        return p.isEmpty ? "/" : p
    }
}
